# frozen_string_literal: true

require "test_helper"

module AgentsControl
  class RegistryTest < Minitest::Test
    def setup
      @executor = FakeExecutor.new(
        "-o" => Fixtures::PS,
        "-Fn" => Fixtures::LSOF,
        "osascript" => Fixtures::ITERM
      )
      @registry = Registry.new(backends: [iterm2], executor: @executor)
    end

    def test_lists_terminal_tabs_and_terminalless_agents_together
      # Four iTerm2 tabs plus three VS Code sessions.
      assert_equal 7, @registry.sessions.size
    end

    def test_agents_are_confirmed_by_processes_not_by_titles
      labels = @registry.agents.map(&:label)

      # mobile-app would land here if we trusted the tab title.
      refute_includes labels, "mobile-app"
      assert_includes labels, "backend_api"
    end

    def test_agent_count_covers_terminal_and_vscode
      # Two in a terminal, three in VS Code.
      assert_equal 5, @registry.agents.size
    end

    def test_stale_tab_stays_in_full_list_but_without_agent
      stale = @registry.sessions.find { |session| session.tty == "/dev/ttys002" }

      refute_predicate stale, :agent?
      assert_equal "✳ Audit unnecessary backend requests (-zsh)", stale.title
    end

    def test_terminalless_sessions_get_directory_from_process
      vscode = @registry.sessions.select(&:terminalless?)

      assert_equal 3, vscode.size
      assert_equal ["flightlog"], vscode.map(&:label).uniq
    end

    def test_terminalless_sessions_have_no_backend
      vscode = @registry.sessions.find(&:terminalless?)

      assert_nil vscode.backend
      assert_equal :none, @registry.backend_for(vscode).name
    end

    def test_foreground_command_comes_from_process_tree
      tab = @registry.sessions.find { |session| session.tty == "/dev/ttys017" }

      # The title says "Claude Code", but caffeinate is on top right now.
      assert_equal "caffeinate", tab.foreground_command
    end

    def test_processing_flag_survives_from_terminal
      busy = @registry.sessions.find { |session| session.tty == "/dev/ttys018" }

      assert_predicate busy, :processing?
    end

    def test_one_broken_backend_does_not_break_the_list
      registry = Registry.new(backends: [exploding_backend, iterm2], executor: @executor)

      assert_equal 7, registry.sessions.size
    end

    def test_refresh_rebuilds_the_list
      @registry.sessions
      calls = @executor.calls.size

      @registry.refresh.sessions

      assert_operator @executor.calls.size, :>, calls
    end

    private

    def iterm2 = Terminals::ITerm2.new(executor: @executor)

    def exploding_backend
      Class.new(Terminals::Base) do
        def name = :broken
        def available? = true
        def sessions = raise("backend fell over")
      end.new(executor: @executor)
    end
  end
end
