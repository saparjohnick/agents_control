# frozen_string_literal: true

module AgentsControl
  # A normalized event from an agent.
  #
  # The core and the notification channel operate only on this type and
  # know nothing about Claude Code or Codex. An agent adapter's job is to
  # bring its own payload into this shape, and that's the extent of its
  # knowledge of the outside world.
  #
  # The shape wasn't picked arbitrarily: Claude Code and Codex independently
  # converged on nearly the same set of events and the same way of
  # returning a decision, so this describes an existing commonality rather
  # than a speculative abstraction.
  class Event
    KINDS = %i[
      needs_permission
      needs_input
      finished
      error
      started
      ended
      progress
    ].freeze

    attr_reader :kind, :agent, :session_id, :cwd, :text, :options,
                :tool_name, :tool_input, :transcript_path, :raw

    def initialize(kind:, agent:, session_id:, cwd: nil, text: nil, options: [],
                   tool_name: nil, tool_input: nil, transcript_path: nil, raw: {})
      raise ArgumentError, "unknown event kind: #{kind}" unless KINDS.include?(kind)

      @kind = kind
      @agent = agent
      @session_id = session_id
      @cwd = cwd
      @text = text
      @options = options
      @tool_name = tool_name
      @tool_input = tool_input
      @transcript_path = transcript_path
      @raw = raw
    end

    # Does a human need to weigh in. Everything else is background info.
    def question? = %i[needs_permission needs_input].include?(kind)

    # AskUserQuestion is structurally a permission request (it goes
    # through the same PermissionRequest hook as any tool call), but
    # answering it means picking one of its listed options — allow/deny
    # doesn't apply, and neither does the usual reply-becomes-hook-response path.
    def ask_user_question? = tool_name == "AskUserQuestion"

    # Short name of where this is happening. The full path in a
    # notification only gets in the way — what matters in a list is
    # recognizing the project, not seeing /Users/...
    def label
      return File.basename(cwd) if cwd && !cwd.empty?

      session_id.to_s[0, 8]
    end

    # Description of what the agent is about to do.
    def summary
      case kind
      when :needs_permission then permission_summary
      when :needs_input then text.to_s
      when :error then "error: #{text}"
      else text.to_s
      end
    end

    private

    # AskUserQuestion isn't a "permission" — it's a question with options
    # to pick from; the tool name won't tell a human anything, the
    # question itself is what matters.
    def permission_summary
      return describe_questions if ask_user_question?

      "#{tool_name}: #{describe_tool}"
    end

    # Every tool has its own main field; show that, not the whole JSON.
    def describe_tool
      return "" unless tool_input.is_a?(Hash)

      value = tool_input["command"] || tool_input["file_path"] ||
              tool_input["pattern"] || tool_input["url"]

      value.to_s
    end

    def describe_questions
      questions = tool_input.is_a?(Hash) ? tool_input["questions"] : nil
      return "" unless questions.is_a?(Array)

      questions.map { |question| describe_question(question) }.join("\n\n")
    end

    def describe_question(question)
      lines = ["#{question['header']}: #{question['question']}"]

      Array(question["options"]).each_with_index do |option, index|
        lines << "#{index + 1}. #{option['label']} — #{option['description']}"
      end

      lines.join("\n")
    end
  end
end
