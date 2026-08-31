# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  module Anchors
    class SchedulerTest < Minitest::Test
      # Monday, 10:00.
      MONDAY = Time.new(2026, 8, 10, 10, 0, 0)

      def setup
        @dir = Dir.mktmpdir
        @store = Store.new(path: File.join(@dir, "store.json"))
        @executor = FakeExecutor.new("claude" => "ok")
        @now = MONDAY
      end

      def teardown = FileUtils.remove_entry(@dir)

      # ── schedule ────────────────────────────────────────────────────

      def test_next_run_is_the_upcoming_slot_today
        assert_equal Time.new(2026, 8, 10, 12, 0, 0), build.next_run_at
      end

      def test_after_the_last_slot_moves_to_the_next_day
        @now = Time.new(2026, 8, 10, 18, 0, 0)

        assert_equal Time.new(2026, 8, 11, 7, 0, 0), build.next_run_at
      end

      # Weekends are skipped: work windows are needed on work days.
      def test_skips_days_that_are_not_enabled
        @now = Time.new(2026, 8, 14, 18, 0, 0) # Friday evening

        assert_equal Time.new(2026, 8, 17, 7, 0, 0), build.next_run_at, "should be Monday"
      end

      def test_no_schedule_means_no_next_run
        assert_nil build(schedule: []).next_run_at
      end

      # ── firing ──────────────────────────────────────────────────────

      def test_fires_when_the_slot_arrives
        @now = Time.new(2026, 8, 10, 12, 0, 5)
        build.tick(@now)

        assert @executor.called?("claude")
      end

      # The five-hour window is shared across the account, but weekly
      # limits are tracked per model family: an anchor with an expensive
      # model spends the scarce bucket for an effect a cheap one gives for free.
      def test_pings_with_the_cheap_model
        @now = Time.new(2026, 8, 10, 12, 0, 5)
        build.tick(@now)

        argv = @executor.call_with("claude")[:argv]

        assert_includes argv, "haiku"
        assert_includes argv, "-p"
        assert_includes argv, "--max-turns"
      end

      def test_does_not_fire_before_the_slot
        build.tick(Time.new(2026, 8, 10, 11, 59, 0))

        refute @executor.called?("claude")
      end

      def test_fires_only_once_per_slot
        scheduler = build
        3.times { scheduler.tick(Time.new(2026, 8, 10, 12, 0, 10)) }

        assert_equal 1, @executor.calls.count { |c| c[:argv].join.include?("claude") }
      end

      # The laptop slept and woke an hour later — the anchor is already
      # pointless, the window will start somewhere other than planned regardless.
      def test_does_not_chase_a_long_missed_slot
        build.tick(Time.new(2026, 8, 10, 13, 30, 0))

        refute @executor.called?("claude")
      end

      # ── window already open ──────────────────────────────────────────────

      # The daemon sees every agent event, so it knows when a human last
      # worked — no need to poll anything.
      def test_skips_the_ping_when_a_window_is_already_open
        @store.put((Time.new(2026, 8, 10, 11, 40, 0)).to_i,
                   ttl: 86_400, key: Scheduler::ACTIVITY_KEY)

        build.tick(Time.new(2026, 8, 10, 12, 0, 5))

        refute @executor.called?("claude"), "no reason to burn quota — the window is already open"
      end

      def test_stale_activity_does_not_block_the_ping
        # Worked six hours ago — the window expired long since.
        @store.put((Time.new(2026, 8, 10, 6, 0, 0)).to_i,
                   ttl: 86_400, key: Scheduler::ACTIVITY_KEY)

        build.tick(Time.new(2026, 8, 10, 12, 0, 5))

        assert @executor.called?("claude")
      end

      def test_skipping_can_be_switched_off
        @store.put((Time.new(2026, 8, 10, 11, 40, 0)).to_i,
                   ttl: 86_400, key: Scheduler::ACTIVITY_KEY)

        build(extra: { "skip_if_window_active" => false }).tick(Time.new(2026, 8, 10, 12, 0, 5))

        assert @executor.called?("claude")
      end

      # ── robustness ──────────────────────────────────────────────────────

      # The marker is set before the call: if the ping hangs or the
      # process crashes, retrying it half a minute later is pointless.
      def test_a_failed_ping_is_not_retried_in_a_loop
        executor = FakeExecutor.new("claude" => 1)
        scheduler = build(executor: executor)

        3.times { scheduler.tick(Time.new(2026, 8, 10, 12, 0, 10)) }

        assert_equal 1, executor.calls.count { |c| c[:argv].join.include?("claude") }
      end

      def test_disabled_scheduler_does_nothing
        build(extra: { "enabled" => false }).tick(Time.new(2026, 8, 10, 12, 0, 5))

        refute @executor.called?("claude")
      end

      # The setting is checked on every tick, not once at startup: turned
      # on later from the menu, it has to work without a restart.
      def test_enabling_later_takes_effect_without_a_restart
        config = Config.new({
                              "anchors" => {
                                "enabled" => false, "model" => "haiku",
                                "schedule" => ["12:00"], "days" => %w[mon tue wed thu fri]
                              }
                            })
        scheduler = Scheduler.new(config: config, store: @store,
                                  executor: @executor, clock: -> { @now })

        scheduler.tick(Time.new(2026, 8, 10, 12, 0, 5))
        refute @executor.called?("claude"), "disabled anchors must not fire"

        config.set("anchors.enabled", true)
        scheduler.tick(Time.new(2026, 8, 10, 12, 1, 0))

        assert @executor.called?("claude"), "enabled ones should, without a restart"
      end

      # ── robustness ─────────────────────────────────────────────────────

      # A failure in the log write itself must not escape the rescue
      # that handles it — or it would kill the thread for good.
      def test_a_broken_store_and_a_broken_logger_do_not_kill_the_thread
        store = Object.new
        def store.get(_key) = raise("disk full")

        logger = Object.new
        def logger.puts(_msg) = raise("log unwritable too")

        scheduler = Scheduler.new(
          config: Config.new({ "anchors" => { "enabled" => true, "schedule" => ["12:00"],
                                               "days" => %w[mon tue wed thu fri] } }),
          store: store, executor: @executor, clock: -> { @now }, logger: logger
        )

        scheduler.tick(Time.new(2026, 8, 10, 12, 0, 5))
      end

      private

      def build(schedule: ["07:00", "12:00", "17:00"], executor: @executor, extra: {})
        config = Config.new({
                              "anchors" => {
                                "enabled" => true,
                                "model" => "haiku",
                                "schedule" => schedule,
                                "days" => %w[mon tue wed thu fri]
                              }.merge(extra)
                            })

        Scheduler.new(config: config, store: @store, executor: executor, clock: -> { @now })
      end
    end
  end
end
