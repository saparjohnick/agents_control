# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  class ScreenWatcherTest < Minitest::Test
    # Real examples captured from live sessions: the folder-trust dialog
    # and the model-switch dialog. Both use the same drawing convention.
    TRUST_SCREEN = <<~SCREEN
      ────────────────────────────────────────────
       Accessing workspace:
       /tmp/probe
       Quick safety check: Is this a project you trust?
       Claude Code'll be able to read, edit, and execute files here.
       Security guide
       ❯ 1. Yes, I trust this folder
         2. No, exit
       Enter to confirm · Esc to cancel
    SCREEN

    MODEL_SCREEN = <<~SCREEN
      This conversation is cached for the current model.

      ❯ 1. Yes, switch to Opus 5
          2. No, go back
    SCREEN

    NORMAL_PROMPT = <<~SCREEN
      ⏺ Done.
      ────────────────────────────────────────────
      ❯ Try "write a test for <filepath>"
      ────────────────────────────────────────────
        ⏸ manual mode on · ? for shortcuts
    SCREEN

    # A real dialog the parser missed: a skill's own wizard menu, where
    # each option carries a couple of lines of description underneath
    # it, and a divider sets a trailing meta-option apart from the rest.
    RICH_WIZARD_SCREEN = <<~SCREEN
      ←  ☒ Направление  ☐ Тип макетов  ✔ Submit  →

      Макеты статичные или кликабельные?

      ❯ 1. Игровой экран живой
           Все экраны статичные, но на игровом реально рисуется путь по сетке — можно потрогать саму механику. Рекомендую: именно тут решается, приятная игра или нет.
        2. Всё статично
           Чистые визуальные макеты всех экранов. Быстрее, проще править, но механику не пощупать.
        3. Кликабельный прототип
           Переходы между экранами, работающие кнопки, живая сетка. Дольше собирать, зато можно пройти весь путь игрока насквозь.
        4. Type something.
      ───────────────────────────────────────────────────────────────────
        5. Chat about this

      Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    SCREEN

    def setup
      @dir = Dir.mktmpdir
      @store = Store.new(path: File.join(@dir, "store.json"))
      @api = FakeApi.new
      @config = Config.new({ "telegram" => { "allowed_chat_ids" => [424_242] } })
    end

    def teardown = FileUtils.remove_entry(@dir)

    # ── menu recognition ───────────────────────────────────────────────

    def test_recognises_the_trust_folder_dialog
      watcher_with(FakeBackend.new(TRUST_SCREEN)).tick

      assert_includes @api.last_text, "Yes, I trust this folder"
    end

    def test_recognises_the_model_switch_dialog
      watcher_with(FakeBackend.new(MODEL_SCREEN)).tick

      assert_includes @api.last_text, "switch to Opus 5"
    end

    # Regression: a menu whose options each carry a couple of lines of
    # description used to break detection entirely — the very first
    # description line didn't look like a numbered option, so the scan
    # stopped right there and never found a second option at all.
    def test_recognises_a_menu_with_multi_line_descriptions
      watcher_with(FakeBackend.new(RICH_WIZARD_SCREEN)).tick

      assert_includes @api.last_text, "Игровой экран живой"
      assert_includes @api.last_text, "Всё статично"
      assert_includes @api.last_text, "Кликабельный прототип"
    end

    # The divider before the trailing meta-option doesn't end the scan
    # either — it's just another line that isn't itself a numbered
    # option, same as a description line.
    def test_recognises_an_option_past_a_divider
      watcher_with(FakeBackend.new(RICH_WIZARD_SCREEN)).tick

      assert_includes @api.last_text, "Chat about this"
    end

    def test_rich_wizard_menu_gets_one_button_per_option
      watcher_with(FakeBackend.new(RICH_WIZARD_SCREEN)).tick

      rows = @api.sent.first[:markup][:inline_keyboard]

      assert_equal 5, rows.size
    end

    # A normal Claude Code input prompt also starts with "❯", but with no
    # numbered options — that's not a menu, and there should be no notification.
    def test_normal_prompt_is_not_a_menu
      watcher_with(FakeBackend.new(NORMAL_PROMPT)).tick

      assert_empty @api.sent
    end

    def test_empty_screen_is_not_a_menu
      watcher_with(FakeBackend.new("")).tick

      assert_empty @api.sent
    end

    # ── candidate source ──────────────────────────────────────────────

    # The candidate source is Registry.agents, same as RateLimitWatcher:
    # bare iTerm2 tabs are needed on equal footing with tmux panes.
    def test_sees_sessions_regardless_of_terminal_backend
      watcher_with(FakeBackend.new(TRUST_SCREEN), session: session(backend: :iterm2)).tick

      refute_empty @api.sent
    end

    # A terminalless session (VS Code) is in the registry, but there's
    # nothing to capture — there'd be nobody to type a choice into.
    def test_terminalless_sessions_are_skipped
      watcher_with(FakeBackend.new(TRUST_SCREEN), session: session(backend: nil, tty: nil)).tick

      assert_empty @api.sent
    end

    # ── deduplication ──────────────────────────────────────────────────────

    def test_the_same_menu_is_not_repeated_every_tick
      watcher = watcher_with(FakeBackend.new(TRUST_SCREEN))

      3.times { watcher.tick }

      assert_equal 1, @api.sent.size
    end

    def test_a_different_menu_notifies_again
      backend = FakeBackend.new(TRUST_SCREEN)
      watcher = watcher_with(backend)
      watcher.tick

      backend.text = MODEL_SCREEN
      watcher.tick

      assert_equal 2, @api.sent.size
    end

    def test_menu_disappearing_and_reappearing_notifies_again
      backend = FakeBackend.new(TRUST_SCREEN)
      watcher = watcher_with(backend)
      watcher.tick

      backend.text = NORMAL_PROMPT
      watcher.tick

      backend.text = TRUST_SCREEN
      watcher.tick

      assert_equal 2, @api.sent.size
    end

    # ── buttons ────────────────────────────────────────────────────────────

    def test_buttons_carry_one_choice_each
      watcher_with(FakeBackend.new(TRUST_SCREEN)).tick

      rows = @api.sent.first[:markup][:inline_keyboard]

      assert_equal 2, rows.size
    end

    def test_every_button_fits_the_callback_limit
      watcher_with(FakeBackend.new(TRUST_SCREEN)).tick

      buttons = @api.sent.first[:markup][:inline_keyboard].flatten
      buttons.each { |b| assert_operator b[:callback_data].bytesize, :<=, 64 }
    end

    # ── reply ────────────────────────────────────────────────────────────

    # Replying (e.g. simply typing "1") must work the same way as
    # replying to any other notification.
    def test_reply_target_is_remembered_for_the_menu_notification
      watcher_with(FakeBackend.new(TRUST_SCREEN)).tick

      target = @store.get("reply:424242:#{@api.sent.size}")

      refute_nil target
      assert_equal "S1", target["session_id"]
    end

    # ── settings ─────────────────────────────────────────────────────────

    def test_can_be_switched_off
      config = Config.new({ "terminal" => { "watch_menus" => false } })

      watcher_with(FakeBackend.new(TRUST_SCREEN), config: config).tick

      assert_empty @api.sent
    end

    # ── robustness ──────────────────────────────────────────────────────────

    def test_a_broken_registry_does_not_raise
      registry = Object.new
      def registry.refresh = self
      def registry.agents = raise("registry fell over")

      ScreenWatcher.new(registry: registry, config: @config, store: @store, api: @api).tick
    end

    # A failure in the log write itself must not escape the rescue that
    # handles it — or it would kill the thread for good.
    def test_a_broken_logger_does_not_kill_the_thread
      backend = Object.new
      def backend.capture(_id, lines: 30) = raise("screen unreadable")

      logger = Object.new
      def logger.puts(_msg) = raise("log unwritable too")

      watcher = ScreenWatcher.new(registry: FakeRegistry.new(session, backend),
                                  config: @config, store: @store, api: @api, logger: logger)

      watcher.tick
    end

    private

    def session(backend: :iterm2, tty: "/dev/ttys017")
      Session.new(id: "S1", backend: backend, tty: tty,
                 title: "work", cwd: "/tmp/probe", agent: :claude_code)
    end

    def watcher_with(backend, config: @config, session: session())
      registry = FakeRegistry.new(session, backend)
      ScreenWatcher.new(registry: registry, config: config, store: @store, api: @api)
    end

    class FakeRegistry
      def initialize(session, backend)
        @session = session
        @backend = backend
      end

      def refresh = self

      def agents = [@session]

      def backend_for(_session) = @backend
    end

    class FakeBackend
      attr_accessor :text

      def initialize(text) = @text = text

      def capture(_id, lines: 30) = @text
    end
  end
end
