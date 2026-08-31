# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  module Channels
    module Telegram
      # Replying via reply: an agent's message can just be answered in
      # chat, without figuring out tab numbers.
      class ReplyTest < Minitest::Test
        OWNER = 424_242

        def setup
          @dir = Dir.mktmpdir
          @api = FakeApi.new
          @store = Store.new(path: File.join(@dir, "store.json"))
          @config = Config.new({ "telegram" => { "allowed_chat_ids" => [OWNER] } },
                               path: File.join(@dir, "config.yml"))
          @pending = Pending.new
          @executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF, "osascript" => Fixtures::ITERM
          )
          @channel = Channel.new(api: @api, store: @store, config: @config)
          @router = Router.new(api: @api, registry: Registry.new(executor: @executor),
                               store: @store, config: @config, pending: @pending)
        end

        def teardown = FileUtils.remove_entry(@dir)

        # ── session tag ──────────────────────────────────────────────────

        # When there are several agents and their labels match, messages
        # can only be told apart by the tag.
        def test_message_carries_a_short_session_tag
          @channel.notify(event)

          assert_match(/#\h{4}/, @api.last_text)
        end

        def test_tag_is_stable_for_the_same_session
          @channel.notify(event)
          first = @api.last_text[/#\h{4}/]
          @channel.notify(event)

          assert_equal first, @api.last_text[/#\h{4}/]
        end

        def test_different_sessions_get_different_tags
          @channel.notify(event)
          first = @api.last_text[/#\h{4}/]
          @channel.notify(event(session: "99999999-1111-2222-3333-444444444444"))

          refute_equal first, @api.last_text[/#\h{4}/]
        end

        # Nobody is going to look this up in the help text.
        def test_question_explains_that_a_reply_works
          ask_in_background

          assert_includes @api.last_text, "reply to this message"
        end

        # ── routing ─────────────────────────────────────────────────────

        def test_reply_to_a_waiting_agent_delivers_the_answer
          question_id = ask_in_background
          message_id = @api.sent.size

          @router.handle(reply(to: message_id, text: "let's go with the second option"))

          assert_includes @api.last_text, "Sent to the agent"
          assert_predicate answer_for(question_id), :text?
          assert_equal "let's go with the second option", answer_for(question_id).text
        end

        # A terminalless session is only reachable while it's holding a
        # hook open — and only that way.
        def test_reply_reaches_a_session_without_a_terminal
          question_id = ask_in_background(cwd: "/Users/devbox/projects/flightlog")
          message_id = @api.sent.size

          @router.handle(reply(to: message_id, text: "answer"))

          assert_equal "answer", answer_for(question_id).text
        end

        # The agent isn't waiting anymore — type into the tab, found by directory.
        def test_reply_after_the_question_expired_types_into_the_tab
          @channel.notify(event(cwd: "/Users/devbox/projects/backend_api"))
          message_id = @api.sent.size

          @router.handle(reply(to: message_id, text: "one more task"))

          assert_includes @api.last_text, "Sent"
        end

        def test_reply_to_something_unknown_says_so
          @router.handle(reply(to: 999, text: "what is this"))

          assert_includes @api.last_text, "I don't remember"
        end

        def test_reply_from_a_stranger_is_ignored
          ask_in_background
          message_id = @api.sent.size
          @api.sent.clear

          @router.handle(reply(to: message_id, text: "not mine", chat_id: 999))

          assert_empty @api.sent
        end

        def test_empty_reply_is_treated_as_a_command_not_an_answer
          ask_in_background
          message_id = @api.sent.size

          @router.handle(reply(to: message_id, text: ""))

          refute_includes @api.texts.join, "Sent to the agent"
        end

        private

        def event(session: Fixtures::SESSION, cwd: Fixtures::CWD)
          Agents::ClaudeCode.new.to_event(
            Fixtures::HOOK_STOP.merge("session_id" => session, "cwd" => cwd)
          )
        end

        # Asks a question on a separate thread and returns its identifier.
        def ask_in_background(cwd: Fixtures::CWD)
          id = nil
          @asker = Thread.new { @channel.ask(event(cwd: cwd), pending: @pending, timeout: 5) }
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3

          until (id = @pending.all.first&.id) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep(0.01)
          end

          id
        end

        def answer_for(_question_id) = @asker.value

        def reply(to:, text:, chat_id: OWNER)
          {
            "message" => {
              "chat" => { "id" => chat_id }, "text" => text,
              "reply_to_message" => { "message_id" => to }
            }
          }
        end
      end
    end
  end
end
