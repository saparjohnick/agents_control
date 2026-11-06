# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module AgentsControl
  class AutoUpdaterTest < Minitest::Test
    DAY = 86_400

    def setup
      @dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(@dir, ".git"))
      @updated = 0
    end

    def teardown = FileUtils.remove_entry(@dir)

    def test_pulls_and_fires_when_everything_lines_up
      build(git: git_responses(pushed_days_ago: 5)).tick

      assert_equal 1, @updated
    end

    def test_does_nothing_up_to_date
      build(git: git_responses(local: "same", remote: "same", pushed_days_ago: 5)).tick

      assert_equal 0, @updated
    end

    def test_does_nothing_with_a_dirty_working_tree
      build(git: git_responses(pushed_days_ago: 5, porcelain: " M lib/thing.rb\n")).tick

      assert_equal 0, @updated
    end

    def test_does_nothing_when_local_history_has_diverged
      build(git: git_responses(pushed_days_ago: 5, ancestor: false)).tick

      assert_equal 0, @updated
    end

    # The whole point of the delay: a commit pushed five minutes ago
    # isn't adopted yet, however clean and fast-forwardable it is.
    def test_does_nothing_when_the_update_is_too_recent
      build(git: git_responses(pushed_days_ago: 0)).tick

      assert_equal 0, @updated
    end

    def test_does_nothing_without_an_upstream_branch
      build(git: git_responses(pushed_days_ago: 5, has_upstream: false)).tick

      assert_equal 0, @updated
    end

    def test_disabled_by_config_never_fires
      config = Config.new({ "daemon" => { "auto_update" => false } })

      build(git: git_responses(pushed_days_ago: 5), config: config).tick

      assert_equal 0, @updated
    end

    # Fetching and pulling on its own is the opt-in half — a real
    # Config with no override (unlike the nil used elsewhere in this
    # file, which always means "on") goes through Config::DEFAULTS,
    # where daemon.auto_update is false. AutoReloader, the half that
    # only restarts into code already pulled by hand, is the one that
    # defaults to on — see auto_reloader_test.rb.
    def test_off_by_default_with_a_real_config
      build(git: git_responses(pushed_days_ago: 5), config: Config.new({})).tick

      assert_equal 0, @updated
    end

    def test_a_failed_fast_forward_does_not_fire
      build(git: git_responses(pushed_days_ago: 5, merge_result: 1)).tick

      assert_equal 0, @updated
    end

    def test_not_a_git_checkout_never_starts_a_thread
      FileUtils.remove_entry(File.join(@dir, ".git"))
      updater = build(git: git_responses(pushed_days_ago: 5))

      updater.start

      assert_nil updater.instance_variable_get(:@thread)
    end

    private

    # Only the subcommand (argv[3], after the binary, "-C", and root)
    # needs to be told apart — AutoUpdater never issues the same one
    # twice with a different meaning.
    def git_responses(local: "old", remote: "new", pushed_days_ago: 5, porcelain: "",
                      ancestor: true, has_upstream: true, merge_result: 0)
      {
        ->(argv) { argv[3] == "rev-parse" && argv.include?("--symbolic-full-name") } => (has_upstream ? 0 : 1),
        ->(argv) { argv[3] == "status" } => porcelain,
        ->(argv) { argv[3] == "fetch" } => 0,
        ->(argv) { argv[3] == "rev-parse" && argv.last == "HEAD" } => local,
        ->(argv) { argv[3] == "rev-parse" && argv.last == "@{u}" } => remote,
        ->(argv) { argv[3] == "merge-base" } => (ancestor ? 0 : 1),
        ->(argv) { argv[3] == "log" } => (Time.now.to_i - (pushed_days_ago * DAY)).to_s,
        ->(argv) { argv[3] == "merge" } => merge_result
      }
    end

    def build(git:, config: nil)
      executor = FakeExecutor.new(git)
      AutoUpdater.new(root: @dir, interval: 0, config: config, executor: executor) { @updated += 1 }
    end
  end
end
