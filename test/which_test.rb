# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  class WhichTest < Minitest::Test
    def test_finds_a_real_system_binary
      assert_equal "/bin/sh", Which.find("sh")
    end

    def test_returns_nil_for_missing_binary
      assert_nil Which.find("definitely-not-a-binary-#{rand(1_000_000)}")
    end

    def test_raises_with_a_useful_message
      error = assert_raises(Which::NotFoundError) { Which.find!("nope-#{rand(1_000_000)}") }

      assert_match(/nope-/, error.message)
    end

    # The daemon starts from launchd, not a shell, and PATH is different
    # there — explicit directories have to win over whatever PATH says.
    def test_explicit_directories_win_over_path
      Dir.mktmpdir do |preferred|
        Dir.mktmpdir do |from_path|
          %W[#{preferred}/tool #{from_path}/tool].each do |path|
            File.write(path, "#!/bin/sh\n")
            File.chmod(0o755, path)
          end

          with_path(from_path) do
            assert_equal "#{preferred}/tool", Which.find("tool", extra_dirs: [preferred])
          end
        end
      end
    end

    def test_falls_back_to_path_when_known_directories_miss
      Dir.mktmpdir do |dir|
        File.write("#{dir}/tool", "#!/bin/sh\n")
        File.chmod(0o755, "#{dir}/tool")

        with_path(dir) { assert_equal "#{dir}/tool", Which.find("tool") }
      end
    end

    def test_ignores_files_that_are_not_executable
      Dir.mktmpdir do |dir|
        File.write("#{dir}/tool", "not executable")

        with_path(dir) { assert_nil Which.find("tool") }
      end
    end

    private

    def with_path(value)
      original = ENV.fetch("PATH", nil)
      ENV["PATH"] = value
      yield
    ensure
      ENV["PATH"] = original
    end
  end
end
