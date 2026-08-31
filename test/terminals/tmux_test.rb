# frozen_string_literal: true

require "test_helper"

module AgentsControl
  module Terminals
    class TmuxTest < Minitest::Test
      def setup
        @executor = FakeExecutor.new("list-panes" => Fixtures::TMUX)
        @tmux = Tmux.new(executor: @executor)
      end

      def test_parses_panes
        assert_equal 2, @tmux.sessions.size
      end

      def test_pane_id_is_the_tmux_identifier
        # tmux puts this same identifier in $TMUX_PANE — a hook uses it
        # to find its own pane.
        assert_equal %w[%0 %3], @tmux.sessions.map(&:id)
      end

      def test_title_combines_session_and_window
        assert_equal "work:editor", @tmux.sessions.first.title
      end

      def test_shell_pane_counts_as_being_at_prompt
        shell, agent = @tmux.sessions

        assert_predicate shell, :at_shell_prompt?
        refute_predicate agent, :at_shell_prompt?
      end

      # tmux has no equivalent of `is processing`. The value must stay
      # unknown, not pretend to be false.
      def test_processing_state_is_unknown_rather_than_false
        refute_predicate @tmux.sessions.first, :processing?
        assert_nil @tmux.sessions.first.to_h[:processing]
      end

      def test_format_string_keeps_tmux_placeholders_literal
        @tmux.sessions
        format = @executor.call_with("list-panes")[:argv].last

        assert_includes format, "\#{pane_id}"
        assert_includes format, "\#{pane_current_path}"
        assert_includes format, Fixtures::FS
      end

      # This is exactly why tmux is used: AppleScript doesn't give you history.
      def test_capture_requests_scrollback
        @tmux.capture("%3", lines: 2000)

        assert_includes @executor.call_with("capture-pane")[:argv], "-2000"
      end

      def test_send_keys_appends_enter_only_when_asked
        @tmux.send_text("%3", "ls")
        assert_includes @executor.call_with("send-keys")[:argv], "Enter"

        quiet = FakeExecutor.new("send-keys" => "")
        Tmux.new(executor: quiet).send_text("%3", "ls", newline: false)
        refute_includes quiet.call_with("send-keys")[:argv], "Enter"
      end

      def test_send_keys_stops_option_parsing_before_user_text
        # Without `--`, text starting with a dash would be taken by tmux as its own flag.
        @tmux.send_text("%3", "-n")

        argv = @executor.call_with("send-keys")[:argv]

        assert_equal "--", argv[argv.index("-n") - 1]
      end

      def test_no_panes_when_server_is_not_running
        assert_empty Tmux.new(executor: FakeExecutor.new).sessions
      end

      def test_create_tab_returns_the_new_pane_id
        executor = FakeExecutor.new("new-window" => "%7\n")

        assert_equal "%7", Tmux.new(executor: executor).create_tab(cwd: "/tmp")
      end

      def test_create_tab_passes_the_working_directory
        executor = FakeExecutor.new("new-window" => "%7")

        Tmux.new(executor: executor).create_tab(cwd: "/tmp/project")

        assert_includes executor.call_with("new-window")[:argv], "/tmp/project"
      end
    end
  end
end
