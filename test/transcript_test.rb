# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  class TranscriptTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @path = File.join(@dir, "session.jsonl")
      File.write(@path, Fixtures::TRANSCRIPT_LINES)
    end

    def teardown = FileUtils.remove_entry(@dir)

    def test_reads_the_tail_of_the_conversation
      entries = Transcript.new(@path).last(3)

      assert_equal 3, entries.size
      assert_equal "fix the build", entries.first[:text]
    end

    # Tool calls are shown by name: a notification needs to convey what's
    # happening, not reproduce the arguments.
    def test_tool_calls_are_shown_by_name
      text = Transcript.new(@path).render

      assert_includes text, "→ Bash"
      refute_includes text, '"input"'
    end

    def test_render_marks_who_said_what
      text = Transcript.new(@path).render

      assert_includes text, "🙋"
      assert_includes text, "🤖"
    end

    def test_missing_file_is_not_an_error
      transcript = Transcript.new(File.join(@dir, "no-such-file.jsonl"))

      refute_predicate transcript, :exists?
      assert_empty transcript.last
    end

    def test_nil_path_is_handled
      refute_predicate Transcript.new(nil), :exists?
    end

    # The file is written line by line and can be read mid-write.
    def test_broken_lines_are_skipped
      File.write(@path, "{cut off\n#{Fixtures::TRANSCRIPT_LINES}")

      assert_equal 3, Transcript.new(@path).last(5).size
    end

    # Splitting across multiple Telegram messages is the caller's job
    # (Router#say_chunked via Chunker), not this method's: it must hand
    # back the message whole, uncut.
    def test_long_output_is_not_clipped
      long = ({ "type" => "assistant",
                "message" => { "role" => "assistant",
                               "content" => "x" * 5000 } }).to_json
      File.write(@path, long)

      assert_equal "x" * 5000, Transcript.new(@path).render(1).delete_prefix("🤖 ")
    end

    # ── recently touched files ──────────────────────────────────────────────

    def test_recent_files_are_most_recent_first
      File.write(@path, Fixtures::TRANSCRIPT_WITH_FILES)

      assert_equal ["#{Fixtures::CWD}/Gemfile", "#{Fixtures::CWD}/app.rb"],
                   Transcript.new(@path).recent_files
    end

    # Gemfile is read twice — it must take one slot, at its latest
    # touch, not crowd out app.rb by appearing as two entries.
    def test_a_file_touched_twice_only_takes_one_slot
      File.write(@path, Fixtures::TRANSCRIPT_WITH_FILES)

      files = Transcript.new(@path).recent_files(10)

      assert_equal 2, files.size
    end

    # Bash runs a command, not a file — it must never be mistaken for one.
    def test_tool_calls_with_no_file_are_not_recent_files
      File.write(@path, Fixtures::TRANSCRIPT_WITH_FILES)

      refute_includes Transcript.new(@path).recent_files(10), "bundle install"
    end

    def test_recent_files_respects_the_requested_count
      File.write(@path, Fixtures::TRANSCRIPT_WITH_FILES)

      assert_equal 1, Transcript.new(@path).recent_files(1).size
    end

    def test_recent_files_on_a_missing_transcript_is_empty
      transcript = Transcript.new(File.join(@dir, "no-such-file.jsonl"))

      assert_empty transcript.recent_files
    end

    # ── lookup by working directory ────────────────────────────────────────

    # Claude Code lays out histories in a directory named after the
    # working path with `/` and `_` replaced by `-`. The scheme was
    # captured from three real projects.
    def test_slug_replaces_slashes_and_underscores
      assert_equal "-Users-devbox-projects-agents-control",
                   Transcript.slug("/Users/devbox/projects/agents_control")
    end

    def test_finds_transcript_by_working_directory
      root = File.join(@dir, "projects")
      cwd = "/Users/someone/proj/some_app"
      project = File.join(root, Transcript.slug(cwd))
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "a.jsonl"), Fixtures::TRANSCRIPT_LINES)

      assert_predicate Transcript.for_cwd(cwd, root: root), :exists?
    end

    # One directory maps to many sessions — the most recent one is needed.
    def test_picks_the_most_recent_session
      root = File.join(@dir, "projects")
      cwd = "/Users/someone/proj"
      project = File.join(root, Transcript.slug(cwd))
      FileUtils.mkdir_p(project)

      File.write(File.join(project, "old.jsonl"), Fixtures::TRANSCRIPT_LINES)
      File.utime(Time.now - 3600, Time.now - 3600, File.join(project, "old.jsonl"))
      File.write(File.join(project, "fresh.jsonl"), Fixtures::TRANSCRIPT_LINES)

      assert_match(/fresh/, Transcript.for_cwd(cwd, root: root).instance_variable_get(:@path))
    end

    # The naming scheme might change one day — that's not a reason to crash.
    def test_unknown_directory_yields_an_empty_transcript
      refute_predicate Transcript.for_cwd("/no/such/thing", root: @dir), :exists?
    end

    def test_empty_cwd_is_handled
      refute_predicate Transcript.for_cwd(nil), :exists?
    end

    # The history grows without bound, and only the end matters.
    def test_huge_file_is_read_from_the_end
      line = { "type" => "user", "message" => { "role" => "user", "content" => "noise" } }.to_json
      File.write(@path, "#{([line] * 20_000).join("\n")}\n#{Fixtures::TRANSCRIPT_LINES}")

      entries = Transcript.new(@path).last(1)

      assert_includes entries.first[:text], "continue, or show the plan"
    end
  end
end
