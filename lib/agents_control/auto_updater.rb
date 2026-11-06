# frozen_string_literal: true

module AgentsControl
  # Fetches a tracked git remote on a schedule and pulls + restarts
  # into it — only when a plain `git pull --ff-only` would be the
  # honest answer anyway: clean working tree, no diverged local
  # history, and the upstream commit old enough that it isn't the
  # latest thing pushed a minute ago. git only, never RubyGems — a gem
  # install has no working tree to check for local edits against.
  #
  # Opt-in, and deliberately cautious about it: this is the one of the
  # two that reaches out on its own and decides to trust whatever's
  # newest upstream, unattended. AutoReloader is the other half —
  # restarting into code someone already chose to pull themselves —
  # and defaults to on, since it isn't making that same call on its own.
  class AutoUpdater
    def self.default_root = File.expand_path("../..", __dir__)

    def initialize(root: self.class.default_root, interval: 7 * 86_400, delay: 2 * 86_400,
                   config: nil, executor: Executor.new, logger: nil, &on_update)
      @root = root
      @git = GitRoot.new(root: root, executor: executor)
      @interval = interval
      @delay = delay
      @config = config
      @executor = executor
      @logger = logger
      @on_update = on_update
      @running = false
    end

    def start
      return self unless auto_update_enabled? && @on_update && @git.checkout?

      @running = true
      @thread = Thread.new { tick while @running }
      self
    end

    def stop
      @running = false
      @thread&.kill
    end

    def tick
      check_for_update if auto_update_enabled?
    rescue StandardError => e
      log("failure: #{e.class}: #{e.message}")
    ensure
      sleep(@interval) if @running
    end

    private

    def auto_update_enabled? = @config.nil? || @config.get("daemon.auto_update", false)

    def check_for_update
      return unless tracks_upstream? && working_tree_clean?

      fetch = @git.run("fetch", "--quiet")
      return log("couldn't fetch: #{fetch.stderr.strip}") unless fetch.success?
      return unless fast_forwardable? && upstream_old_enough?

      apply_update
    end

    def tracks_upstream?
      @git.run("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}").success?
    end

    def working_tree_clean? = @git.run("status", "--porcelain").stdout.strip.empty?

    def fast_forwardable?
      local = @git.run("rev-parse", "HEAD").stdout.strip
      remote = @git.run("rev-parse", "@{u}").stdout.strip
      return false if local.empty? || remote.empty? || local == remote

      @git.run("merge-base", "--is-ancestor", "HEAD", "@{u}").success?
    end

    def upstream_old_enough?
      pushed_at = @git.run("log", "-1", "--format=%ct", "@{u}").stdout.strip
      return false if pushed_at.empty?

      (Time.now.to_i - pushed_at.to_i) >= @delay
    end

    def apply_update
      merge = @git.run("merge", "--ff-only", "@{u}")
      return log("found an update but couldn't fast-forward: #{merge.stderr.strip}") unless merge.success?
      return log("pulled an update but `bundle install` failed — not restarting into it") unless bundle_install

      log("pulled an update — restarting into it")
      @running = false
      @on_update.call
    end

    # Best-effort: no bundler and no Gemfile both just mean there's
    # nothing to install, same as succeeding.
    def bundle_install
      bundle = Which.find("bundle")
      return true unless bundle && File.exist?(File.join(@root, "Gemfile"))

      @executor.run(bundle, "install", "--gemfile", File.join(@root, "Gemfile"), timeout: 300).success?
    end

    def log(message)
      @logger&.puts("[auto-updater] #{message}")
    rescue StandardError
      nil
    end
  end
end
