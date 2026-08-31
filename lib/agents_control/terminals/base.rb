# frozen_string_literal: true

module AgentsControl
  module Terminals
    # An operation this backend doesn't have. For example, a tabless
    # session has nothing to create or read from the screen.
    class Unsupported < StandardError; end

    # The terminal backend contract.
    #
    # There are three implementations right now (iTerm2, tmux, null), and
    # they're chosen not globally but per session: the same machine can
    # hold bare iTerm2 tabs, tmux panes, and VS Code sessions with no
    # terminal at all, all at once.
    #
    # Every method must be safe when the backend is unavailable: return an
    # empty result or false, never raise out to the caller or hang it.
    class Base
      def initialize(executor: Executor.new, probe: nil)
        @executor = executor
        @probe = probe
      end

      # The backend's symbolic name — ends up in Session#backend.
      def name = raise(NotImplementedError)

      # Whether the backend can answer right now.
      # Must have no side effects: in particular, must not launch an app
      # the user hasn't already opened.
      def available? = raise(NotImplementedError)

      # [Session] — all of this backend's tabs/panes.
      def sessions = raise(NotImplementedError)

      def create_tab(cwd: nil, command: nil) = raise(Unsupported, "#{name}: creating a tab is not supported")

      def send_text(_id, _text, newline: true) = raise(Unsupported, "#{name}: sending input is not supported")

      def capture(_id, lines: 200) = raise(Unsupported, "#{name}: reading the screen is not supported")

      def focus(_id) = raise(Unsupported, "#{name}: focusing is not supported")

      def close(_id) = raise(Unsupported, "#{name}: closing is not supported")

      private

      attr_reader :executor

      # The registry hands over its own probe, so the process tree is
      # read once per pass instead of separately by each backend.
      def probe
        @probe ||= ProcessProbe.new(executor: executor)
      end

      # Field and record separators.
      #
      # Plain `|` or a tab won't do: a tab title holds arbitrary text
      # that the user or the agent writes however they like — anything
      # can show up there, including newlines. The US and RS control
      # characters never appear in that text.
      FIELD = "\x1F"
      RECORD = "\x1E"

      def parse_records(output, fields)
        output.split(RECORD).filter_map do |record|
          next if record.strip.empty?

          values = record.split(FIELD, -1)
          next if values.size < fields.size

          fields.zip(values).to_h
        end
      end
    end
  end
end
