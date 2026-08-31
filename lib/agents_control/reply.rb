# frozen_string_literal: true

module AgentsControl
  # A human's answer to an event.
  #
  # Also agent-neutral: turning it into the right JSON shape is the
  # adapter's job. Telegram only ever knows these four kinds.
  class Reply
    KINDS = %i[allow deny text none].freeze

    attr_reader :kind, :text, :remember

    def self.allow(remember: false) = new(kind: :allow, remember: remember)
    def self.deny(text = nil) = new(kind: :deny, text: text)
    def self.text(value) = new(kind: :text, text: value)

    # Nobody answered. A distinct kind rather than nil: silence is itself
    # a decision, and it's treated as a refusal — but it's still worth
    # distinguishing from an explicit "no" in the message shown to the user.
    def self.none = new(kind: :none)

    def initialize(kind:, text: nil, remember: false)
      raise ArgumentError, "unknown reply kind: #{kind}" unless KINDS.include?(kind)

      @kind = kind
      @text = text
      @remember = remember
    end

    def allow? = kind == :allow
    def deny? = kind == :deny
    def text? = kind == :text
    def none? = kind == :none

    # Whether to allow the tool. Silence is not permission: if nobody
    # answered while the owner was out, the action doesn't happen.
    def permits? = allow?

    def to_h = { kind: kind, text: text, remember: remember }
  end
end
