# frozen_string_literal: true

require "date"

module AgentsControl
  module Anchors
    # Placing rate-limit windows on a schedule.
    #
    # A five-hour window starts at the minute of the first message and
    # expires exactly three hundred minutes later. This tool doesn't add
    # a single extra token — it moves window boundaries to where they're
    # convenient. The difference is between "the window reset at 2:37pm,
    # mid-work" and "windows at exactly 7am, noon, 5pm."
    #
    # Pinging has to use a cheap model. The five-hour window is shared
    # across the account, but weekly limits are tracked per model family:
    # an anchor on opus would spend the scarcest bucket for an effect
    # haiku gives for free.
    class Scheduler
      DAYS = %w[sun mon tue wed thu fri sat].freeze

      # How late it's still worth catching up on a missed slot. If the
      # laptop slept and woke an hour later, an anchor is already
      # pointless — the window will start somewhere other than planned regardless.
      GRACE = 300

      # How often to wake up and check the clock.
      TICK = 30

      def initialize(config:, store:, executor: Executor.new, clock: -> { Time.now }, logger: nil)
        @config = config
        @store = store
        @executor = executor
        @clock = clock
        @logger = logger
        @running = false
      end

      # The thread always starts; whether it's enabled is checked on
      # every tick — so a setting changed from the menu takes effect
      # without restarting the daemon.
      def start
        @running = true
        @thread = Thread.new do
          tick while @running
        end

        self
      end

      def stop
        @running = false
        @thread&.kill
      end

      # One pass: fire if the time has come.
      def tick(now = @clock.call)
        due_slot(now)&.then { |slot| fire(slot, now) } if enabled?
      rescue StandardError => e
        log("failure: #{e.class}: #{e.message}")
      ensure
        sleep(TICK) if @running
      end

      # The next firing time — for doctor and /status.
      def next_run_at(from = @clock.call)
        (0..7).each do |offset|
          date = from.to_date + offset
          next unless enabled_day?(date)

          slot = slots_on(date).find { |time| time > from }
          return slot if slot
        end

        nil
      end

      # Whether a window is currently active. Known because the daemon
      # sees every agent event: any of them means a human was just working.
      def window_active?(now = @clock.call)
        last = @store.get(ACTIVITY_KEY)
        return false unless last

        now.to_i - last.to_i < WINDOW
      end

      ACTIVITY_KEY = "agent:last_activity"
      WINDOW = 5 * 3600

      private

      def enabled? = @config.get("anchors.enabled", false)

      def schedule = Array(@config.get("anchors.schedule", []))

      def enabled_day?(date)
        days = Array(@config.get("anchors.days", DAYS)).map(&:to_s)

        days.include?(DAYS[date.wday])
      end

      def slots_on(date)
        schedule.filter_map do |entry|
          hour, minute = entry.to_s.split(":").map(&:to_i)
          next if hour.nil?

          Time.new(date.year, date.month, date.day, hour, minute, 0)
        end.sort
      end

      def due_slot(now)
        return nil unless enabled_day?(now.to_date)

        slots_on(now.to_date).find do |slot|
          now >= slot && now - slot < GRACE && !fired?(slot)
        end
      end

      def fired?(slot) = !@store.get(slot_key(slot)).nil?

      def slot_key(slot) = "anchor:#{slot.strftime('%Y-%m-%d %H:%M')}"

      def fire(slot, now)
        # The marker is set before the call, not after: if the ping
        # hangs or the process crashes, retrying it half a minute later
        # is pointless.
        @store.put(now.to_i, ttl: 86_400 * 2, key: slot_key(slot))

        if @config.get("anchors.skip_if_window_active", true) && window_active?(now)
          return log("skipping #{slot.strftime('%H:%M')}: window is already open")
        end

        ping(slot)
      end

      def ping(slot)
        binary = Which.find("claude")
        return log("couldn't find claude — anchor skipped") unless binary

        model = @config.get("anchors.model", "haiku")
        result = @executor.run(binary, "-p", "ok", "--model", model,
                               "--max-turns", "1", timeout: 120)

        if result.success?
          log("anchor #{slot.strftime('%H:%M')} on #{model}: window opened")
        else
          log("anchor #{slot.strftime('%H:%M')} failed: #{result.stderr.to_s[0, 120]}")
        end
      end

      # log() catches any write failure itself: an exception raised
      # inside a rescue isn't caught by that same rescue, and would kill
      # the thread for good.
      def log(message)
        @logger&.puts("[anchors] #{message}")
      rescue StandardError
        nil
      end
    end
  end
end
