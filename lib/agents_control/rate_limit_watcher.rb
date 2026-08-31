# frozen_string_literal: true

require "time"

module AgentsControl
  # Notices a rate-limit message on an agent's screen and types
  # "continue" itself at the exact moment the limit resets.
  #
  # Three message formats:
  #
  #   5-hour limit reached - resets 3pm (UTC)
  #   You've hit your session limit · resets 2am (Europe/Zurich)
  #   You've hit your weekly limit · resets Oct 9, 10am
  #
  # Goes through the full Registry, not just tmux (unlike ScreenWatcher)
  # — a limit doesn't hit every few seconds, so polling once a minute
  # keeps the cost of scanning iTerm2 via AppleScript low.
  class RateLimitWatcher
    # "limit ... resets [at] <everything to the end of the line>".
    PATTERN = /\blimit\b.{0,60}?\bresets?\b\s*(?:at\s+)?(.+?)\s*$/i

    # A timezone in parentheses at the end of the line, if present — for
    # display to the human. Not accounted for programmatically: Time.parse
    # treats the time as local to the machine the daemon runs on.
    ZONE = /\(([\w\/]+)\)\s*\z/

    # A month name in the rest of the line distinguishes a bare time of
    # day ("3pm", today or tomorrow) from a weekly-limit date ("Oct 9").
    HAS_DATE = /[A-Za-z]{3,}\s+\d{1,2}/

    GRACE = 60
    LINES = 20

    def initialize(registry:, config:, store:, api:, interval: 60, clock: -> { Time.now }, logger: nil)
      @registry = registry
      @config = config
      @store = store
      @api = api
      @interval = interval
      @clock = clock
      @logger = logger
      @running = false
    end

    def start
      return self unless enabled?

      @running = true
      @thread = Thread.new { tick while @running }
      self
    end

    def stop
      @running = false
      @thread&.kill
    end

    def tick
      candidates.each { |session| check(session) } if enabled?
    rescue StandardError => e
      log("failure: #{e.class}: #{e.message}")
    ensure
      sleep(@interval) if @running
    end

    private

    def now = @clock.call

    def enabled? = @config.get("answers.auto_resume_after_limit", true)

    def candidates
      @registry.refresh.agents.reject(&:terminalless?)
    rescue StandardError
      []
    end

    # A limit, once detected, isn't dropped just because the screen
    # currently shows something else — only once it's actually fired. By
    # reset time, the original message has almost certainly scrolled off
    # the screen already, and reset_at has to survive exactly that.
    def check(session)
      spec = detect(@registry.backend_for(session).capture(session.id, lines: LINES))
      key = resume_key(session)
      saved = @store.get(key)

      return remember(session, key, spec) if spec && (saved.nil? || saved["spec"] != spec)
      return unless saved
      return if saved["fired"]

      fire(session, key, saved) if now >= Time.parse(saved["reset_at"]) + GRACE
    end

    def resume_key(session) = "resume:#{session.id}"

    # The last textual match — the one closest to the screen's current
    # state, not a random mention of a limit somewhere in the scrollback.
    def detect(text)
      text.to_s.each_line.map(&:chomp).filter_map { |line| line[PATTERN, 1] }.last
    end

    def remember(session, key, spec)
      reset_at = parse_reset_time(spec)
      return notify_unparseable(session, spec) unless reset_at

      @store.put({ "spec" => spec, "reset_at" => reset_at.iso8601, "fired" => false },
                 ttl: 86_400, key: key)
      notify_detected(session, spec, reset_at)
    end

    def parse_reset_time(spec)
      zone = spec[ZONE, 1]
      clean = spec.sub(ZONE, "").strip
      return nil if clean.empty?

      time = Time.parse(clean, now)

      # A bare time of day in the past means "tomorrow"; a weekly-limit
      # date in the past means "a year has rolled over," not "the reset
      # was yesterday."
      if time < now
        time += clean.match?(HAS_DATE) ? 365 * 86_400 : 86_400
      end

      time
    rescue ArgumentError, TypeError
      nil
    end

    # The session could have closed between detecting the limit and the
    # reset moment — checked right before typing, not trusted from the
    # state at detection time.
    def fire(session, key, saved)
      fresh = @registry.refresh.find(session.id)

      unless fresh&.agent?
        @store.delete(key)
        return
      end

      ok = type_resume(fresh)
      @store.put(saved.merge("fired" => true), ttl: 3600, key: key)

      broadcast("✅ #{fresh.label}: the limit reset, sent \"#{resume_message}\".", session: fresh) if ok
    end

    def type_resume(session)
      backend = @registry.backend_for(session)
      backend.send_text(session.id, resume_message, newline: false) &&
        sleep(0.4).then { backend.send_text(session.id, "", newline: true) }
    end

    def resume_message
      @config.get("answers.resume_message",
                  "Continue where you left off — the previous attempt was rate limited.")
    end

    def notify_detected(session, spec, reset_at)
      broadcast("⏳ #{session.label} hit a limit: \"#{spec}\".\n" \
                "Resets at #{reset_at.strftime('%H:%M %d.%m')} — I'll send \"#{resume_message}\" myself.",
                session: session)
    end

    # Don't spam the same unparseable message on every tick.
    def notify_unparseable(session, spec)
      key = "#{resume_key(session)}:unparsed"
      return if @store.get(key) == spec

      @store.put(spec, ttl: 3600, key: key)
      broadcast("⚠️ #{session.label} looks like it hit a limit, but I couldn't parse the reset time: \"#{spec}\".\n" \
                "Answer manually whenever you see fit.", session: session)
    end

    def broadcast(text, session: nil)
      chats.each do |chat_id|
        sent = @api.send_message(chat_id: chat_id, text: text)
        remember_reply(chat_id, sent, session) if session
      rescue StandardError
        next
      end
    end

    def remember_reply(chat_id, sent, session)
      id = sent.is_a?(Hash) ? sent["message_id"] : nil
      return unless id

      @store.put({ "session_id" => session.id, "cwd" => session.cwd, "label" => session.label },
                 ttl: 30 * 86_400, key: "reply:#{chat_id}:#{id}")
    end

    def chats = Array(@config.get("telegram.allowed_chat_ids", []))

    # log() catches any write failure itself: an exception raised inside
    # a rescue isn't caught by that same rescue, and would kill the
    # thread for good.
    def log(message)
      @logger&.puts("[rate-limit-watcher] #{message}")
    rescue StandardError
      nil
    end
  end
end
