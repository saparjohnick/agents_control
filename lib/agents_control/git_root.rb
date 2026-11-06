# frozen_string_literal: true

module AgentsControl
  # A git checkout's root, shared by whatever polls it — AutoReloader
  # (restarts into code already pulled by someone else) and AutoUpdater
  # (pulls it itself). Both need the same three things: find the
  # binary, confirm there's actually a checkout here, run a command in
  # it — this is that, written once.
  class GitRoot
    def initialize(root:, executor: Executor.new)
      @root = root
      @executor = executor
    end

    def checkout? = path && File.directory?(File.join(@root, ".git"))

    def run(*args, timeout: 30)
      return Executor::Result.new(stdout: "", stderr: "git not found", status: 127) unless path

      @executor.run(path, "-C", @root, *args, timeout: timeout)
    end

    private

    # false means "looked and didn't find it", so we don't search again on every call.
    def path
      @path = Which.find("git") || false if @path.nil?
      @path || nil
    end
  end
end
