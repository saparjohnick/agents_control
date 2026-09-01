# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "tmpdir"
require "fileutils"

# A test run has no business touching the user's real files.
#
# This isn't precaution for its own sake: tests once overwrote a real
# config and wrote hooks into a real settings.json — all it took was
# creating a Config with no explicit path. A mistake like that isn't
# caught right away, and it looks like "the tool went insane."
#
# The variables are set before the library loads: paths are computed from them.
SANDBOX = Dir.mktmpdir("agents_control_test")
ENV["XDG_CONFIG_HOME"] = File.join(SANDBOX, "config")
ENV["XDG_STATE_HOME"] = File.join(SANDBOX, "state")
ENV["CLAUDE_CONFIG_DIR"] = File.join(SANDBOX, "claude")
FileUtils.mkdir_p(ENV.values_at("XDG_CONFIG_HOME", "XDG_STATE_HOME", "CLAUDE_CONFIG_DIR"))

require "minitest/autorun"

Minitest.after_run { FileUtils.remove_entry(SANDBOX) if File.directory?(SANDBOX) }
require "agents_control"
require_relative "fixtures"

module AgentsControl
  # Stands in for Executor, so tests never touch iTerm2, tmux, or ps.
  #
  # Responses are keyed by a substring or regex matched against any
  # element of argv: FakeExecutor.new("list-panes" => Fixtures::TMUX_PANES).
  class FakeExecutor
    attr_reader :calls

    def initialize(responses = {})
      @responses = responses
      @calls = []
      @sequence_positions = Hash.new(0)
    end

    def run(*argv, stdin: nil, timeout: nil)
      @calls << { argv: argv, stdin: stdin, timeout: timeout }

      matcher, response = @responses.find { |m, _| matches?(m, argv) }
      build(resolve(matcher, response))
    end

    # The arguments of the call that matched a given substring.
    def call_with(fragment)
      @calls.find { |call| matches?(fragment, call[:argv]) }
    end

    def called?(fragment) = !call_with(fragment).nil?

    private

    # An Array response is a sequence: each call to a matcher advances
    # one step through it, repeating the last element once exhausted.
    # Needed for anything that reads the same target twice and expects
    # to see it change in between, like a before/after screen capture.
    def resolve(matcher, response)
      return response unless response.is_a?(Array)

      index = @sequence_positions[matcher]
      @sequence_positions[matcher] += 1
      response[[index, response.size - 1].min]
    end

    # A callable matcher gets the full argv and decides for itself —
    # needed when a plain substring would match more than one distinct
    # kind of call (e.g. a session id appears in both its capture calls
    # and its send_text calls, but only capture should advance an
    # Array-sequenced response meant to represent that session's screen
    # changing over time).
    def matches?(matcher, argv)
      return matcher.call(argv) if matcher.respond_to?(:call)

      argv.any? do |arg|
        matcher.is_a?(Regexp) ? arg.to_s.match?(matcher) : arg.to_s.include?(matcher.to_s)
      end
    end

    def build(response)
      case response
      when nil then Executor::Result.new(stdout: "", stderr: "", status: 1)
      when Executor::Result then response
      when Integer then Executor::Result.new(stdout: "", stderr: "", status: response)
      else Executor::Result.new(stdout: response.to_s, stderr: "", status: 0)
      end
    end
  end

  # Input that plays back a pre-recorded set of keystrokes. A real
  # terminal isn't needed to test the editor.
  #
  # Each argument is one keystroke: the bytes inside it arrive together,
  # with a pause between keystrokes. This is how a real terminal
  # behaves, and it's the only reason a lone Esc can be told apart from
  # the start of an arrow-key sequence.
  class Keys
    def initialize(*presses) = @presses = presses.map(&:bytes)

    def getbyte
      @presses.shift while @presses.first&.empty?
      @presses.first&.shift
    end

    def wait_readable(_timeout) = @presses.first&.any? ? self : nil

    def raw = yield
  end

  # Network-free transport: hands back canned responses in order.
  class FakeHttp
    Response = Struct.new(:code, :body)

    attr_reader :calls

    def initialize(*responses)
      @responses = responses.flatten
      @calls = []
    end

    def post(uri, params, read_timeout:)
      @calls << { uri: uri.to_s, params: params, read_timeout: read_timeout }

      response = @responses.shift
      raise response if response.is_a?(Exception)

      response || Response.new("200", JSON.generate({ ok: true, result: [] }))
    end

    def self.ok(result) = Response.new("200", JSON.generate({ ok: true, result: result }))

    def self.fail(code, description, **extra)
      Response.new("200", JSON.generate({ ok: false, error_code: code,
                                          description: description }.merge(extra)))
    end
  end

  # A Telegram client with no Telegram: remembers what was sent.
  class FakeApi
    attr_reader :sent, :answered
    attr_accessor :fail_markdown_once

    def initialize
      @sent = []
      @answered = []
      @fail_markdown_once = false
    end

    def send_message(chat_id:, text:, reply_markup: nil, parse_mode: nil)
      if parse_mode && @fail_markdown_once
        @fail_markdown_once = false
        raise Channels::Telegram::Api::Error,
              "sendMessage: Bad Request: can't parse entities: simulated failure"
      end

      @sent << { chat_id: chat_id, text: text, markup: reply_markup, parse_mode: parse_mode }
      { "message_id" => @sent.size }
    end

    def answer_callback_query(id, text: nil, show_alert: false)
      @answered << { id: id, text: text, show_alert: show_alert }
      true
    end

    def redact(text) = text

    def last_text = @sent.last&.fetch(:text)

    def texts = @sent.map { |message| message[:text] }
  end
end
