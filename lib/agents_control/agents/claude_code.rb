# frozen_string_literal: true

require "json"
require "fileutils"

module AgentsControl
  module Agents
    # Claude Code.
    #
    # `{"decision":"block","reason":"..."}` returned to a Stop hook comes
    # back to the agent as user input, and the agent continues working
    # with that text — this is what the whole idea of answering from
    # Telegram rests on.
    class ClaudeCode < Base
      # Claude Code's config directory honors CLAUDE_CONFIG_DIR — just
      # like the agent itself. This matters both for anyone keeping
      # settings outside the home directory, and for tests: without this
      # override a test run would edit the user's real file.
      def self.settings_path
        base = ENV["CLAUDE_CONFIG_DIR"] || File.expand_path("~/.claude")

        File.join(base, "settings.json")
      end

      # The events we care about. Others arrive too but are ignored:
      # subscribing to everything is extra overhead on every agent call.
      EVENTS = %w[SessionStart SessionEnd PermissionRequest Stop Notification StopFailure].freeze

      class << self
        def key = :claude_code

        def binaries = %w[claude]

        def handles?(payload)
          payload.is_a?(Hash) && payload.key?("hook_event_name")
        end
      end

      def initialize(settings_path: self.class.settings_path)
        @settings_path = settings_path
      end

      def capabilities = %i[push blocking_reply]

      def to_event(payload)
        case payload["hook_event_name"]
        when "SessionStart" then build(payload, :started)
        when "SessionEnd" then build(payload, :ended)
        when "PermissionRequest" then permission_event(payload)
        when "Stop" then stop_event(payload)
        when "Notification" then notification_event(payload)
        when "StopFailure" then build(payload, :error, text: payload["error"])
        end
      end

      # Reply → the hook response body. The shape depends on the event:
      # granting permission and continuing a dialog are structured
      # differently in the API.
      def to_response(event, reply)
        case event.raw["hook_event_name"]
        when "PermissionRequest" then permission_response(event, reply)
        when "Stop" then stop_response(reply)
        else {}
        end
      end

      # ── installation ──────────────────────────────────────────────────

      # Merge, not overwrite: settings.json holds other settings we don't
      # own, and they must not be clobbered. The timeout is set
      # explicitly: Claude Code waits longer than the documented 600
      # seconds, and how long to wait is our call.
      def install!(url, secret: nil, timeout: 660)
        settings = read_settings
        settings["hooks"] ||= {}

        EVENTS.each do |name|
          settings["hooks"][name] = merge_hook(settings["hooks"][name],
                                               hook_entry(url, name, secret, timeout))
        end

        write_settings(settings)
      end

      def uninstall!
        settings = read_settings
        hooks = settings["hooks"] || {}

        EVENTS.each do |name|
          next unless hooks[name]

          hooks[name] = hooks[name].filter_map { |group| without_ours(group) }
          hooks.delete(name) if hooks[name].empty?
        end

        # If the key wasn't there before us, it shouldn't be there after
        # us either: cleaning up after ourselves means not leaving an
        # empty shell behind.
        settings.delete("hooks") if hooks.empty?

        write_settings(settings)
      end

      def installed?
        hooks = read_settings["hooks"] || {}

        EVENTS.all? { |name| Array(hooks[name]).any? { |group| ours?(group) } }
      end

      private

      def build(payload, kind, text: nil, **extra)
        Event.new(
          kind: kind,
          agent: key,
          session_id: payload["session_id"],
          cwd: payload["cwd"],
          transcript_path: payload["transcript_path"],
          text: text,
          raw: payload,
          **extra
        )
      end

      def permission_event(payload)
        build(payload, :needs_permission,
              tool_name: payload["tool_name"],
              tool_input: payload["tool_input"])
      end

      # Stop fires at the end of every turn, not only when the agent is
      # actually asking something. The payload alone can't tell them
      # apart — whether to bother the human is a decision the Dispatcher
      # makes based on settings.
      #
      # stop_hook_active means we're already holding this turn blocked.
      # Answering with another block would produce an infinite loop.
      def stop_event(payload)
        return nil if payload["stop_hook_active"]

        build(payload, :needs_input, text: payload["last_assistant_message"])
      end

      def notification_event(payload)
        kind = payload["notificationType"] == "agent_completed" ? :finished : :progress

        build(payload, kind, text: payload["message"])
      end

      def permission_response(event, reply)
        behavior = reply.permits? ? "allow" : "deny"
        decision = { "behavior" => behavior }

        # "Allow and don't ask again" — the rule is remembered by the
        # agent itself, we don't need to store it afterward.
        decision["storeRule"] = { "matcher" => event.tool_name } if reply.allow? && reply.remember

        {
          "hookSpecificOutput" => {
            "hookEventName" => "PermissionRequest",
            "decision" => decision
          }
        }
      end

      # An empty reply means "let the agent stop". A block with text
      # feeds that text back to the agent as input.
      def stop_response(reply)
        return {} unless reply.text? && !reply.text.to_s.empty?

        { "decision" => "block", "reason" => reply.text }
      end

      # ── settings.json handling ─────────────────────────────────────────

      # The secret is written as a literal value, not via $VAR:
      # environment substitution pulls variables from the agent's own
      # process, which the user launches by hand — our environment isn't
      # there.
      #
      # The settings file is already readable only by its owner, and the
      # secret protects against another process on the local port, not
      # against another user on the same account.
      def hook_entry(url, name, secret, timeout)
        hook = {
          "type" => "http",
          "url" => "#{url}/#{name}",
          "timeout" => timeout,
          "statusMessage" => "agents_control: waiting for a reply in Telegram",
          # This marker is how our own entries are found on uninstall,
          # without touching anyone else's.
          "_agents_control" => true
        }
        hook["headers"] = { "Authorization" => "Bearer #{secret}" } if secret

        { "hooks" => [hook] }
      end

      def merge_hook(existing, entry)
        groups = Array(existing).reject { |group| ours?(group) }

        groups + [entry]
      end

      def ours?(group)
        Array(group["hooks"]).any? { |hook| hook["_agents_control"] }
      end

      def without_ours(group)
        remaining = Array(group["hooks"]).reject { |hook| hook["_agents_control"] }

        remaining.empty? ? nil : group.merge("hooks" => remaining)
      end

      def read_settings
        return {} unless File.exist?(@settings_path)

        parsed = JSON.parse(File.read(@settings_path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        # A broken file that isn't ours to fix, but we definitely have
        # no right to overwrite its contents either.
        raise Error, "could not parse #{@settings_path}: file is corrupted"
      end

      # Via a temporary file: an interrupted write must not leave the
      # user with no Claude Code settings at all. Chmod'd before the
      # rename: this file carries our hook secret in plaintext once
      # install! runs, and it must never sit world-readable, even briefly.
      def write_settings(settings)
        FileUtils.mkdir_p(File.dirname(@settings_path))
        temporary = "#{@settings_path}.agents_control.tmp"

        File.write(temporary, JSON.pretty_generate(settings))
        File.chmod(0o600, temporary)
        File.rename(temporary, @settings_path)
        true
      ensure
        FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
      end
    end
  end
end
