# frozen_string_literal: true

module AgentsControl
  module Terminals
    # Backend for sessions that have no terminal at all.
    #
    # This isn't a stub for an exotic edge case: an agent launched from
    # the VS Code extension sits on tty `??` — it has neither a tab nor a
    # pty, and such sessions are often the majority of active ones, not a
    # rare exception.
    #
    # A session like this shows up in the list and can be worked with
    # through hooks — answering questions, reading the transcript. What's
    # off-limits is anything that needs a terminal: sending text, reading
    # the screen, creating a tab.
    class Null < Base
      def name = :none

      def available? = true

      # This backend doesn't enumerate its own sessions: they're
      # supplied by ProcessProbe (terminalless agent processes) and the
      # hook registry.
      def sessions = []
    end
  end
end
