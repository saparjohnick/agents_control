# frozen_string_literal: true

require "test_helper"

module AgentsControl
  class ProcessProbeTest < Minitest::Test
    def setup
      @executor = FakeExecutor.new("-o" => Fixtures::PS, "-Fn" => Fixtures::LSOF)
      @probe = ProcessProbe.new(executor: @executor).refresh
    end

    def test_reads_whole_process_tree_in_one_call
      assert_equal 1, @executor.calls.size
      assert @executor.called?("-A")
    end

    def test_finds_agent_in_tab_where_it_actually_runs
      agent = @probe.agent_in("ttys017")

      assert_equal :claude_code, agent.agent
      assert_equal 6221, agent.pid
    end

    # The main case the probe exists for: tab ttys002 has an agent icon
    # in its title, but no agent process actually lives there.
    def test_ignores_tabs_whose_title_lies
      assert_nil @probe.agent_in("ttys002")
    end

    def test_accepts_tty_with_or_without_dev_prefix
      assert_equal @probe.agent_in("ttys017").pid, @probe.agent_in("/dev/ttys017").pid
    end

    def test_foreground_is_the_process_marked_with_plus
      assert_equal "caffeinate", @probe.foreground("ttys017").name
      assert_equal "ssh", @probe.foreground("ttys000").name
    end

    def test_agent_matched_by_basename_not_full_path
      # In a terminal this is `claude`; in VS Code, a long path into the extension's directory.
      vscode = @probe.terminalless_agents.first

      assert_equal :claude_code, vscode.agent
      assert_equal "claude", vscode.name
    end

    def test_collects_agents_that_have_no_terminal_at_all
      pids = @probe.terminalless_agents.map(&:pid)

      assert_equal [1752, 6399, 16141], pids
    end

    def test_terminalless_list_excludes_non_agent_daemons
      names = @probe.terminalless_agents.map(&:name)

      refute_includes names, "secinitd"
    end

    def test_resolves_working_directories_for_pids
      paths = @probe.cwds([1752, 6399, 16141])

      assert_equal "/Users/devbox/projects/flightlog", paths[1752]
      assert_equal 3, paths.size
    end

    def test_cwds_skips_lsof_entirely_when_no_pids_given
      calls_before = @executor.calls.size
      assert_empty @probe.cwds([])
      assert_equal calls_before, @executor.calls.size
    end

    def test_survives_failing_ps
      probe = ProcessProbe.new(executor: FakeExecutor.new).refresh

      assert_empty probe.processes
      assert_nil probe.agent_in("ttys017")
    end
  end
end
