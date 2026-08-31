# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  module Agents
    class ClaudeCodeTest < Minitest::Test
      def setup
        @dir = Dir.mktmpdir
        @settings = File.join(@dir, "settings.json")
        @agent = ClaudeCode.new(settings_path: @settings)
      end

      def teardown = FileUtils.remove_entry(@dir)

      # ── event parsing ────────────────────────────────────────────────

      def test_recognises_its_own_payloads
        assert ClaudeCode.handles?(Fixtures::HOOK_STOP)
        refute ClaudeCode.handles?({ "something" => "foreign" })
      end

      # The question text arrives right in the payload — no need to read the screen.
      def test_stop_carries_the_question_text
        event = @agent.to_event(Fixtures::HOOK_STOP)

        assert_equal :needs_input, event.kind
        assert_equal "Should I continue the refactor, or show the plan first?", event.text
      end

      # Answering with a block on a turn we're already blocking would
      # produce an infinite loop: the agent continues, stops again, blocks again.
      def test_ignores_a_turn_we_are_already_blocking
        assert_nil @agent.to_event(Fixtures::HOOK_STOP_ACTIVE)
      end

      def test_permission_carries_tool_and_arguments
        event = @agent.to_event(Fixtures::HOOK_PERMISSION)

        assert_equal :needs_permission, event.kind
        assert_equal "Bash", event.tool_name
        assert_equal "npm run build", event.tool_input["command"]
      end

      def test_summary_shows_the_command_not_the_whole_json
        event = @agent.to_event(Fixtures::HOOK_PERMISSION)

        assert_equal "Bash: npm run build", event.summary
      end

      def test_label_is_the_project_directory
        assert_equal "flightlog", @agent.to_event(Fixtures::HOOK_STOP).label
      end

      def test_rate_limit_arrives_as_an_error
        event = @agent.to_event(Fixtures::HOOK_RATE_LIMIT)

        assert_equal :error, event.kind
        assert_equal "usage limit reached", event.text
      end

      def test_session_lifecycle_events
        assert_equal :started, @agent.to_event(Fixtures::HOOK_SESSION_START).kind
        assert_equal :ended, @agent.to_event(Fixtures::HOOK_SESSION_END).kind
      end

      def test_unknown_event_is_skipped
        assert_nil @agent.to_event(Fixtures.hook("PostToolBatch"))
      end

      # ── building responses ────────────────────────────────────────────

      # A reply like this comes back to the agent as user input, and the
      # agent continues working with that text.
      def test_text_reply_becomes_a_blocking_continuation
        event = @agent.to_event(Fixtures::HOOK_STOP)

        response = @agent.to_response(event, Reply.text("Show the plan."))

        assert_equal "block", response["decision"]
        assert_equal "Show the plan.", response["reason"]
      end

      # An empty reply means "let the agent stop" — a normal outcome, not an error.
      def test_empty_reply_lets_the_turn_end
        event = @agent.to_event(Fixtures::HOOK_STOP)

        assert_empty @agent.to_response(event, Reply.none)
      end

      def test_permission_allow
        event = @agent.to_event(Fixtures::HOOK_PERMISSION)

        decision = @agent.to_response(event, Reply.allow).dig("hookSpecificOutput", "decision")

        assert_equal "allow", decision["behavior"]
        refute decision.key?("storeRule")
      end

      def test_permission_deny
        event = @agent.to_event(Fixtures::HOOK_PERMISSION)

        decision = @agent.to_response(event, Reply.deny).dig("hookSpecificOutput", "decision")

        assert_equal "deny", decision["behavior"]
      end

      # "Allow and don't ask again" — the rule is remembered by the agent itself.
      def test_permission_can_store_a_rule
        event = @agent.to_event(Fixtures::HOOK_PERMISSION)

        decision = @agent.to_response(event, Reply.allow(remember: true))
                         .dig("hookSpecificOutput", "decision")

        assert_equal({ "matcher" => "Bash" }, decision["storeRule"])
      end

      # Silence must not grant permission.
      def test_silence_does_not_permit
        event = @agent.to_event(Fixtures::HOOK_PERMISSION)

        decision = @agent.to_response(event, Reply.none).dig("hookSpecificOutput", "decision")

        assert_equal "deny", decision["behavior"]
      end

      # ── installation ─────────────────────────────────────────────────

      def test_install_creates_hooks_for_every_event
        @agent.install!("http://127.0.0.1:47653", secret: "s3cret")

        hooks = JSON.parse(File.read(@settings))["hooks"]

        assert_equal ClaudeCode::EVENTS.sort, hooks.keys.sort
        assert_predicate @agent, :installed?
      end

      # The file carries our hook secret in plaintext once a secret is
      # installed — it must never be readable by anyone but the owner.
      def test_settings_file_is_not_world_readable_after_install
        @agent.install!("http://127.0.0.1:47653", secret: "s3cret")

        assert_equal "600", format("%o", File.stat(@settings).mode & 0o777)
      end

      # settings.json holds settings we don't own — they must not be overwritten.
      def test_install_keeps_foreign_settings_and_hooks
        File.write(@settings, JSON.generate({
                                              "model" => "opus",
                                              "hooks" => {
                                                "Stop" => [{ "hooks" => [{ "type" => "command",
                                                                           "command" => "foreign.sh" }] }]
                                              }
                                            }))

        @agent.install!("http://127.0.0.1:47653")
        settings = JSON.parse(File.read(@settings))

        assert_equal "opus", settings["model"]
        commands = settings["hooks"]["Stop"].flat_map { |g| g["hooks"] }.map { |h| h["command"] }
        assert_includes commands, "foreign.sh"
      end

      def test_uninstall_removes_only_ours
        File.write(@settings, JSON.generate({
                                              "hooks" => {
                                                "Stop" => [{ "hooks" => [{ "type" => "command",
                                                                           "command" => "foreign.sh" }] }]
                                              }
                                            }))
        @agent.install!("http://127.0.0.1:47653")
        @agent.uninstall!

        settings = JSON.parse(File.read(@settings))
        commands = settings["hooks"]["Stop"].flat_map { |g| g["hooks"] }.map { |h| h["command"] }

        assert_equal ["foreign.sh"], commands
        refute_predicate @agent, :installed?
      end

      # Install then uninstall must return the file to exactly its
      # original shape, leaving no empty shell of keys that weren't there before.
      def test_install_then_uninstall_restores_the_file_exactly
        File.write(@settings, JSON.generate({ "model" => "opus" }))
        before = JSON.parse(File.read(@settings))

        @agent.install!("http://127.0.0.1:47653")
        @agent.uninstall!

        assert_equal before, JSON.parse(File.read(@settings))
      end

      def test_repeated_install_does_not_pile_up_duplicates
        3.times { @agent.install!("http://127.0.0.1:47653") }

        groups = JSON.parse(File.read(@settings))["hooks"]["Stop"]

        assert_equal 1, groups.size
      end

      def test_install_carries_the_shared_secret
        @agent.install!("http://127.0.0.1:47653", secret: "s3cret")

        hook = JSON.parse(File.read(@settings))["hooks"]["Stop"][0]["hooks"][0]

        assert_equal "Bearer s3cret", hook.dig("headers", "Authorization")
      end

      # Claude Code waits longer than the documented 600 seconds.
      def test_timeout_is_configurable_beyond_the_documented_default
        @agent.install!("http://127.0.0.1:47653", timeout: 960)

        hook = JSON.parse(File.read(@settings))["hooks"]["Stop"][0]["hooks"][0]

        assert_equal 960, hook["timeout"]
      end

      # A foreign broken file isn't ours to fix, but it must not be overwritten either.
      def test_refuses_to_touch_a_corrupted_settings_file
        File.write(@settings, "{this is not json")

        assert_raises(Error) { @agent.install!("http://127.0.0.1:47653") }
        assert_equal "{this is not json", File.read(@settings)
      end
    end
  end
end
