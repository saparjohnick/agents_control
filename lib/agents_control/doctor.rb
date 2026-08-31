# frozen_string_literal: true

module AgentsControl
  # Checks that everything is in place.
  #
  # Main principle: check the environment the daemon will actually get,
  # not the one the user happens to be sitting in. An interactive shell
  # can show a different Ruby, a different PATH, different environment
  # variables than what a separately launched daemon process will see.
  class Doctor
    Check = Struct.new(:name, :status, :detail, :fix, keyword_init: true) do
      def ok? = status == :ok
      def failed? = status == :fail
      def icon = { ok: "✓", warn: "!", fail: "✗" }[status]
    end

    # AppleScript's error when the user hasn't granted permission to
    # control the app.
    NOT_AUTHORISED = "-1743"

    def initialize(config: nil, secrets: nil, executor: Executor.new, api: nil)
      @config = config || Config.load
      @secrets = secrets || Secrets.new
      @executor = executor
      @api = api
    end

    CHECKS = %i[
      ruby_check terminal_check automation_check agent_binary_check
      token_check chats_check bot_check daemon_check hooks_check
      anchors_check wake_check
    ].freeze

    # Checks run one at a time, each wrapped: a diagnostic tool has no
    # business crashing. An unexpected error is just another result, not
    # the end of the run — otherwise the first small thing would hide
    # everything after it.
    def run
      CHECKS.filter_map do |name|
        send(name)
      rescue StandardError => e
        Check.new(name: name.to_s.sub("_check", ""), status: :fail,
                  detail: "check failed: #{e.class}")
      end
    end

    private

    def ok(name, detail) = Check.new(name: name, status: :ok, detail: detail)
    def warn(name, detail, fix = nil) = Check.new(name: name, status: :warn, detail: detail, fix: fix)
    def fail(name, detail, fix = nil) = Check.new(name: name, status: :fail, detail: detail, fix: fix)

    # The plist gets RbConfig.ruby — the interpreter running this code,
    # so it's guaranteed to work. What's checked isn't that, but what
    # would be found by searching PATH: a version manager's broken shim
    # can sit ahead of the real Ruby there.
    def ruby_check
      running = RbConfig.ruby
      return fail("Ruby", "#{RUBY_VERSION} — needs 3.2+", "update the interpreter") if RUBY_VERSION < "3.2"

      found = Which.find("ruby")
      shadow = found && found != running && !working_ruby?(found)

      return warn("Ruby", "#{RUBY_VERSION} — #{running}",
                  "a broken #{found} sits earlier on PATH; the service uses " \
                  "an absolute path, so this won't get in the way") if shadow

      ok("Ruby", "#{RUBY_VERSION} — #{running}")
    end

    def working_ruby?(path)
      result = @executor.run(path, "-e", "print RUBY_VERSION")

      result.success? && !result.stdout.strip.empty?
    end

    def terminal_check
      registry = Registry.new(executor: @executor)
      names = registry.available_backends.map(&:name)

      return warn("Terminal", "no backends available",
                  "install tmux or launch iTerm2 — without them only monitoring works") if names.empty?

      ok("Terminal", names.join(", "))
    end

    # Permission to control iTerm2 can't be granted programmatically: the
    # TCC database is closed off by SIP, and that's a load-bearing part
    # of macOS security, not an oversight. All that's possible is
    # triggering the prompt at a clear moment, catching the refusal, and
    # opening the right settings pane.
    def automation_check
      return nil unless macos?
      return nil unless iterm_running?

      result = @executor.run(Which.find("osascript"), "-e",
                             'tell application "iTerm2" to count windows')

      return ok("iTerm2 permission", "granted") if result.success?

      if result.stderr.include?(NOT_AUTHORISED)
        fail("iTerm2 permission", "not granted",
             'open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"')
      else
        warn("iTerm2 permission", result.stderr.to_s[0, 80])
      end
    end

    def agent_binary_check
      path = Which.find("claude")
      return warn("Claude Code", "binary not found", "needed for rate-limit anchors") unless path

      ok("Claude Code", path)
    end

    def token_check
      source = @secrets.source_for(:telegram_token)
      return fail("Token", "not found", "agents_control setup") unless source

      insecure = source.respond_to?(:insecure?) && source.insecure?
      return warn("Token", "#{source.name} — insecure storage") if insecure

      ok("Token", source.name)
    end

    def chats_check
      chats = Array(@config.get("telegram.allowed_chat_ids", []))
      return fail("Allowed chats", "list is empty — the bot won't answer anyone",
                  "agents_control setup") if chats.empty?

      ok("Allowed chats", chats.join(", "))
    end

    TOKEN_SHAPE = /\A\d+:[A-Za-z0-9_-]{30,}\z/

    def bot_check
      token = @secrets.get(:telegram_token)
      return nil unless token

      # The shape is checked before touching the network: unprintable
      # characters would land straight in the URL and fail the request
      # with a cryptic address-parsing error.
      return fail("Bot", "token doesn't look like one issued by BotFather", "agents_control setup") unless
        token.match?(TOKEN_SHAPE)

      me = (@api || Channels::Telegram::Api.new(token)).get_me
      ok("Bot", "@#{me['username']}")
    rescue Channels::Telegram::Api::Unavailable
      warn("Bot", "network unavailable — couldn't check")
    rescue Channels::Telegram::Api::Error => e
      fail("Bot", e.message, "check the token: agents_control setup")
    end

    # A successful connection alone means nothing: something else could
    # be sitting on the port, and in some environments a local connect
    # always succeeds. So a request is sent and the response is
    # inspected — our server refuses a request with no secret, and
    # that's its signature.
    def daemon_check
      port = @config.get("hooks.port", Daemon::DEFAULT_PORT)

      case daemon_response(port)
      when :ours then ok("Daemon", "running on port #{port}")
      when :stranger then fail("Daemon", "port #{port} is taken by something else",
                               "change hooks.port in settings")
      else warn("Daemon", "not running", "agents_control daemon")
      end
    end

    def daemon_response(port)
      socket = Socket.tcp("127.0.0.1", port, connect_timeout: 1)
      socket.print("POST /ping HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}")
      status = socket.readline

      status.include?("403") ? :ours : :stranger
    rescue StandardError
      :down
    ensure
      socket&.close
    end

    def hooks_check
      agent = Agents::ClaudeCode.new
      return ok("Hooks", "connected") if agent.installed?

      # Not an error: the daemon connects them itself on start and
      # removes them on stop, or the agent would complain about an
      # unreachable address.
      warn("Hooks", "not connected — expected while the daemon is off")
    rescue StandardError => e
      fail("Hooks", e.message)
    end

    def anchors_check
      return warn("Rate-limit anchors", "off", "turn on in /settings") unless @config.get("anchors.enabled", false)

      scheduler = Anchors::Scheduler.new(config: @config, store: Store.new)
      at = scheduler.next_run_at

      ok("Rate-limit anchors", "model #{@config.get('anchors.model')}, next at #{at&.strftime('%d.%m %H:%M')}")
    end

    # A 7am anchor won't fire if the laptop is asleep: launchd runs the
    # task after waking, and the precise timing is lost.
    def wake_check
      return nil unless macos?
      return nil unless @config.get("anchors.enabled", false)

      scheduled = @executor.run(Which.find("pmset"), "-g", "sched").stdout.to_s

      return ok("Wake schedule", "configured") if scheduled.match?(/wake|poweron/i)

      warn("Wake schedule", "the Mac could be asleep at anchor time",
           "sudo pmset repeat wakeorpoweron MTWRF #{earliest_anchor}:00")
    end

    def earliest_anchor
      Array(@config.get("anchors.schedule", [])).min.to_s.sub(/\A(\d):/, "0\\1:")
    end

    def macos? = RUBY_PLATFORM.include?("darwin")

    def iterm_running?
      ProcessProbe.new(executor: @executor).refresh.running?("iTerm2")
    end

    def port_open?(port)
      Socket.tcp("127.0.0.1", port, connect_timeout: 1, &:close)
      true
    rescue StandardError
      false
    end
  end
end
