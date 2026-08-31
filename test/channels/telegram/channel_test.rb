# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  module Channels
    module Telegram
      class ChannelTest < Minitest::Test
        def setup
          @dir = Dir.mktmpdir
          @api = FakeApi.new
          @store = Store.new(path: File.join(@dir, "store.json"))
          @config = Config.new({ "telegram" => { "allowed_chat_ids" => [424_242] } })
          @channel = Channel.new(api: @api, store: @store, config: @config)
        end

        def teardown = FileUtils.remove_entry(@dir)

        # A long agent message usually ends with the point — the
        # question itself or the result of the work. Clipping the tail
        # means hiding exactly what the notification was sent for.
        def test_long_notification_keeps_the_tail_not_the_head
          text = "#{'intro ' * 200}THE MOST IMPORTANT QUESTION AT THE END"

          @channel.notify(event(text: text))

          assert_includes @api.last_text, "THE MOST IMPORTANT QUESTION AT THE END"
        end

        def test_long_question_keeps_the_tail_too
          text = "#{'context ' * 200}what should I do next?"

          Thread.new { @channel.ask(event(text: text), pending: Pending.new, timeout: 0.3) }
          wait_for_message

          assert_includes @api.last_text, "what should I do next?"
        end

        # ── formatting ──────────────────────────────────────────────────────
        #
        # This is the original complaint: an agent's last message almost
        # always carries code or a list of changes, and it's unreadable
        # without formatting.

        def test_agent_code_arrives_as_a_formatted_block
          text = "Done:\n\n```ruby\ndef f; end\n```"

          @channel.notify(event(text: text))

          assert_equal "MarkdownV2", @api.sent.last[:parse_mode]
          assert_includes @api.last_text, "```ruby\ndef f; end\n```"
        end

        def test_underscores_in_agent_text_are_escaped_not_swallowed
          @channel.notify(event(text: "field filePath_v2 not found"))

          assert_includes @api.last_text, "filePath\\_v2"
        end

        # An open hook holds the agent blocked until a reply arrives —
        # losing a notification to a formatting error is not acceptable
        # under any circumstance, so a plain-text fallback is mandatory.
        def test_falls_back_to_plain_text_when_markdown_is_rejected
          @api.fail_markdown_once = true

          @channel.notify(event(text: "whatever"))

          assert_equal 1, @api.sent.size
          assert_nil @api.sent.last[:parse_mode]
        end

        def test_short_text_is_not_clipped_at_all
          @channel.notify(event(text: "short"))

          assert_includes @api.last_text, "short"
          refute_includes @api.last_text, "…"
        end

        # A long agent response is delivered in full — as several
        # messages in a row, without losing a single character.
        def test_long_text_is_sent_as_several_messages_without_losing_content
          @channel.notify(event(text: "x" * 9000))

          assert_operator @api.sent.size, :>, 1
          assert_equal 9000, @api.texts.join.count("x")
        end

        # A continuation is marked so it doesn't look like a separate,
        # unrelated notification — while the first chunk stays clean, with no marker.
        def test_continuation_chunks_are_marked
          @channel.notify(event(text: "word " * 2000))

          assert_operator @api.sent.size, :>, 1
          refute_match(/^↪️/, @api.sent.first[:text])
          assert_match(/^↪️ 2\/\d+/, @api.sent[1][:text])
        end

        # Buttons logically belong to the whole message — attaching them
        # to every chunk would mean offering to press "allow" before the
        # question is even fully read.
        def test_buttons_attach_only_to_the_last_chunk
          markup = { inline_keyboard: [[{ text: "ok", callback_data: "x" }]] }

          @channel.send(:broadcast, "word " * 2000, markup: markup)

          assert_operator @api.sent.size, :>, 1
          assert_nil @api.sent.first[:markup]
          assert_equal markup, @api.sent.last[:markup]
        end

        # A reply can target any of the chunks, not just the last one —
        # replying to the middle of a long response must not get lost.
        def test_every_chunk_is_a_valid_reply_target
          @channel.notify(event(text: "word " * 2000))

          assert_operator @api.sent.size, :>, 1
          (1..@api.sent.size).each do |message_id|
            refute_nil @store.get("reply:424242:#{message_id}")
          end
        end

        # Every message is tagged with the session — otherwise, in a chat
        # with several agents, it's unclear who's asking.
        def test_notification_carries_the_session_tag
          @channel.notify(event)

          assert_match(/#\h{4}/, @api.last_text)
        end

        # ── AskUserQuestion ──────────────────────────────────────────────
        #
        # This isn't a request for tool access, it's a question with
        # answer options — neither "Allow"/"Deny" picks one of them, and
        # a reply to the message never reaches it: it can only be
        # answered in the terminal.

        def test_ask_user_question_gets_no_permission_buttons
          Thread.new { @channel.ask(ask_user_question_event, pending: Pending.new, timeout: 0.3) }
          wait_for_message

          rows = @api.sent.last[:markup][:inline_keyboard]

          refute(rows.flatten.any? { |b| b[:text].include?("Allow") })
        end

        def test_ask_user_question_still_offers_the_context_button
          Thread.new { @channel.ask(ask_user_question_event, pending: Pending.new, timeout: 0.3) }
          wait_for_message

          rows = @api.sent.last[:markup][:inline_keyboard]

          assert(rows.flatten.any? { |b| b[:text].include?("context") })
        end

        def test_ask_user_question_reply_hint_points_to_the_terminal
          Thread.new { @channel.ask(ask_user_question_event, pending: Pending.new, timeout: 0.3) }
          wait_for_message

          assert_includes @api.last_text, "Answer in the terminal"
          refute_includes @api.last_text, "reply to this message"
        end

        def test_ask_user_question_question_and_options_reach_the_message
          Thread.new { @channel.ask(ask_user_question_event, pending: Pending.new, timeout: 0.3) }
          wait_for_message

          text = unescape_markdown(@api.last_text)

          assert_includes text, "Short or detailed?"
          assert_includes text, "Detailed — Question and options"
        end

        # A regular permission request (not AskUserQuestion) must not
        # lose its "Allow"/"Deny" buttons because of this branch.
        def test_a_regular_permission_request_keeps_its_buttons
          event = permission_event(tool_name: "Bash", tool_input: { "command" => "npm run build" })
          Thread.new { @channel.ask(event, pending: Pending.new, timeout: 0.3) }
          wait_for_message

          rows = @api.sent.last[:markup][:inline_keyboard]

          assert(rows.flatten.any? { |b| b[:text].include?("Allow") })
        end

        private

        def event(text: "question")
          Agents::ClaudeCode.new.to_event(
            Fixtures::HOOK_STOP.merge("last_assistant_message" => text)
          )
        end

        def permission_event(tool_name:, tool_input:)
          Agents::ClaudeCode.new.to_event(
            Fixtures::HOOK_PERMISSION.merge("tool_name" => tool_name, "tool_input" => tool_input)
          )
        end

        def ask_user_question_event
          permission_event(
            tool_name: "AskUserQuestion",
            tool_input: {
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

        def unescape_markdown(text)
          text.to_s.gsub(/\\([_*\[\]()~`>#+\-=|{}.!\\])/, '\1')
        end

        def wait_for_message(seconds: 2)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          sleep(0.01) until @api.sent.any? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        end
      end
    end
  end
end
