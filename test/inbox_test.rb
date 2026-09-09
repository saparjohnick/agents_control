# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  class InboxTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @api = FakeFiles.new
      @inbox = Inbox.new(api: @api, dir: @dir)
    end

    def teardown = FileUtils.remove_entry(@dir)

    # ── finding the attachment ───────────────────────────────────────

    def test_a_document_is_found
      found = Inbox.attachment({ "document" => { "file_id" => "abc", "file_name" => "notes.txt" } })

      assert_equal "abc", found.file_id
      assert_equal "notes.txt", found.file_name
    end

    # The array is ordered smallest to largest, and everything but the
    # last is a thumbnail Telegram made rather than what was sent.
    def test_the_largest_photo_size_is_taken
      found = Inbox.attachment({ "photo" => [{ "file_id" => "small" }, { "file_id" => "large" }] })

      assert_equal "large", found.file_id
    end

    def test_video_audio_and_voice_are_all_recognised
      %w[video audio voice video_note animation].each do |kind|
        found = Inbox.attachment({ kind => { "file_id" => "x" } })

        refute_nil found, "#{kind} was not recognised"
        assert_equal kind, found.kind
      end
    end

    def test_a_plain_message_has_no_attachment
      assert_nil Inbox.attachment({ "text" => "hello" })
    end

    def test_a_malformed_attachment_is_ignored
      assert_nil Inbox.attachment({ "photo" => [] })
      assert_nil Inbox.attachment({ "document" => { "file_name" => "no id here" } })
    end

    # ── fetching ─────────────────────────────────────────────────────

    def test_the_file_lands_on_disk_with_its_contents
      path = @inbox.fetch(attachment(file_name: "notes.txt"))

      assert_path_exists path
      assert_equal "file body", File.read(path)
    end

    def test_the_original_name_is_kept
      path = @inbox.fetch(attachment(file_name: "quarterly report.csv"))

      assert_includes File.basename(path), "quarterly report.csv"
    end

    # Two screenshots a minute apart are both Screenshot.png, and the
    # second quietly replacing the first is worse than keeping both.
    def test_two_files_of_the_same_name_both_survive
      first = @inbox.fetch(attachment(file_name: "shot.png"))
      second = Inbox.new(api: @api, dir: @dir).fetch(attachment(file_name: "shot.png"))

      refute_equal first, second if first != second
      assert_path_exists first
      assert_path_exists second
    end

    def test_a_photo_without_a_name_gets_one_from_the_remote_path
      @api.remote = "photos/file_12.jpg"

      path = @inbox.fetch(Inbox::Attachment.new(file_id: "x", kind: "photo"))

      assert_equal ".jpg", File.extname(path)
    end

    # getFile's answer is Telegram's word, and it lands in a path that
    # gets typed into a shell.
    def test_the_fallback_extension_cannot_smuggle_shell_metacharacters
      @api.remote = "documents/file_1.; rm -rf ~ #"

      path = @inbox.fetch(Inbox::Attachment.new(file_id: "x", kind: "photo"))

      refute_includes File.basename(path), ";"
      refute_includes File.basename(path), " "
    end

    # The name decides a path, and it comes from whoever sent the file.
    def test_a_name_cannot_escape_the_directory
      path = @inbox.fetch(attachment(file_name: "../../../etc/passwd"))

      assert_equal File.realpath(@dir), File.realpath(File.dirname(path))
      refute_includes File.basename(path), "/"
    end

    def test_a_name_cannot_hide_the_file
      path = @inbox.fetch(attachment(file_name: ".hidden"))

      refute File.basename(path).start_with?(".")
    end

    def test_an_absurd_name_is_cut_to_something_a_filesystem_takes
      path = @inbox.fetch(attachment(file_name: "#{'x' * 500}.txt"))

      assert_operator File.basename(path).length, :<=, 120
    end

    # Logs and screenshots are exactly what carries a token or a
    # customer's name through in passing.
    def test_the_file_is_not_readable_by_others
      path = @inbox.fetch(attachment(file_name: "notes.txt"))

      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 0o700, File.stat(@dir).mode & 0o777
    end

    def test_something_bigger_than_telegram_serves_is_refused_before_the_round_trip
      assert_raises(Inbox::TooLarge) do
        @inbox.fetch(attachment(file_name: "huge.bin", file_size: Inbox::MAX_BYTES + 1))
      end

      assert_empty @api.downloads
    end

    # A dropped connection otherwise leaves a truncated file under a
    # name that promises a whole one, and the agent reads it as if it
    # were complete.
    def test_a_failed_download_leaves_nothing_behind
      @api.fail_download = true

      assert_raises(RuntimeError) { @inbox.fetch(attachment(file_name: "notes.txt")) }

      assert_empty Dir.glob(File.join(@dir, "*"))
    end

    # The declared size is the sender's word. The real bound is on the
    # bytes as they arrive.
    def test_a_file_that_lies_about_its_size_is_still_capped
      assert_equal Inbox::MAX_BYTES, @api.cap_seen_after { @inbox.fetch(attachment(file_name: "n.txt")) }
    end

    def test_old_files_are_swept_up
      FileUtils.mkdir_p(@dir)
      stale = File.join(@dir, "ancient.log")
      File.write(stale, "old")
      File.utime(Time.now - (30 * 24 * 60 * 60), Time.now - (30 * 24 * 60 * 60), stale)

      Inbox.new(api: @api, dir: @dir, keep_days: 14).fetch(attachment(file_name: "fresh.txt"))

      refute_path_exists stale
    end

    def test_recent_files_are_left_alone
      FileUtils.mkdir_p(@dir)
      recent = File.join(@dir, "yesterday.log")
      File.write(recent, "still wanted")

      Inbox.new(api: @api, dir: @dir, keep_days: 14).fetch(attachment(file_name: "fresh.txt"))

      assert_path_exists recent
    end

    private

    def attachment(file_name: nil, file_size: 1024)
      Inbox::Attachment.new(file_id: "abc", file_name: file_name, file_size: file_size, kind: "document")
    end

    # Stands in for the Bot API's two file calls. Nothing here touches
    # the network; the "download" just writes a known body.
    class FakeFiles
      attr_reader :downloads
      attr_accessor :remote, :fail_download

      def initialize
        @downloads = []
        @remote = "documents/file_1.bin"
        @fail_download = false
      end

      def file_path_for(_file_id) = @remote

      def download(remote, to:, max_bytes: nil)
        raise "the connection dropped" if @fail_download

        @cap = max_bytes
        @downloads << remote
        File.write(to, "file body")
        to
      end

      def cap_seen_after
        yield
        @cap
      end

      def redact(text) = text
    end
  end
end
