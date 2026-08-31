# frozen_string_literal: true

require "test_helper"

module AgentsControl
  class ExecutorTest < Minitest::Test
    def setup
      @executor = Executor.new
    end

    def test_captures_stdout_and_status
      result = @executor.run("/bin/echo", "hello")

      assert_predicate result, :success?
      assert_equal "hello\n", result.stdout
    end

    def test_reports_failure_without_raising
      result = @executor.run("/bin/sh", "-c", "echo trouble >&2; exit 3")

      refute_predicate result, :success?
      assert_equal 3, result.status
      assert_equal "trouble\n", result.stderr
    end

    # No external command has the right to hang the daemon.
    # osascript hangs dead when iTerm2 shows a beachball.
    def test_kills_a_command_that_outlives_its_timeout
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = @executor.run("/bin/sleep", "30", timeout: 0.3)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_predicate result, :timeout?
      assert_operator elapsed, :<, 5
    end

    def test_missing_binary_is_a_result_not_an_exception
      result = @executor.run("/nonexistent/binary")

      assert_predicate result, :not_found?
      refute_predicate result, :success?
    end

    def test_passes_stdin
      result = @executor.run("/bin/cat", stdin: "data")

      assert_equal "data", result.stdout
    end

    # A command is entitled to not read stdin — that must not take the caller down.
    def test_survives_command_that_ignores_stdin
      result = @executor.run("/bin/echo", "ok", stdin: "x" * 100_000)

      assert_predicate result, :success?
    end

    # A process that fills the stderr buffer would block if the streams
    # were read sequentially after waiting for it to exit.
    def test_does_not_deadlock_on_large_output_in_both_streams
      script = "for i in $(seq 1 2000); do echo out$i; echo err$i >&2; done"
      result = @executor.run("/bin/sh", "-c", script, timeout: 15)

      assert_predicate result, :success?
      assert_equal 2000, result.stdout.lines.size
      assert_equal 2000, result.stderr.lines.size
    end
  end
end
