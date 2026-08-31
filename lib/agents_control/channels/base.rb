# frozen_string_literal: true

module AgentsControl
  module Channels
    # The notification channel contract.
    #
    # There's only one implementation right now — Telegram. The interface
    # is still broken out because the core must not know about buttons
    # and chats: it operates on an event and a reply, and how that's
    # shown to a human is the channel's concern.
    #
    # A second implementation (ntfy, Slack, whatever) is deliberately not
    # invented ahead of time: the seam is marked out, but guessing its
    # shape before a real need shows up is exactly the kind of
    # complication this project avoids.
    class Base
      # Notify, expecting nothing back.
      def notify(_event) = raise(NotImplementedError)

      # Ask a question and return a Reply, or nil once the timeout expires.
      def ask(_event, timeout:) = raise(NotImplementedError)

      # Whether the channel is ready to work: has a token, has someone to talk to.
      def ready? = raise(NotImplementedError)
    end
  end
end
