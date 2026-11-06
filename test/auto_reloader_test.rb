# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module AgentsControl
  class AutoReloaderTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(@dir, ".git"))
      @restarted = 0
    end

    def teardown = FileUtils.remove_entry(@dir)

    def test_restarts_once_a_pull_moves_the_upstream_ref_and_head_together
      reloader = build(head: "old", upstream: "old")
      reloader.start

      advance(reloader, head: "new", upstream: "new")
      reloader.tick

      assert_equal 1, @restarted
    end

    # The regression this guards: a local commit moves HEAD alone,
    # same as it does all day in this project's own checkout — it must
    # never be mistaken for a pull.
    def test_a_local_commit_does_not_fire_because_the_upstream_ref_does_not_move
      reloader = build(head: "old", upstream: "old")
      reloader.start

      advance(reloader, head: "new-local-commit", upstream: "old")
      reloader.tick

      assert_equal 0, @restarted
    end

    def test_does_nothing_while_nothing_has_moved
      reloader = build(head: "same", upstream: "same")
      reloader.start

      reloader.tick

      assert_equal 0, @restarted
    end

    # The second pull must still be noticed — tracking "changed since
    # boot" instead of "changed since the last check" would miss it.
    def test_a_second_pull_after_a_local_commit_still_fires
      reloader = build(head: "old", upstream: "old")
      reloader.start

      advance(reloader, head: "mid-local-commit", upstream: "old")
      reloader.tick
      advance(reloader, head: "pulled", upstream: "pulled")
      reloader.tick

      assert_equal 1, @restarted
    end

    def test_disabled_by_config_never_fires
      config = Config.new({ "daemon" => { "auto_reload" => false } })
      reloader = build(head: "old", upstream: "old", config: config)
      reloader.start

      advance(reloader, head: "new", upstream: "new")
      reloader.tick

      assert_equal 0, @restarted
    end

    def test_not_a_git_checkout_never_starts_a_thread
      FileUtils.remove_entry(File.join(@dir, ".git"))
      reloader = build(head: "old", upstream: "old")

      reloader.start

      assert_nil reloader.instance_variable_get(:@thread)
    end

    private

    # AutoReloader keeps one GitRoot, built once in #initialize — swap
    # the executor it already holds instead of handing it a new one,
    # so a later tick sees the updated values.
    def advance(reloader, head:, upstream:)
      git = reloader.instance_variable_get(:@git)
      git.instance_variable_set(:@executor, responses(head: head, upstream: upstream))
    end

    def responses(head:, upstream:)
      FakeExecutor.new(
        ->(argv) { argv[3] == "rev-parse" && argv.last == "HEAD" } => head,
        ->(argv) { argv[3] == "rev-parse" && argv.last == "@{u}" } => upstream
      )
    end

    def build(head:, upstream:, config: nil)
      AutoReloader.new(root: @dir, interval: 0, config: config,
                       executor: responses(head: head, upstream: upstream)) { @restarted += 1 }
    end
  end
end
