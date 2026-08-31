# frozen_string_literal: true

module AgentsControl
  # Finds executables by absolute path rather than via PATH.
  #
  # The daemon is launched by launchd, not an interactive shell, and PATH
  # is different there: Ruby version-manager shims may be missing, and an
  # Intel Homebrew install on Apple Silicon without Rosetta doesn't run at
  # all. So PATH is checked last, not first.
  module Which
    # Directories in order of trust: version managers and ARM Homebrew
    # first, then system paths, and only then whatever PATH turns up.
    SEARCH_DIRS = [
      "~/.asdf/shims",
      "~/.rbenv/shims",
      "/opt/homebrew/bin",
      "/opt/homebrew/sbin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin"
    ].freeze

    module_function

    # Absolute path to the binary, or nil.
    def find(name, extra_dirs: [])
      dirs = extra_dirs + SEARCH_DIRS
      from_dirs(name, dirs) || from_path(name)
    end

    # Like find, but with a clear error instead of nil — for places where
    # a missing binary means there's no point continuing.
    def find!(name, extra_dirs: [])
      find(name, extra_dirs: extra_dirs) ||
        raise(NotFoundError, "executable not found: #{name.inspect}")
    end

    def from_dirs(name, dirs)
      dirs.lazy
          .map { |dir| File.join(File.expand_path(dir), name) }
          .find { |path| executable?(path) }
    end

    def from_path(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).lazy
         .reject(&:empty?)
         .map { |dir| File.join(dir, name) }
         .find { |path| executable?(path) }
    end

    def executable?(path)
      File.file?(path) && File.executable?(path)
    end

    class NotFoundError < StandardError; end
  end
end
