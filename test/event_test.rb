# frozen_string_literal: true

require "test_helper"

module AgentsControl
  class EventTest < Minitest::Test
    def test_permission_summary_shows_the_tool_and_its_main_field
      event = permission_event(tool_name: "Bash", tool_input: { "command" => "rm -rf build/" })

      assert_equal "Bash: rm -rf build/", event.summary
    end

    # AskUserQuestion is a question with options, not a request for
    # access to a tool: the tool name won't tell a human anything, what
    # matters is the question itself and its options.
    def test_ask_user_question_summary_shows_the_question_and_its_options
      event = permission_event(
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

      assert_equal(
        "Format: Short or detailed?\n1. Short — Just the question\n2. Detailed — Question and options",
        event.summary
      )
    end

    def test_ask_user_question_summary_joins_several_questions
      event = permission_event(
        tool_name: "AskUserQuestion",
        tool_input: {
          "questions" => [
            { "header" => "A", "question" => "First?", "options" => [{ "label" => "Yes", "description" => "" }] },
            { "header" => "B", "question" => "Second?", "options" => [{ "label" => "No", "description" => "" }] }
          ]
        }
      )

      assert_equal "A: First?\n1. Yes — \n\nB: Second?\n1. No — ", event.summary
    end

    def test_ask_user_question_with_missing_questions_does_not_raise
      event = permission_event(tool_name: "AskUserQuestion", tool_input: {})

      assert_equal "", event.summary
    end

    def test_permission_summary_with_no_recognised_field_is_still_safe
      event = permission_event(tool_name: "WebFetch", tool_input: { "url" => nil })

      assert_equal "WebFetch: ", event.summary
    end

    def test_needs_input_summary_is_the_raw_text
      event = Event.new(kind: :needs_input, agent: :claude_code, session_id: "s1", text: "Continue?")

      assert_equal "Continue?", event.summary
    end

    def test_error_summary_is_prefixed
      event = Event.new(kind: :error, agent: :claude_code, session_id: "s1", text: "usage limit reached")

      assert_equal "error: usage limit reached", event.summary
    end

    private

    def permission_event(tool_name:, tool_input:)
      Event.new(kind: :needs_permission, agent: :claude_code, session_id: "s1",
               tool_name: tool_name, tool_input: tool_input)
    end
  end
end
