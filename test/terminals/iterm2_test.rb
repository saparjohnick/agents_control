# frozen_string_literal: true

require "test_helper"

module AgentsControl
  module Terminals
    class ITerm2Test < Minitest::Test
      def setup
        @executor = FakeExecutor.new("osascript" => Fixtures::ITERM, "-o" => Fixtures::PS)
        @iterm = ITerm2.new(executor: @executor)
      end

      def test_parses_all_sessions
        assert_equal 4, @iterm.sessions.size
      end

      def test_session_id_matches_iterm_session_id_variable
        # This is the identifier iTerm2 puts in ITERM_SESSION_ID, and it's
        # exactly what an agent's hook uses to tie itself to its tab.
        assert_equal "D63D6009-F477-44EE-B890-54C1B30E8B69", @iterm.sessions.first.id
      end

      def test_reads_state_flags
        busy = @iterm.sessions.find { |session| session.tty == "/dev/ttys018" }
        idle = @iterm.sessions.find { |session| session.tty == "/dev/ttys002" }

        assert_predicate busy, :processing?
        refute_predicate idle, :processing?
        assert_predicate idle, :at_shell_prompt?
      end

      def test_reads_working_directory
        session = @iterm.sessions.find { |s| s.tty == "/dev/ttys017" }

        assert_equal "/Users/devbox/projects/backend_api", session.cwd
        assert_equal "backend_api", session.label
      end

      # Titles contain non-Latin scripts, emoji, braille spinners, and
      # brackets — so control characters serve as separators, not `|` or a tab.
      def test_keeps_arbitrary_text_in_titles_intact
        titles = @iterm.sessions.map(&:title)

        assert_includes titles, "⠐ Claude Code session monitor (caffeinate)"
      end

      def test_title_containing_separator_like_characters_does_not_split_record
        row = ["ID", "/dev/ttys099", "false", "false", "/tmp", "a | b\tc — d"]
        executor = FakeExecutor.new("osascript" => row.join(Fixtures::FS) + Fixtures::RS)

        session = ITerm2.new(executor: executor).sessions.first

        assert_equal "a | b\tc — d", session.title
      end

      # Talking to the app over AppleScript launches it if it's closed.
      # An availability check has no business opening a terminal on the user.
      def test_availability_check_never_touches_applescript
        assert_predicate @iterm, :available?
        refute @executor.called?("osascript")
      end

      # pgrep won't do here: on macOS `-x` matches against the full path,
      # and in a restricted environment it misses processes that ps sees fine.
      def test_availability_check_does_not_rely_on_pgrep
        @iterm.available?

        refute @executor.called?("pgrep")
      end

      def test_unavailable_when_iterm_is_not_running
        executor = FakeExecutor.new("-o" => Fixtures::PS_WITHOUT_ITERM)

        refute_predicate ITerm2.new(executor: executor), :available?
      end

      # Matched by exact basename, not substring: an iTermServer helper
      # process runs alongside, and it must not be mistaken for the app itself.
      def test_app_is_matched_by_exact_name
        probe = ProcessProbe.new(executor: FakeExecutor.new("-o" => Fixtures::PS)).refresh

        assert probe.running?("iTerm2")
        refute probe.running?("iTerm")
      end

      def test_empty_list_when_applescript_fails
        assert_empty ITerm2.new(executor: FakeExecutor.new).sessions
      end

      # The script goes over stdin, values via argv. Otherwise a session
      # identifier or an arbitrary user command becomes an AppleScript injection.
      def test_values_are_passed_as_arguments_not_interpolated_into_script
        @iterm.send_text("SESSION-ID", 'say "boom" & do shell script "rm -rf /"')

        call = @executor.call_with("osascript")

        assert_includes call[:argv], "SESSION-ID"
        assert_includes call[:argv], 'say "boom" & do shell script "rm -rf /"'
        refute_includes call[:stdin], "boom"
      end

      def test_send_text_controls_newline
        @iterm.send_text("ID", "ls", newline: false)

        assert_includes @executor.call_with("osascript")[:stdin], "newline false"
      end

      def test_capture_returns_only_requested_tail
        executor = FakeExecutor.new("osascript" => (1..500).map { |i| "line #{i}" }.join("\n"))

        captured = ITerm2.new(executor: executor).capture("ID", lines: 5)

        assert_equal 5, captured.lines.size
        assert_equal "line 500", captured.lines.last
      end

      # `contents of s` hands back the whole visible screen, including
      # blank filler lines below the text when it doesn't reach the
      # bottom of the pane. `.last(N)` without trimming that tail first
      # took N lines of blank space — the method silently returned "" for
      # any pane taller than its content.
      def test_capture_skips_blank_padding_at_the_bottom_of_a_tall_pane
        screen = (["real text one", "real text two"] + Array.new(40) { " " }).join("\n")
        executor = FakeExecutor.new("osascript" => screen)

        captured = ITerm2.new(executor: executor).capture("ID", lines: 8)

        assert_equal "real text one\nreal text two", captured
      end

      def test_capture_of_a_pane_showing_nothing_but_blanks_is_empty
        executor = FakeExecutor.new("osascript" => Array.new(20) { " " }.join("\n"))

        assert_equal "", ITerm2.new(executor: executor).capture("ID", lines: 8)
      end

      # When the real text is itself longer than the requested tail,
      # behavior must not change: take the last N lines of CONTENT, not
      # of the screen.
      def test_capture_still_clips_to_the_requested_tail_after_removing_padding
        lines = (1..30).map { |i| "line #{i}" }
        screen = (lines + Array.new(15) { " " }).join("\n")
        executor = FakeExecutor.new("osascript" => screen)

        captured = ITerm2.new(executor: executor).capture("ID", lines: 5)

        assert_equal "line 26\nline 27\nline 28\nline 29\nline 30", captured
      end

      def test_create_tab_returns_new_session_id
        executor = FakeExecutor.new("osascript" => "NEW-ID\n")

        assert_equal "NEW-ID", ITerm2.new(executor: executor).create_tab(cwd: "/tmp")
      end
    end
  end
end
