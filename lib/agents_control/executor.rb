# frozen_string_literal: true

require "open3"

module AgentsControl
  # The single point through which the utility talks to the outside world.
  #
  # Exists for the "adapter isolation" rule: osascript can hang dead when
  # iTerm2 shows a beachball, and without a hard timeout that takes the
  # whole daemon down with it. No adapter calls Open3 directly.
  #
  # Tests swap this for FakeExecutor — no real terminal needed in CI.
  class Executor
    DEFAULT_TIMEOUT = 10

    # status 124 — coreutils timeout(1) convention, 127 — "command not found".
    TIMEOUT_STATUS   = 124
    NOT_FOUND_STATUS = 127

    Result = Struct.new(:stdout, :stderr, :status, keyword_init: true) do
      def success? = status.zero?
      def timeout? = status == TIMEOUT_STATUS
      def not_found? = status == NOT_FOUND_STATUS
    end

    def initialize(timeout: DEFAULT_TIMEOUT)
      @timeout = timeout
    end

    # Always returns a Result — never raises. A failing external command
    # must not take the daemon down with it.
    def run(*argv, stdin: nil, timeout: @timeout)
      Open3.popen3(*argv) do |input, output, errors, wait_thread|
        write_stdin(input, stdin)

        # Read on separate threads: otherwise a process that fills the
        # stderr buffer blocks waiting to be read, while we block waiting
        # for it to exit. report_on_exception is off on purpose: on a
        # timeout, the reader threads find popen3's pipe already closed
        # and raise IOError. That's expected and handled below, but Ruby
        # prints that trace to stderr by default, where it looks like a
        # real crash in the utility's console.
        out_reader = Thread.new { output.read }
        err_reader = Thread.new { errors.read }
        [out_reader, err_reader].each { |thread| thread.report_on_exception = false }

        return kill(wait_thread, out_reader, err_reader, timeout) unless wait_thread.join(timeout)

        Result.new(
          stdout: out_reader.value.to_s,
          stderr: err_reader.value.to_s,
          status: wait_thread.value.exitstatus || -1
        )
      end
    rescue Errno::ENOENT, Errno::EACCES => e
      Result.new(stdout: "", stderr: e.message, status: NOT_FOUND_STATUS)
    end

    private

    def write_stdin(input, data)
      input.write(data) if data
      input.close
    rescue Errno::EPIPE
      # The command exited without reading stdin — that's its right.
    end

    def kill(wait_thread, *readers, timeout)
      begin
        Process.kill("KILL", wait_thread.pid)
        wait_thread.join
      rescue Errno::ESRCH
        # The process died on its own between join and kill.
      end

      # Readers are stopped explicitly: otherwise they stay hanging on
      # already-closed pipes and pile up on every timeout.
      readers.each(&:kill)

      Result.new(stdout: "", stderr: "command didn't respond within #{timeout}s", status: TIMEOUT_STATUS)
    end
  end
end
