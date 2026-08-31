# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  class RateLimitWatcherTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @store = Store.new(path: File.join(@dir, "store.json"))
      @api = FakeApi.new
      @config = Config.new({ "telegram" => { "allowed_chat_ids" => [424_242] } })
      @now = Time.local(2026, 8, 11, 12, 0, 0)
    end

    def teardown = FileUtils.remove_entry(@dir)

    # ── three confirmed formats ───────────────────────────────────────

    def test_recognises_5_hour_limit_with_timezone
      build("5-hour limit reached - resets 3pm (UTC)").tick

      assert_includes @api.last_text, "hit a limit"
      assert_includes @api.last_text, "15:00"
    end

    def test_recognises_session_limit_with_named_zone
      build("You've hit your session limit · resets 2am (Europe/Zurich)").tick

      assert_includes @api.last_text, "02:00"
    end

    def test_recognises_weekly_limit_with_a_date
      build("You've hit your weekly limit · resets Oct 9, 10am").tick

      assert_includes @api.last_text, "10:00 09.10"
    end

    def test_ignores_text_without_a_limit_message
      build("⏺ Done. Everything built with no errors.").tick

      assert_empty @api.sent
    end

    # ── rolling over midnight and over a year ────────────────────────────

    # "3pm" already passed today — a bare time of day gone into the past
    # means "tomorrow," not "sometime the day before yesterday."
    def test_bare_time_already_passed_today_rolls_to_tomorrow
      @now = Time.local(2026, 8, 11, 16, 0, 0) # already 16:00, limit resets at 15:00

      build("5-hour limit reached - resets 3pm (UTC)").tick

      assert_includes @api.last_text, "15:00 12.08" # tomorrow, not today
    end

    # A weekly-limit date in the past is a year rolling over (December →
    # January), not "the reset was yesterday."
    def test_dated_limit_in_the_past_rolls_to_next_year
      @now = Time.local(2026, 12, 20, 12, 0, 0)

      build("You've hit your weekly limit · resets Jan 3, 10am").tick

      assert_includes @api.last_text, "10:00 03.01"
    end

    # ── what didn't parse ────────────────────────────────────────────────

    def test_unparseable_reset_time_is_reported_plainly
      build("Rate limit hit. Resets whenever Anthropic feels like it").tick

      assert_includes @api.last_text, "couldn't parse"
    end

    def test_unparseable_message_is_not_repeated_every_tick
      watcher = build("Rate limit hit. Resets soonish")

      3.times { watcher.tick }

      assert_equal 1, @api.sent.size
    end

    # ── detection deduplication ──────────────────────────────────────────

    def test_detection_is_announced_once_not_every_tick
      watcher = build("5-hour limit reached - resets 3pm (UTC)")

      3.times { watcher.tick }

      assert_equal 1, @api.sent.size
    end

    # The phrase disappearing from the screen (scrolling, new output —
    # whatever, not necessarily the limit resolving) must not cancel an
    # already-computed reset time: by the actual reset moment, the
    # original message has almost certainly scrolled off the screen already.
    def test_limit_still_fires_after_the_message_scrolls_off_screen
      backend = FakeBackend.new("5-hour limit reached - resets 12:00pm (UTC)")
      watcher = watcher_with(backend)
      watcher.tick # detected

      backend.text = "⏺ Done. Working on the next thing." # the limit phrase is gone from the screen
      @now += RateLimitWatcher::GRACE + 1
      watcher.tick

      assert backend.sent_text, "should type the continuation even when the phrase is no longer on screen"
    end

    # A different limit (a different reset time) isn't the same tracking
    # — it's an update: a genuinely new fact on the screen must take precedence.
    def test_a_different_limit_message_updates_the_tracked_reset_time
      backend = FakeBackend.new("5-hour limit reached - resets 12:00pm (UTC)")
      watcher = watcher_with(backend)
      watcher.tick

      backend.text = "5-hour limit reached - resets 6:00pm (UTC)"
      watcher.tick

      assert_includes @api.texts.last, "18:00"
    end

    # ── firing ──────────────────────────────────────────────────────────

    def test_fires_once_reset_time_plus_grace_has_passed
      backend = FakeBackend.new("5-hour limit reached - resets 12:00pm (UTC)")
      watcher = watcher_with(backend)

      watcher.tick # detected; the reset is exactly "now" (12:00)

      @now += RateLimitWatcher::GRACE + 1
      watcher.tick

      assert backend.sent_text, "should have typed the continuation"
      assert_includes @api.texts.last, "reset"
    end

    def test_does_not_fire_before_the_grace_period
      backend = FakeBackend.new("5-hour limit reached - resets 12:00pm (UTC)")
      watcher = watcher_with(backend)

      watcher.tick
      @now += RateLimitWatcher::GRACE - 5
      watcher.tick

      refute backend.sent_text
    end

    def test_fires_only_once
      backend = FakeBackend.new("5-hour limit reached - resets 12:00pm (UTC)")
      watcher = watcher_with(backend)

      watcher.tick
      @now += RateLimitWatcher::GRACE + 1
      2.times { watcher.tick }

      assert_equal 1, backend.send_count
    end

    # The session could have closed between detection and the firing
    # moment — typing into a closed tab is not allowed.
    def test_does_not_fire_into_a_session_that_closed_meanwhile
      backend = FakeBackend.new("5-hour limit reached - resets 12:00pm (UTC)")
      registry = FakeRegistry.new(session, backend)
      watcher = RateLimitWatcher.new(registry: registry, config: @config, store: @store,
                                     api: @api, clock: -> { @now })

      watcher.tick
      registry.close!
      @now += RateLimitWatcher::GRACE + 1
      watcher.tick

      refute backend.sent_text
    end

    # ── reply ──────────────────────────────────────────────────────────

    # "Answer manually whenever you see fit" has to be a real invitation
    # to reply, not an empty promise.
    def test_reply_target_is_remembered_for_the_detected_limit
      build("5-hour limit reached - resets 3pm (UTC)").tick

      target = @store.get("reply:424242:#{@api.sent.size}")

      refute_nil target
      assert_equal "S1", target["session_id"]
    end

    def test_reply_target_is_remembered_for_the_unparseable_limit
      build("Rate limit hit. Resets whenever Anthropic feels like it").tick

      target = @store.get("reply:424242:#{@api.sent.size}")

      refute_nil target
    end

    # ── settings ─────────────────────────────────────────────────────────

    def test_can_be_switched_off
      config = Config.new({ "answers" => { "auto_resume_after_limit" => false } })

      build("5-hour limit reached - resets 3pm (UTC)", config: config).tick

      assert_empty @api.sent
    end

    def test_custom_resume_message_is_used
      config = Config.new({ "answers" => { "resume_message" => "keep going" } })
      backend = FakeBackend.new("5-hour limit reached - resets 12:00pm (UTC)")
      watcher = watcher_with(backend, config: config)

      watcher.tick
      @now += RateLimitWatcher::GRACE + 1
      watcher.tick

      assert_equal "keep going", backend.sent_text
    end

    # ── robustness ──────────────────────────────────────────────────────────

    def test_a_broken_registry_does_not_raise
      registry = Object.new
      def registry.refresh = self
      def registry.agents = raise("fell over")

      RateLimitWatcher.new(registry: registry, config: @config, store: @store, api: @api).tick
    end

    # A failure in the log write itself must not escape the rescue that
    # handles it — or it would kill the thread for good.
    def test_a_broken_logger_does_not_kill_the_thread
      backend = Object.new
      def backend.capture(_id, lines: 20) = raise("screen unreadable")

      logger = Object.new
      def logger.puts(_msg) = raise("log unwritable too")

      registry = FakeRegistry.new(session, backend)
      watcher = RateLimitWatcher.new(registry: registry, config: @config, store: @store,
                                     api: @api, logger: logger)

      watcher.tick
    end

    private

    def session
      Session.new(id: "S1", backend: :iterm2, tty: "/dev/ttys017",
                 title: "work", cwd: "/tmp", agent: :claude_code)
    end

    def watcher_with(backend, config: @config)
      registry = FakeRegistry.new(session, backend)
      RateLimitWatcher.new(registry: registry, config: config, store: @store, api: @api,
                           clock: -> { @now })
    end

    def build(text, config: @config) = watcher_with(FakeBackend.new(text), config: config)

    class FakeRegistry
      def initialize(session, backend)
        @session = session
        @backend = backend
        @closed = false
      end

      def close! = @closed = true

      def refresh = self

      def agents = @closed ? [] : [@session]

      def find(_id) = @closed ? nil : @session

      def backend_for(_session) = @backend
    end

    class FakeBackend
      attr_accessor :text
      attr_reader :send_count, :sent_text

      def initialize(text)
        @text = text
        @send_count = 0
        @buffer = +""
        @sent_text = nil
      end

      def capture(_id, lines: 20) = @text

      # type_resume sends text and Enter as two calls (like /run) —
      # here they're joined into one final message, the way they'd
      # appear on a real screen.
      def send_text(_id, chunk, newline: true)
        @buffer << chunk

        if newline
          @send_count += 1
          @sent_text = @buffer
          @buffer = +""
        end

        true
      end
    end
  end
end
