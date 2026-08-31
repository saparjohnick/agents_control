# frozen_string_literal: true

module AgentsControl
  # Decides what to do with an agent event: stay quiet, notify, or ask.
  #
  # All the policy lives here, because it's the one part of the system
  # people actually want to tune with settings. Agent adapters only turn
  # a payload into an Event, a channel only displays it — Dispatcher does the thinking.
  class Dispatcher
    # The key distinction: is a human at the keyboard.
    #
    # While they are, intercepting permission requests is counterproductive:
    # they'll answer in the terminal faster than they can reach for their
    # phone, and a blocked hook keeps the dialog from ever reaching the
    # screen at all. So by default this only notifies, and interception
    # is turned on explicitly — with /away before stepping out.
    def initialize(agents:, channel:, config:, pending: nil, logger: nil)
      @agents = agents
      @channel = channel
      @config = config
      @pending = pending || Pending.new
      @logger = logger
    end

    attr_reader :pending

    # Returns the hook response body. An empty hash means "no decision" —
    # the agent behaves as it would without us.
    def handle(payload)
      agent = @agents.find { |candidate| candidate.class.handles?(payload) }
      return {} unless agent

      event = agent.to_event(payload)
      return {} unless event

      reply = decide(event)
      return {} unless reply

      agent.to_response(event, reply)
    rescue StandardError => e
      log("failed to handle event: #{e.class}: #{e.message}")
      {}
    end

    private

    def decide(event)
      unless event.question?
        notify(event)
        return nil
      end

      # A human is at the keyboard — don't get in their way, just notify.
      unless away?
        notify(event)
        return nil
      end

      automatic(event) || ask(event)
    end

    def away? = @config.get("answers.away", false)

    # What can be decided without a human.
    def automatic(event)
      case event.kind
      when :needs_permission then automatic_permission(event)
      when :needs_input then automatic_input(event)
      end
    end

    def automatic_permission(event)
      return nil unless @config.get("answers.auto_approve_permissions", false)
      # The forbidden list overrides any automatic setting: these things
      # a human confirms in person, whatever the settings say.
      return nil if forbidden?(event)

      Reply.allow
    end

    # A "continue" reply is safe — it grants the agent no new
    # permissions, it only clears the question "should I go on?" That's
    # why it's on by default, unlike automatic tool approval.
    def automatic_input(event)
      return nil unless @config.get("answers.auto_continue", true)
      return nil unless continuation?(event.text)

      Reply.text("Continue.")
    end

    CONTINUATION = /(продолж|continue|proceed|shall i|идти дальше|go ahead)/i

    # Signs that a human is being offered a choice, not asked permission to go on.
    ALTERNATIVE = /(\bили\b|\bлибо\b|\bor\b|^\s*\d[.)]\s|\bвариант)/i

    # A "should I continue?" question differs from a substantive one in
    # having no subject — it's answerable without reading any context.
    #
    # The word "continue" alone isn't enough for this: "Should I continue
    # the refactor, or show the plan first?" is a choice, and answering
    # "continue" on the human's behalf there means making the decision
    # for them. So the presence of an alternative overrides the
    # automation, even when the word matches.
    def continuation?(text)
      value = text.to_s
      return false if value.empty? || value.length > 300
      return false if value.match?(ALTERNATIVE)

      value.match?(CONTINUATION)
    end

    def forbidden?(event)
      haystack = [event.tool_name, event.tool_input.to_s].join(" ").downcase

      Array(@config.get("answers.never_auto_approve", [])).any? do |needle|
        haystack.include?(needle.to_s.downcase)
      end
    end

    def ask(event)
      timeout = @config.get("answers.reply_timeout", 600)
      log("asking: #{event.label} — #{event.summary[0, 80]}")

      reply = @channel.ask(event, pending: @pending, timeout: timeout)

      # Silence is a refusal, not a permission. If nobody answered while
      # the owner was out, the action doesn't happen.
      log("no answer, declining: #{event.label}") if reply.none?
      reply
    end

    def notify(event)
      return unless notifiable?(event)

      log("notifying: #{event.label} — #{event.summary.to_s[0, 80]}")
      @channel.notify(event)
    rescue StandardError => e
      log("failed to notify: #{e.message}")
    end

    # Not every event can make noise: an agent calls tools dozens of
    # times per turn. Only report what a human actually needs to know about.
    def notifiable?(event)
      case event.kind
      when :error then true
      when :needs_permission, :needs_input then @config.get("answers.notify_when_present", true)
      else false
      end
    end

    def log(message) = @logger&.puts("[dispatcher] #{message}")
  end
end
