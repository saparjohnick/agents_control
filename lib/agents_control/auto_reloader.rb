# frozen_string_literal: true

module AgentsControl
  # Restarts into code that's already on disk — never fetched, just
  # noticed. Something else (the person at a keyboard, an agent, a cron
  # job) already made the call to `git pull`; this exists so that
  # choice doesn't also require remembering to restart the daemon by
  # hand. See AutoUpdater for the other half — going and fetching that
  # code in the first place — which is a separate, more cautious call
  # to make, gated by its own config key and a multi-day delay.
  #
  # Watches the upstream branch moving, not HEAD: this daemon often
  # runs from the very checkout it's being developed in, where HEAD
  # moves on every local commit — restarting on each of those would
  # make iterating on this project itself unworkable. A pull is what
  # moves the local copy of the upstream ref; a local commit never does.
  #
  # No delay here on purpose, unlike AutoUpdater: whoever pulled the
  # code already decided to trust it today, not after it's sat
  # untested for two days — that waiting period belongs to
  # AutoUpdater's own, unattended fetch-and-merge.
  class AutoReloader
    def self.default_root = File.expand_path("../..", __dir__)

    def initialize(root: self.class.default_root, interval: 60, config: nil,
                   executor: Executor.new, logger: nil, &on_update)
      @git = GitRoot.new(root: root, executor: executor)
      @interval = interval
      @config = config
      @logger = logger
      @on_update = on_update
      @running = false
    end

    def start
      return self unless enabled? && @on_update && @git.checkout?

      @last_upstream = upstream
      @running = true
      @thread = Thread.new { tick while @running }
      self
    end

    def stop
      @running = false
      @thread&.kill
    end

    def tick
      restart_if_pulled if enabled?
    rescue StandardError => e
      log("failure: #{e.class}: #{e.message}")
    ensure
      sleep(@interval) if @running
    end

    private

    def enabled? = @config.nil? || @config.get("daemon.auto_reload", true)

    # A pull moves the local copy of the upstream branch, not just
    # HEAD — a local commit moves HEAD alone, leaving the upstream ref
    # exactly where it was. Watching the upstream ref, not HEAD, is
    # what tells "someone pulled" apart from "someone's mid-edit,
    # committing in the very checkout this daemon runs from" — which
    # is this project's own daily workflow, and must never trigger a restart.
    def restart_if_pulled
      current = upstream
      moved = current && current != @last_upstream
      @last_upstream = current
      return unless moved && current == head

      log("pulled to #{current.slice(0, 7)} — restarting into it")
      @running = false
      @on_update.call
    end

    def upstream
      result = @git.run("rev-parse", "@{u}", timeout: 10)
      result.success? ? result.stdout.strip : nil
    end

    def head
      result = @git.run("rev-parse", "HEAD", timeout: 10)
      result.success? ? result.stdout.strip : nil
    end

    def log(message)
      @logger&.puts("[auto-reload] #{message}")
    rescue StandardError
      nil
    end
  end
end
