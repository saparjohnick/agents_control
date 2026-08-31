# frozen_string_literal: true

module AgentsControl
  module Agents
    # The agent adapter contract.
    #
    # Deliberately tiny. The core is written for a weak agent — one with
    # nothing but a process in a terminal. An agent with full hooks
    # (Claude Code, Codex) just enriches the same events, without
    # changing their shape.
    #
    # If adding a new agent requires changes outside its adapter, the
    # registry, and the hook installer, the seam was drawn wrong.
    class Base
      class << self
        # Name in the registry and in Session#agent.
        def key = raise(NotImplementedError)

        # Executable names, matched by process basename.
        def binaries = []

        # Whether this adapter can parse a hook payload of this shape.
        def handles?(_payload) = false
      end

      def key = self.class.key

      # What the adapter can do. The core checks this list, not the
      # agent's name.
      #
      #   :push               — pushes events itself, no polling needed
      #   :blocking_reply     — can wait for an answer and feed it back to the session
      #   :structured_options — brings a ready-made list of answer choices
      def capabilities = []

      def supports?(capability) = capabilities.include?(capability)

      # hook payload → Event, or nil if the event isn't interesting.
      def to_event(_payload) = raise(NotImplementedError)

      # Reply → the hook response body.
      def to_response(_event, _reply) = raise(NotImplementedError)

      # Register itself in the agent's config so events start arriving.
      def install!(_url, secret: nil) = raise(NotImplementedError)

      def uninstall! = raise(NotImplementedError)

      def installed? = false
    end
  end
end
