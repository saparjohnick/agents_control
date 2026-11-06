# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"

module AgentsControl
  class DaemonTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @config = Config.new({}, path: File.join(@dir, "config.yml"))
      @store = Store.new(path: File.join(@dir, "store.json"))
      @secrets = Secrets.new(providers: [Secrets::Providers::File.new(path: File.join(@dir, "secrets.json"))])
      @logger = StringIO.new
      @reexecs = []
      @daemon = build_daemon
    end

    def teardown = FileUtils.remove_entry(@dir)

    # ── reload! ──────────────────────────────────────────────────────────
    #
    # What the daemon does once asked to restart into updated code —
    # the asking itself is a HUP it traps in #start, sent by `agents_control
    # reload` or by Router's /reload; signal delivery itself isn't tested here.

    def test_reload_execs_the_running_interpreter_and_script
      @daemon.send(:reload!)

      assert_equal [[RbConfig.ruby, $PROGRAM_NAME, *ARGV]], @reexecs
    end

    def test_reload_says_what_it_is_doing
      @daemon.send(:reload!)

      assert_includes @logger.string, "restarting"
    end

    # $PROGRAM_NAME is whatever the current process happens to report —
    # trusted for the exec call, but still checked first: restarting
    # into a path that doesn't exist would just trade a daemon that
    # needs a manual restart for one that is outright gone.
    def test_reload_refuses_to_exec_into_a_script_that_does_not_exist
      with_program_name(File.join(@dir, "no-such-file")) do
        @daemon.send(:reload!)
      end

      assert_empty @reexecs
      assert_includes @logger.string, "couldn't find"
    end

    # exec is a point of no return — by the time it runs, the old
    # process is already gone. Proving the new code can at least load,
    # in a disposable child, is what stops a broken `git pull` or gems
    # out of sync from taking the whole daemon down instead of just
    # declining to apply.
    def test_reload_declines_when_the_updated_code_does_not_even_boot
      broken = FakeExecutor.new("version" => Executor::Result.new(stdout: "", stderr: "cannot load such file -- thor",
                                                                   status: 1))
      daemon = build_daemon(executor: broken)

      daemon.send(:reload!)

      assert_empty @reexecs
      assert_includes @logger.string, "doesn't start up"
      assert_includes @logger.string, "thor"
    end

    def test_reload_proceeds_once_the_updated_code_boots_cleanly
      @daemon.send(:reload!)

      refute_empty @reexecs
    end

    private

    def build_daemon(executor: FakeExecutor.new("version" => 0))
      Daemon.new(config: @config, store: @store, secrets: @secrets, logger: @logger,
                reexec: ->(*args) { @reexecs << args }, executor: executor)
    end

    def with_program_name(value)
      original = $PROGRAM_NAME
      $PROGRAM_NAME = value
      yield
    ensure
      $PROGRAM_NAME = original
    end
  end
end
