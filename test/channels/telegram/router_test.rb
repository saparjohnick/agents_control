# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  module Channels
    module Telegram
      class RouterTest < Minitest::Test
        OWNER = 424_242
        STRANGER = 999_999

        def setup
          @dir = Dir.mktmpdir
          @api = FakeApi.new
          @store = Store.new(path: File.join(@dir, "store.json"))
          @executor = FakeExecutor.new(
            "-o" => Fixtures::PS,
            "-Fn" => Fixtures::LSOF,
            "osascript" => Fixtures::ITERM
          )
          @config = Config.new({ "telegram" => { "allowed_chat_ids" => [OWNER] } })
          @router = build_router
        end

        def teardown = FileUtils.remove_entry(@dir)

        # ── access ────────────────────────────────────────────────────────

        # The bot's name is public, anyone can write to it. The only
        # boundary is the allowed-chats list.
        def test_stranger_gets_no_response_at_all
          @router.handle(incoming("/agents", chat_id: STRANGER))

          assert_empty @api.sent
        end

        def test_stranger_cannot_press_buttons
          key = @store.put({ "action" => "list_tabs" })

          @router.handle(pressed(key, chat_id: STRANGER))

          assert_empty @api.sent
          assert_empty @api.answered
        end

        # An empty list means "nobody", not "everybody".
        def test_empty_allowlist_answers_nobody
          router = build_router(config: Config.new)

          router.handle(incoming("/agents", chat_id: OWNER))

          assert_empty @api.sent
        end

        def test_owner_gets_a_response
          @router.handle(incoming("/agents", chat_id: OWNER))

          refute_empty @api.sent
        end

        # ── lists ────────────────────────────────────────────────────────

        def test_agents_list_shows_only_confirmed_agents
          @router.handle(incoming("/agents", chat_id: OWNER))

          text = unescape_markdown(@api.last_text)

          assert_includes text, "backend_api"
          # A tab with a stale title doesn't count as an agent.
          refute_includes text, "mobile-app"
        end

        def test_tabs_list_shows_everything
          @router.handle(incoming("/tabs", chat_id: OWNER))

          assert_includes unescape_markdown(@api.last_text), "mobile-app"
        end

        # The number goes out escaped ("3\.", not "3.") — the period is
        # one of the characters MarkdownV2 requires escaped outside code,
        # confirmed by a direct request to the real Bot API.
        def test_list_is_numbered_for_addressing_by_command
          @router.handle(incoming("/agents", chat_id: OWNER))

          assert_match(/^\s*\d+\\?\./, @api.last_text.lines[2])
        end

        # The menu and the help text are built from the same list: a
        # menu that's drifted is worse than none.
        def test_help_is_built_from_the_command_list
          Router::COMMANDS.each do |name, _|
            assert_includes Router::HELP, "/#{name}"
          end
        end

        # Telegram's menu button (☰) is easy to lose track of — the
        # buttons under /start and /help stay available at any moment
        # right in the message.
        def test_start_shows_a_button_menu
          @router.handle(incoming("/start", chat_id: OWNER))

          texts = @api.sent.last[:markup][:inline_keyboard].flatten.map { |b| b[:text] }

          assert_includes texts, "🤖 agents"
          assert_includes texts, "📋 all tabs"
          assert_includes texts, "📊 status"
          assert_includes texts, "⚙️ settings"
        end

        def test_status_button_shows_status
          @router.handle(incoming("/start", chat_id: OWNER))

          @router.handle(pressed(button_key(@api.sent.last, "📊 status"), chat_id: OWNER))

          assert_includes @api.last_text, "Tabs"
        end

        def test_settings_button_shows_settings
          @router.handle(incoming("/start", chat_id: OWNER))

          @router.handle(pressed(button_key(@api.sent.last, "⚙️ settings"), chat_id: OWNER))

          refute_includes @api.last_text, "I don't know"
        end

        def test_every_listed_command_is_actually_handled
          Router::COMMANDS.each do |name, _|
            @api.sent.clear
            @router.handle(incoming("/#{name}", chat_id: OWNER))

            refute_includes @api.texts.join, "I don't know that command", "/#{name} is not handled"
          end
        end

        def test_unknown_command_explains_itself
          @router.handle(incoming("/whatisthis", chat_id: OWNER))

          assert_includes @api.last_text, "I don't know that command"
        end

        # ── buttons ────────────────────────────────────────────────────────

        def test_button_is_answered_before_work_starts
          key = @store.put({ "action" => "list_tabs" })

          @router.handle(pressed(key, chat_id: OWNER))

          assert_equal 1, @api.answered.size
        end

        # Telegram redelivers a callback if the connection drops, and a
        # finger can easily press twice.
        def test_second_press_does_nothing
          key = @store.put({ "action" => "list_tabs" })

          @router.handle(pressed(key, chat_id: OWNER))
          @router.handle(pressed(key, chat_id: OWNER))

          assert_includes @api.texts.last, "expired"
        end

        def test_unknown_key_is_rejected_politely
          @router.handle(pressed("no-such-key", chat_id: OWNER))

          assert_includes @api.last_text, "expired"
        end

        def test_expired_key_is_rejected
          store = Store.new(path: File.join(@dir, "store.json"), clock: -> { @clock ||= 1000 })
          router = build_router(store: store)
          key = store.put({ "action" => "list_tabs" }, ttl: 60)

          @clock = 2000
          router.handle(pressed(key, chat_id: OWNER))

          assert_includes @api.last_text, "expired"
        end

        # Bot API constraint: 64 bytes per button.
        def test_every_button_fits_the_callback_data_limit
          @router.handle(incoming("/agents", chat_id: OWNER))

          buttons = @api.sent.flat_map { |m| (m[:markup] || {})[:inline_keyboard].to_a.flatten }

          refute_empty buttons
          buttons.each { |button| assert_operator button[:callback_data].bytesize, :<=, 64 }
        end

        # ── running commands ─────────────────────────────────────────────

        def test_run_requires_a_command
          @router.handle(incoming("/run 1", chat_id: OWNER))

          assert_includes @api.last_text, "Usage"
        end

        def test_new_creates_a_tab_in_the_given_directory
          executor = FakeExecutor.new(
            "/tmp/newproj" => "NEW-TAB-ID",
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF, "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)

          router.handle(incoming("/new /tmp/newproj", chat_id: OWNER))

          assert_includes @api.last_text, "Created tab"
        end

        def test_new_reports_failure_when_the_backend_cant_create_a_tab
          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF, "osascript" => 1
          )
          router = build_router(executor: executor)

          router.handle(incoming("/new /tmp/whatever", chat_id: OWNER))

          assert_includes @api.last_text, "Couldn't create"
        end

        # ── formatting ──────────────────────────────────────────────────────

        def test_replies_are_sent_as_markdownv2
          @router.handle(incoming("/status", chat_id: OWNER))

          assert_equal "MarkdownV2", @api.sent.last[:parse_mode]
        end

        # Confirmed against the real API: an unescaped period outside
        # code causes the send to fail. A tab's label contains
        # underscores and dashes, and they must arrive escaped.
        def test_reserved_characters_in_labels_are_escaped
          @router.handle(incoming("/agents", chat_id: OWNER))

          assert_includes @api.last_text, "backend\\_api"
        end

        # A message isn't required to arrive formatted — it's required
        # to arrive. If Telegram rejects it over formatting anyway
        # (whatever text the agent happened to write), the same text
        # goes out again with no parse_mode at all.
        def test_falls_back_to_plain_text_when_markdown_is_rejected
          @api.fail_markdown_once = true

          @router.handle(incoming("/status", chat_id: OWNER))

          assert_equal 1, @api.sent.size, "should arrive as one message, not get lost"
          assert_nil @api.sent.last[:parse_mode]
        end

        # /run doesn't just confirm the command was typed — it reads the
        # screen back afterward and shows the actual result, the same
        # way /screen would.
        def test_run_sends_text_to_the_tab_and_shows_the_result
          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => ["backend_api $ ",
                                          "backend_api $ \ntotal 8\ndrwxr-xr-x 3 devbox staff 96 some_file"],
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")

          router.handle(incoming("/run #{number} ls -la", chat_id: OWNER))

          assert executor.called?(Fixtures::BACKEND_API_ID)
          assert_includes @api.last_text, "some_file"
        end

        # With several tabs sharing the same label (same project directory
        # open twice), the label alone can't tell them apart — the reply
        # needs to name the actual tab the result came from.
        def test_run_result_names_the_tty_so_identically_labeled_tabs_are_distinguishable
          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => ["backend_api $ ",
                                          "backend_api $ \ntotal 8\ndrwxr-xr-x 3 devbox staff 96 some_file"],
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")

          router.handle(incoming("/run #{number} ls -la", chat_id: OWNER))

          assert_includes @api.last_text, "backend\\_api"
          assert_includes @api.last_text, "ttys017"
        end

        # The result shown is only what appeared after the command was
        # typed, not whatever was already sitting on screen — the
        # pre-command prompt line must not leak into the reply.
        def test_run_shows_only_new_output_not_the_pre_command_screen
          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => ["stale content from before",
                                          "stale content from before\nfresh command output"],
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")

          router.handle(incoming("/run #{number} ls", chat_id: OWNER))

          assert_includes @api.last_text, "fresh command output"
          refute_includes @api.last_text, "stale content from before"
        end

        # A shell prompt repeats after every command, so stale repeats
        # from earlier runs can already be sitting on screen before this
        # one is even typed — the "before" snapshot itself already
        # contains them. Only what's typed *after* that snapshot counts
        # as new; the two stale repeats already there must not leak in
        # alongside the real result.
        def test_run_finds_the_most_recent_prompt_not_a_stale_repeat
          stale = "prompt> git st\nOn branch main\nnothing to commit\n"
          before = "#{stale * 2}prompt> "
          after = "#{before}git st\nOn branch main\nnothing to commit\nprompt> "

          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => [before, after],
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")

          router.handle(incoming("/run #{number} git st", chat_id: OWNER))

          assert_equal 1, @api.last_text.scan("On branch main").size
        end

        # A prompt-matching approach breaks the moment the *new* run's own
        # trailing prompt looks identical to the boundary marker — search
        # naturally finds the newest, wrong occurrence, right at the very
        # end of the capture, and returns next to nothing. This is the
        # actual bug that shipped live: re-running an identical command
        # against an already-repeating prompt produced an empty result.
        # An exact prefix match sidesteps the ambiguity entirely — no
        # searching needed when nothing scrolled out of the window.
        def test_run_result_is_not_swallowed_by_the_commands_own_new_prompt
          before = "prompt> git st\nOn branch main\nnothing to commit\nprompt> "
          after = "#{before}git st\nOn branch main\nnothing to commit\nprompt> "

          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => [before, after],
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")

          router.handle(incoming("/run #{number} git st", chat_id: OWNER))

          assert_includes @api.last_text, "On branch main"
        end

        # An agent's input field is live: while it's busy, typed text
        # lands there as a delayed message, and a merged newline can end
        # up staying part of the text instead of submitting — in the
        # window where it's "just typed."
        def test_agent_receives_text_and_enter_separately
          @router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")
          @router.handle(incoming("/run #{number} hello", chat_id: OWNER))

          writes = @executor.calls.select { |c| c[:argv].join.include?("osascript") && c[:argv].include?("hello") }

          assert_equal 1, writes.size
          assert_includes writes.first[:stdin], "newline false"
        end

        # The two-step send — text, then a separate Enter — works the
        # same way for any session, not only agent sessions: a merged
        # call can fail to send a multi-line command at all.
        def test_plain_tab_also_gets_text_and_enter_separately
          @router.handle(incoming("/tabs", chat_id: OWNER))
          number = number_of("mobile-app")
          before = @executor.calls.size

          @router.handle(incoming("/run #{number} ls", chat_id: OWNER))

          # Filtered by "write text" in stdin, not just "osascript" in
          # argv: /run first refreshes the tab registry (also an
          # osascript call, but a session list, not text input), and
          # that must not be mistaken for the write.
          writes = @executor.calls[before..].select { |c| c[:stdin].to_s.include?("write text") }

          assert_equal 2, writes.size
          assert_includes writes.first[:stdin], "newline false"
          assert_includes writes.last[:stdin], "newline true"
        end

        def test_run_refuses_sessions_without_a_terminal
          @router.handle(incoming("/tabs", chat_id: OWNER))
          number = number_of("flightlog", terminalless: true)

          @router.handle(incoming("/run #{number} ls", chat_id: OWNER))

          assert_includes @api.last_text, "no terminal"
        end

        # A terminalless session (VS Code) doesn't support focus/close/send_text
        # at all — Terminals::Null doesn't implement them, and
        # Terminals::Base raises Unsupported by default. Buttons on such
        # a session's card must report that in the chat, not just do
        # nothing: a generic top-level rescue StandardError would only
        # log to the daemon's log, leaving a button tap with no response at all.
        def test_focus_button_on_a_terminalless_session_is_reported_not_silent
          key = @store.put({ "action" => "focus", "session_id" => "pid:1752" })

          @router.handle(pressed(key, chat_id: OWNER))

          assert_includes @api.last_text, "not supported"
        end

        def test_close_button_on_a_terminalless_session_is_reported_not_silent
          key = @store.put({ "action" => "close", "session_id" => "pid:1752" })

          @router.handle(pressed(key, chat_id: OWNER))

          assert_includes @api.last_text, "not supported"
        end

        # A command in an ssh tab goes to a remote server, not the laptop.
        def test_run_on_remote_tab_asks_for_confirmation_first
          @router.handle(incoming("/tabs", chat_id: OWNER))
          number = number_of("ttys000")

          @router.handle(incoming("/run #{number} rm -rf /", chat_id: OWNER))

          assert_includes @api.last_text, "remote machine"
          refute_includes @api.last_text, "Sent"
        end

        def test_confirmed_remote_command_is_executed
          ssh_session_id = "D63D6009-F477-44EE-B890-54C1B30E8B69"
          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            ssh_session_id => ["dev@relay:~$ ", "dev@relay:~$ \nuptime output here"],
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/tabs", chat_id: OWNER))
          router.handle(incoming("/run #{number_of('ttys000')} uptime", chat_id: OWNER))

          key = @api.sent.last[:markup][:inline_keyboard][0][0][:callback_data]
          router.handle(pressed(key, chat_id: OWNER))

          assert executor.called?(ssh_session_id)
          assert_includes @api.last_text, "uptime output here"
        end

        # If "All tabs" and "Agents" numbered against their own filtered
        # view instead of the shared universe, opening one would rewrite
        # the other's numbering, and /run with a remembered number could
        # hit the wrong session.
        def test_same_session_keeps_its_number_across_agents_and_tabs_view
          @router.handle(incoming("/tabs", chat_id: OWNER))
          from_tabs = number_of("backend_api")

          @router.handle(incoming("/agents", chat_id: OWNER))
          from_agents = number_of_in(@api.last_text, "backend_api")

          assert_equal from_tabs, from_agents
        end

        # After viewing "Agents", a number from "All tabs" must keep
        # addressing that exact session, not whatever ended up at that
        # position in the shorter list.
        def test_run_still_hits_the_right_session_after_switching_views
          @router.handle(incoming("/tabs", chat_id: OWNER))
          number = number_of("backend_api")

          @router.handle(incoming("/agents", chat_id: OWNER))
          @router.handle(incoming("/run #{number} echo hello", chat_id: OWNER))

          writes = @executor.calls.select { |c| c[:argv].include?("echo hello") }
          assert_equal 1, writes.size
          assert_includes writes.first[:argv], Fixtures::BACKEND_API_ID
        end

        # A reply to a local CLI menu (ScreenWatcher): there's no
        # structured decision here like with hooks — just type the
        # number and Enter into the pane.
        def test_menu_choice_sends_the_number_into_the_pane
          key = @store.put({ "action" => "menu_choice", "session_id" => Fixtures::BACKEND_API_ID,
                            "choice" => 1 })

          @router.handle(pressed(key, chat_id: OWNER))

          call = @executor.call_with(Fixtures::BACKEND_API_ID)
          assert_includes call[:stdin], "1"
          assert_includes @api.last_text, "Chose"
        end

        def test_menu_choice_on_a_closed_session_is_reported
          key = @store.put({ "action" => "menu_choice", "session_id" => "no-such-session", "choice" => 1 })

          @router.handle(pressed(key, chat_id: OWNER))

          assert_includes @api.last_text, "already closed"
        end

        # A tapped AskUserQuestion option button, same idea as
        # menu_choice: no hook involved, just the same keystroke a human
        # would type into the pane.
        def test_ask_question_choice_sends_the_number_into_the_pane
          key = @store.put({ "action" => "ask_question_choice", "session_id" => Fixtures::BACKEND_API_ID,
                            "choice" => 2 })

          @router.handle(pressed(key, chat_id: OWNER))

          call = @executor.call_with(Fixtures::BACKEND_API_ID)
          assert_includes call[:stdin], "2"
          assert_includes @api.last_text, "Sent"
        end

        def test_ask_question_choice_on_a_closed_session_is_reported
          key = @store.put({ "action" => "ask_question_choice", "session_id" => "no-such-session",
                            "choice" => 1 })

          @router.handle(pressed(key, chat_id: OWNER))

          assert_includes @api.last_text, "already closed"
        end

        def test_stale_number_is_reported
          @router.handle(incoming("/run 99 ls", chat_id: OWNER))

          assert_includes @api.last_text, "No such number"
        end

        # ── screen output ──────────────────────────────────────────────────

        # An agent's screen is read directly — that's the first choice
        # for /screen, not just for regular tabs. The transcript stays
        # the fallback for when the screen is empty (a tab just created,
        # say) — simulated here with a separate executor response
        # targeted specifically at the capture call, not the listing, or
        # the test would be checking the wrong behavior.
        def test_agent_screen_falls_back_to_the_transcript_when_the_screen_is_empty
          project = File.join(@dir, "projects", Transcript.slug("/Users/devbox/projects/backend_api"))
          FileUtils.mkdir_p(project)
          File.write(File.join(project, "s.jsonl"), Fixtures::TRANSCRIPT_LINES)

          executor = empty_screen_executor
          router = build_router(config: config_with_transcripts, executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")
          router.handle(incoming("/screen #{number}", chat_id: OWNER))

          assert_includes @api.last_text, "fix the build"
        end

        def test_agent_without_a_transcript_says_so_plainly
          executor = empty_screen_executor
          router = build_router(config: config_with_transcripts, executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")
          router.handle(incoming("/screen #{number}", chat_id: OWNER))

          assert_includes @api.last_text, "no transcript was found"
        end

        # The transcript fallback is keyed by cwd, not by session — a
        # plain (non-agent) tab sharing a project directory with some
        # unrelated Claude session must never surface that session's
        # transcript as if it were its own screen. A transcript file is
        # deliberately planted here to prove it stays untouched, not just
        # absent.
        def test_plain_tabs_empty_screen_never_leaks_an_unrelated_transcript
          project = File.join(@dir, "projects", Transcript.slug("/Users/devbox/projects/mobile-app"))
          FileUtils.mkdir_p(project)
          File.write(File.join(project, "s.jsonl"), Fixtures::TRANSCRIPT_LINES)

          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            "AD9E50DB-91C0-4966-994C-62091639B101" => "",
            "osascript" => Fixtures::ITERM
          )
          router = build_router(config: config_with_transcripts, executor: executor)
          router.handle(incoming("/tabs", chat_id: OWNER))
          number = number_of_in(@api.last_text, "mobile-app")

          router.handle(incoming("/screen #{number}", chat_id: OWNER))

          assert_includes @api.last_text, "screen is empty"
          refute_includes @api.last_text, "fix the build"
        end

        # Same guarantee for /run's result: an actually-empty screen on a
        # plain tab must not turn into an unrelated Claude session's
        # transcript.
        def test_plain_tabs_empty_run_result_never_leaks_an_unrelated_transcript
          project = File.join(@dir, "projects", Transcript.slug("/Users/devbox/projects/mobile-app"))
          FileUtils.mkdir_p(project)
          File.write(File.join(project, "s.jsonl"), Fixtures::TRANSCRIPT_LINES)

          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            "AD9E50DB-91C0-4966-994C-62091639B101" => "",
            "osascript" => Fixtures::ITERM
          )
          router = build_router(config: config_with_transcripts, executor: executor)
          router.handle(incoming("/tabs", chat_id: OWNER))
          number = number_of_in(@api.last_text, "mobile-app")

          router.handle(incoming("/run #{number} git status", chat_id: OWNER))

          assert_includes @api.last_text, "screen is empty"
          refute_includes @api.last_text, "fix the build"
        end

        # No clean boundary doesn't mean nothing to show — the whole
        # point of /run is seeing the result sitting on screen, so
        # "couldn't confidently isolate what's new" must still surface
        # the actual current screen, not go silent.
        def test_run_shows_the_current_screen_when_no_new_growth_can_be_found
          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => "backend_api $ git st\nOn branch main",
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")

          router.handle(incoming("/run #{number} git st", chat_id: OWNER))

          assert_includes @api.last_text, "On branch main"
        end

        # The scenario that actually shipped live: the tab is also being
        # used by hand at the same time, so `before` and `after` share
        # no prefix and no common marker at all by the time they're
        # captured. The command's own echo is still there regardless —
        # anchoring on it directly recovers the precise result instead
        # of falling back to the whole (noisy) capture.
        def test_run_recovers_the_result_even_when_before_and_after_share_nothing
          before = "totally unrelated screen state from a moment ago\n$ "
          after = "completely different content now\ngit st\nOn branch main\nnothing to commit\n$ "

          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => [before, after],
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")

          router.handle(incoming("/run #{number} git st", chat_id: OWNER))

          assert_includes @api.last_text, "On branch main"
          refute_includes @api.last_text, "totally unrelated"
          refute_includes @api.last_text, "completely different content now"
        end

        # Same reasoning as the /run result: with several tabs sharing a
        # label, the tty is what actually tells them apart. The capture
        # text is deliberately something that doesn't itself contain
        # "backend_api" or "ttys017" — the assertions must be exercising
        # the header, not coincidentally matching the fixture's own cwd.
        def test_screen_names_the_tty_in_its_header
          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => "$ some unrelated screen contents",
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")

          router.handle(incoming("/screen #{number}", chat_id: OWNER))

          assert_includes @api.last_text, "backend\\_api"
          assert_includes @api.last_text, "ttys017"
        end

        # capture hands back an agent's full screen for a live session,
        # and a large one is delivered in full — as several messages in a
        # row, each of which still fits the Bot API's real limit (4096
        # UTF-16 units after markup parsing, not UTF-8 bytes: a non-Latin
        # character is 2 bytes but 1 UTF-16 unit).
        def test_agent_screen_is_read_directly_and_sent_in_full_across_several_messages
          # capture() itself clips output to terminal.context_lines (80
          # lines by default) — so the "huge" input is built as 80 long
          # lines, not many short ones: otherwise it would never reach
          # the chunking threshold, no matter how many lines a real
          # screen would actually hand back.
          screen = (1..80).map { |i| "line #{i} #{'x' * 100}" }.join("\n")
          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => screen,
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")
          before = @api.sent.size

          router.handle(incoming("/screen #{number}", chat_id: OWNER))

          sent = @api.sent[before..]
          assert_operator sent.size, :>, 1
          sent.each { |m| assert_operator Chunker.utf16_length(m[:text]), :<=, Router::MAX_MESSAGE }
          assert_equal 80, sent.map { |m| m[:text] }.join.scan(/line \d+/).size
        end

        # ── replies to service messages ────────────────────────────────

        # /context shows the transcript, and must work the same way /run
        # and agent notifications do: a reply must address the session.
        def test_reply_to_context_message_reaches_the_session
          project = File.join(@dir, "projects", Transcript.slug("/Users/devbox/projects/backend_api"))
          FileUtils.mkdir_p(project)
          File.write(File.join(project, "s.jsonl"), Fixtures::TRANSCRIPT_LINES)

          router = build_router(config: config_with_transcripts)
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")
          router.handle(incoming("/context #{number}", chat_id: OWNER))
          context_message_id = @api.sent.size

          router.handle(reply_to("hello", context_message_id, chat_id: OWNER))

          refute_includes @api.last_text, "don't remember"
          writes = @executor.calls.select { |c| c[:stdin].to_s.include?("write text") }
          refute_empty writes
        end

        # Same for /screen — it also shows a session's content and
        # should accept a reply on the same principle.
        def test_reply_to_screen_message_reaches_the_session
          router = build_router
          router.handle(incoming("/agents", chat_id: OWNER))
          number = number_of_in(@api.last_text, "backend_api")
          router.handle(incoming("/screen #{number}", chat_id: OWNER))
          screen_message_id = @api.sent.size

          router.handle(reply_to("hello", screen_message_id, chat_id: OWNER))

          refute_includes @api.last_text, "don't remember"
        end

        # A plain shell tab running something interactive (git add -p,
        # an installer prompt, anything reading single-key answers) has
        # to work as a back-and-forth: each reply types into the same
        # pane and shows what came back, not just a "sent" confirmation.
        def test_reply_drives_an_interactive_command_like_git_add_dash_p
          mobile_app_id = "AD9E50DB-91C0-4966-994C-62091639B101"
          # A capture call's only argument is the session id itself;
          # send_text also carries the id, but with the typed text (or
          # "" for the Enter call) as the last element — that's how
          # they're told apart, so send_text calls don't also eat a
          # step of this sequence meant only for the screen changing
          # between captures.
          capture_call = ->(argv) { argv.last == mobile_app_id }
          executor = FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            capture_call => [
              "mobile-app $ ",
              "mobile-app $ \n+++ hunk 1\nStage this hunk [y,n,q]? ",
              "mobile-app $ \n+++ hunk 1\nStage this hunk [y,n,q]? y",
              "mobile-app $ \n+++ hunk 1\nStage this hunk [y,n,q]? y\n" \
              "+++ hunk 2\nStage this hunk [y,n,q]? "
            ],
            mobile_app_id => "",
            "osascript" => Fixtures::ITERM
          )
          router = build_router(executor: executor)
          router.handle(incoming("/tabs", chat_id: OWNER))
          number = number_of("mobile-app")

          router.handle(incoming("/run #{number} git add -p", chat_id: OWNER))
          assert_includes @api.last_text, "hunk 1"
          refute_includes @api.last_text, "mobile-app $"
          reply_target = @api.sent.size

          router.handle(reply_to("y", reply_target, chat_id: OWNER))

          assert_includes @api.last_text, "hunk 2"
          writes = executor.calls.select { |c| c[:argv].include?("y") }
          assert_equal 1, writes.size
        end

        # ── a reply lands in the right tab ───────────────────────────

        # A reply first looks for the exact session by session_id — not
        # just by working directory, which is ambiguous with several
        # tabs of the same project.
        def test_reply_reaches_the_exact_tab_among_several_tabs_of_the_same_project
          tab_a = Session.new(id: "TAB-A", backend: :iterm2, tty: "/dev/ttys030",
                              cwd: "/tmp/flightlog", agent: :claude_code)
          tab_b = Session.new(id: "TAB-B", backend: :iterm2, tty: "/dev/ttys031",
                              cwd: "/tmp/flightlog", agent: :claude_code)
          backend = RecordingBackend.new
          router = Router.new(api: @api, store: @store, config: @config,
                              registry: FakeMultiRegistry.new([tab_a, tab_b], backend))
          @store.put({ "session_id" => "TAB-B", "cwd" => "/tmp/flightlog", "label" => "flightlog" },
                     key: "reply:#{OWNER}:555")

          router.handle(reply_to("continue", 555, chat_id: OWNER))

          assert_equal [["TAB-B", "continue"], ["TAB-B", ""]], backend.calls
        end

        # The tab that sent the notification has closed — but exactly
        # one other one remains in the same project. Matching by
        # directory is a sensible fallback exactly for this case.
        def test_reply_falls_back_to_the_one_remaining_tab_of_the_same_project
          tab_b = Session.new(id: "TAB-B", backend: :iterm2, tty: "/dev/ttys031",
                              cwd: "/tmp/flightlog", agent: :claude_code)
          backend = RecordingBackend.new
          router = Router.new(api: @api, store: @store, config: @config,
                              registry: FakeMultiRegistry.new([tab_b], backend))
          @store.put({ "session_id" => "TAB-GONE", "cwd" => "/tmp/flightlog", "label" => "flightlog" },
                     key: "reply:#{OWNER}:555")

          router.handle(reply_to("continue", 555, chat_id: OWNER))

          assert_equal [["TAB-B", "continue"], ["TAB-B", ""]], backend.calls
        end

        # The tab has closed, and several others remain in the project —
        # this really is ambiguous, and /run NUMBER is still the honest answer.
        def test_reply_asks_to_disambiguate_when_original_tab_is_gone_and_several_remain
          tab_b = Session.new(id: "TAB-B", backend: :iterm2, tty: "/dev/ttys031",
                              cwd: "/tmp/flightlog", agent: :claude_code)
          tab_c = Session.new(id: "TAB-C", backend: :iterm2, tty: "/dev/ttys032",
                              cwd: "/tmp/flightlog", agent: :claude_code)
          router = Router.new(api: @api, store: @store, config: @config,
                              registry: FakeMultiRegistry.new([tab_b, tab_c], RecordingBackend.new))
          @store.put({ "session_id" => "TAB-GONE", "cwd" => "/tmp/flightlog", "label" => "flightlog" },
                     key: "reply:#{OWNER}:555")

          router.handle(reply_to("continue", 555, chat_id: OWNER))

          assert_includes @api.last_text, "several tabs"
        end

        private

        class FakeMultiRegistry
          def initialize(sessions, backend)
            @sessions = sessions
            @backend = backend
          end

          def refresh = self

          def find(id) = @sessions.find { |s| s.id == id }

          def sessions = @sessions

          def agents = @sessions.select(&:agent?)

          def backend_for(_session) = @backend
        end

        class RecordingBackend
          attr_reader :calls

          def initialize = @calls = []

          def send_text(id, text, newline: true)
            @calls << [id, text]
            true
          end
        end

        # An empty response specifically for the backend_api session's
        # capture call, while listing still hands back a normal tab
        # list. The key with the session identifier comes before the
        # generic "osascript" — FakeExecutor takes the first match, and a
        # request with this id in argv (i.e. the capture call, not the
        # listing) gets the empty string.
        def empty_screen_executor
          FakeExecutor.new(
            "-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF,
            Fixtures::BACKEND_API_ID => "",
            "osascript" => Fixtures::ITERM
          )
        end

        def config_with_transcripts
          Config.new({
                       "telegram" => { "allowed_chat_ids" => [OWNER] },
                       "terminal" => { "transcript_root" => File.join(@dir, "projects") }
                     })
        end

        def build_router(config: @config, store: @store, executor: @executor)
          Router.new(
            api: @api,
            registry: Registry.new(executor: executor),
            store: store,
            config: config
          )
        end

        def incoming(text, chat_id:)
          { "message" => { "chat" => { "id" => chat_id }, "text" => text } }
        end

        def reply_to(text, message_id, chat_id:)
          { "message" => { "chat" => { "id" => chat_id }, "text" => text,
                            "reply_to_message" => { "message_id" => message_id } } }
        end

        def pressed(data, chat_id:)
          {
            "callback_query" => {
              "id" => "cb1", "data" => data,
              "message" => { "chat" => { "id" => chat_id } }
            }
          }
        end

        # The callback_data of the button with this text in the sent message.
        def button_key(sent, text)
          sent[:markup][:inline_keyboard].flatten.find { |b| b[:text] == text }[:callback_data]
        end

        # The row number in the last list shown.
        def number_of(fragment, terminalless: false)
          text = @api.texts.reverse.find { |t| t.include?("All tabs") }
          number_of_in(text, fragment, terminalless: terminalless)
        end

        # Message text is now escaped for MarkdownV2 (underscores,
        # dashes, periods become "\_", "\-", "\.") — most tests don't
        # care about that, they need the message's meaning, not its
        # markup, so comparison runs against the original, unescaped form.
        def unescape_markdown(text)
          text.to_s.gsub(/\\([_*\[\]()~`>#+\-=|{}.!\\])/, '\1')
        end

        def number_of_in(text, fragment, terminalless: false)
          line = unescape_markdown(text).lines.find { |l| l.include?(fragment) && (!terminalless || l.include?("vscode")) }

          line[/^\s*(\d+)\./, 1]
        end
      end
    end
  end
end
