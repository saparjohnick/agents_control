# frozen_string_literal: true

require "test_helper"

module AgentsControl
  class DispatcherTest < Minitest::Test
    # Stub channel: remembers notifications and hands back a preset reply.
    class SpyChannel
      attr_reader :notified, :asked

      def initialize(reply: Reply.none)
        @reply = reply
        @notified = []
        @asked = []
      end

      def notify(event) = @notified << event

      def ask(event, pending:, timeout:)
        @asked << { event: event, timeout: timeout }
        @reply
      end
    end

    def setup
      @agent = Agents::ClaudeCode.new
      @channel = SpyChannel.new
    end

    # ── a human at the keyboard ────────────────────────────────────────────

    # While the owner is present, intercepting a permission request is
    # counterproductive: they'll answer in the terminal faster, and a
    # busy hook keeps the dialog from ever appearing.
    def test_at_keyboard_only_notifies_and_never_blocks
      response = build.handle(Fixtures::HOOK_PERMISSION)

      assert_empty response
      assert_empty @channel.asked
      assert_equal 1, @channel.notified.size
    end

    def test_away_mode_asks_the_human
      channel = SpyChannel.new(reply: Reply.allow)

      response = build(channel: channel, away: true).handle(Fixtures::HOOK_PERMISSION)

      assert_equal 1, channel.asked.size
      assert_equal "allow", response.dig("hookSpecificOutput", "decision", "behavior")
    end

    # ── AskUserQuestion ──────────────────────────────────────────────────

    # Its answer never comes back through the hook response — only
    # allow/deny does. Blocking here would hold the hook open for the
    # full reply_timeout for nothing and then auto-deny, regardless of mode.
    def test_ask_user_question_never_blocks_even_when_away
      channel = SpyChannel.new(reply: Reply.allow)

      response = build(channel: channel, away: true).handle(ask_user_question_payload)

      assert_empty channel.asked
      assert_equal 1, channel.notified.size
      assert_empty response
    end

    def test_ask_user_question_notifies_while_present_too
      response = build(away: false).handle(ask_user_question_payload)

      assert_equal 1, @channel.notified.size
      assert_empty response
    end

    # ── silence ────────────────────────────────────────────────────────────

    # Nobody answered while the owner was out — the action doesn't happen.
    def test_silence_denies_a_permission
      response = build(away: true).handle(Fixtures::HOOK_PERMISSION)

      assert_equal "deny", response.dig("hookSpecificOutput", "decision", "behavior")
    end

    def test_silence_lets_a_turn_simply_end
      assert_empty build(away: true).handle(Fixtures::HOOK_STOP)
    end

    # ── automation ────────────────────────────────────────────────────────

    # A "continue" reply grants the agent no new permissions — it only
    # clears the question "should I go on?" That's why it's on by default.
    def test_continuation_question_is_answered_automatically
      response = build(away: true).handle(Fixtures::HOOK_STOP_CONTINUE)

      assert_equal "block", response["decision"]
      assert_equal "Continue.", response["reason"]
      assert_empty @channel.asked
    end

    def test_substantive_question_still_goes_to_the_human
      payload = Fixtures::HOOK_STOP.merge(
        "last_assistant_message" => "What should the new table be called?"
      )

      build(away: true).handle(payload)

      assert_equal 1, @channel.asked.size
    end

    # The word "continue" alone isn't enough: if a choice is offered, the
    # decision stays with the human. Otherwise automation would silently
    # pick one of the options for them.
    def test_question_offering_alternatives_is_never_auto_answered
      build(away: true).handle(Fixtures::HOOK_STOP)

      assert_equal 1, @channel.asked.size,
                   "a question with \"or\" is a choice, not \"should I continue?\""
    end

    def test_numbered_options_also_count_as_a_choice
      payload = Fixtures::HOOK_STOP.merge(
        "last_assistant_message" => "Shall we continue?\n1) rewrite it\n2) leave it"
      )

      build(away: true).handle(payload)

      assert_equal 1, @channel.asked.size
    end

    def test_auto_continue_can_be_switched_off
      build(away: true, extra: { "auto_continue" => false }).handle(Fixtures::HOOK_STOP_CONTINUE)

      assert_equal 1, @channel.asked.size
    end

    # Automatic tool approval is off by default — deliberately a separate
    # setting from "continue."
    def test_permissions_are_not_auto_approved_by_default
      build(away: true).handle(Fixtures::HOOK_PERMISSION)

      assert_equal 1, @channel.asked.size
    end

    def test_permissions_can_be_auto_approved_when_asked_for
      response = build(away: true,
                       extra: { "auto_approve_permissions" => true }).handle(Fixtures::HOOK_PERMISSION)

      assert_empty @channel.asked
      assert_equal "allow", response.dig("hookSpecificOutput", "decision", "behavior")
    end

    # The forbidden list overrides any automatic setting.
    def test_forbidden_commands_are_never_auto_approved
      dispatcher = build(away: true, extra: { "auto_approve_permissions" => true })

      dispatcher.handle(Fixtures::HOOK_PERMISSION_DANGEROUS)

      assert_equal 1, @channel.asked.size, "rm -rf must ask a human"
    end

    # ── noise ───────────────────────────────────────────────────────────────

    # An agent calls tools dozens of times per turn: reporting all of it isn't an option.
    def test_routine_events_are_silent
      dispatcher = build

      dispatcher.handle(Fixtures::HOOK_SESSION_START)
      dispatcher.handle(Fixtures::HOOK_SESSION_END)

      assert_empty @channel.notified
    end

    def test_rate_limit_is_always_reported
      build.handle(Fixtures::HOOK_RATE_LIMIT)

      assert_equal 1, @channel.notified.size
      assert_equal :error, @channel.notified.first.kind
    end

    def test_notifications_can_be_silenced_while_present
      build(extra: { "notify_when_present" => false }).handle(Fixtures::HOOK_PERMISSION)

      assert_empty @channel.notified
    end

    # ── robustness ──────────────────────────────────────────────────────────

    def test_unknown_payload_yields_no_decision
      assert_empty build.handle({ "some" => "noise" })
    end

    # A failure on our end must not stop the agent: an empty response
    # means "no decision," and it behaves as it would without us.
    def test_broken_channel_does_not_block_the_agent
      channel = Object.new
      def channel.notify(_event) = raise("channel broke")
      def channel.ask(_event, pending:, timeout:) = raise("channel broke")

      assert_empty build(channel: channel, away: true).handle(Fixtures::HOOK_PERMISSION)
    end

    def test_reply_timeout_is_taken_from_settings
      channel = SpyChannel.new

      build(channel: channel, away: true, extra: { "reply_timeout" => 1234 })
        .handle(Fixtures::HOOK_PERMISSION)

      assert_equal 1234, channel.asked.first[:timeout]
    end

    private

    def build(channel: @channel, away: false, extra: {})
      config = Config.new({ "answers" => { "away" => away }.merge(extra) })

      Dispatcher.new(agents: [@agent], channel: channel, config: config)
    end

    def ask_user_question_payload
      Fixtures::HOOK_PERMISSION.merge(
        "tool_name" => "AskUserQuestion",
        "tool_input" => {
          "questions" => [
            { "header" => "Format", "question" => "Short or detailed?",
              "options" => [
                { "label" => "Short", "description" => "Just the question" },
                { "label" => "Detailed", "description" => "Question and options" }
              ] }
          ]
        }
      )
    end
  end
end
