# frozen_string_literal: true

require "fileutils"

module AgentsControl
  # Files arriving from Telegram — a screenshot, a log, a CSV, a screen
  # recording — landed on disk so an agent can read them.
  #
  # On disk, and not as a link, for one reason: Telegram serves file
  # bytes from `/file/bot<TOKEN>/<path>`, so the download URL *is* the
  # bot token. Handing that to an agent would put the token in its
  # context, in the pane, and in the shell history — and this project
  # treats a leaked bot token as equivalent to remote code execution.
  # The URL is built inside Api#download and never leaves it. What the
  # agent gets is a local path.
  class Inbox
    # Order matters: a photo comes as an array of sizes and the last is
    # the largest, while a document carries the original filename. A
    # message can hold exactly one of these.
    KINDS = %w[document photo video audio voice video_note animation].freeze

    # getFile refuses to serve anything larger, so a bigger file is
    # rejected before the round trip rather than after it. The declared
    # size is only the sender's word, though, so the same bound is
    # enforced again on the bytes as they actually arrive.
    MAX_BYTES = 20 * 1024 * 1024

    # Kept out of the project directory on purpose: files arrive from a
    # phone, and dropping them into whatever repository happened to be
    # open would put them in front of `git status` and eventually into
    # a commit.
    def self.path
      base = ENV["XDG_STATE_HOME"] || File.expand_path("~/.local/state")
      File.join(base, "agents_control", "inbox")
    end

    Attachment = Struct.new(:file_id, :file_name, :file_size, :kind, keyword_init: true)

    # The attachment in a message, or nil if it carries none.
    def self.attachment(message)
      KINDS.each do |kind|
        value = message[kind]
        next unless value

        # photo is an array of increasing sizes; the last is the one
        # worth having, since the smaller ones are Telegram's own
        # thumbnails rather than what was sent.
        descriptor = value.is_a?(Array) ? value.last : value
        next unless descriptor.is_a?(Hash) && descriptor["file_id"]

        return Attachment.new(file_id: descriptor["file_id"], file_name: descriptor["file_name"],
                              file_size: descriptor["file_size"], kind: kind)
      end

      nil
    end

    class TooLarge < StandardError; end

    def initialize(api:, dir: self.class.path, keep_days: 14)
      @api = api
      @dir = dir
      @keep_days = keep_days
    end

    # The local path the file landed at.
    def fetch(attachment)
      size = attachment.file_size.to_i
      raise TooLarge, "#{human(size)} is over the #{human(MAX_BYTES)} Telegram allows a bot to download" if size > MAX_BYTES

      remote = @api.file_path_for(attachment.file_id)
      prepare
      destination = File.join(@dir, name_for(attachment, remote))

      download(remote, destination)
      prune
      destination
    end

    private

    # Downloaded beside the destination and renamed into place: a
    # connection that drops half way through otherwise leaves a
    # truncated file with a name that promises a whole one, and the
    # agent reads it as though it were complete.
    def download(remote, destination)
      partial = "#{destination}.part"
      @api.download(remote, to: partial, max_bytes: MAX_BYTES)
      File.chmod(0o600, partial)
      File.rename(partial, destination)
    ensure
      FileUtils.rm_f(partial) if partial && File.exist?(partial)
    end

    def prepare
      FileUtils.mkdir_p(@dir)
      # Logs and screenshots are exactly the kind of thing that carries
      # a token or a customer's name through in passing.
      File.chmod(0o700, @dir)
    end

    # A timestamp prefix rather than a check for collisions: two
    # screenshots sent a minute apart are both called Screenshot.png,
    # and the second one silently replacing the first is worse than
    # having both.
    def name_for(attachment, remote)
      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      base = sanitize(attachment.file_name)
      # The fallback extension comes from getFile's answer, which is
      # Telegram's word and not ours — the API client escapes the same
      # value per segment before it goes into a URL, and it gets the
      # same treatment here rather than being spliced into a filename
      # that will be typed into a shell.
      base = "#{attachment.kind}#{extension(remote)}" if base.empty?

      "#{stamp}-#{base}"
    end

    # Its own cleaning rather than sanitize's, which is written for a
    # whole filename and strips the leading dot an extension needs.
    # Everything but word characters and dots goes: this ends up in a
    # path that gets typed into a shell, and it comes from getFile's
    # answer — Telegram's word, not ours. The API client escapes the
    # same value per segment before putting it in a URL.
    def extension(remote)
      File.extname(remote.to_s).gsub(/[^\w.]/, "")[0, 16]
    end

    # The name comes from whoever sent the file. It decides a path here,
    # so it doesn't get to contain one: no separators, no traversal, no
    # leading dot to hide the result, and short enough for any
    # filesystem to accept.
    def sanitize(name)
      # Stripped before File.basename, which raises on a null byte
      # rather than returning anything — and the name is JSON from
      # Telegram, so it can carry one.
      safe = name.to_s.delete("\u0000").tr("\n\r\t", " ")
      cleaned = File.basename(safe).gsub(/[^\w.\- ]/, "_").squeeze("_").strip
      cleaned = cleaned.sub(/\A\.+/, "")

      cleaned.length > 96 ? "#{cleaned[0, 60]}#{File.extname(cleaned)[0, 16]}" : cleaned
    end

    # Nothing here is meant to be kept: an agent reads the file within
    # minutes of it arriving. Without this the directory only ever
    # grows, and it's full of screenshots and logs.
    def prune
      cutoff = Time.now - (@keep_days * 24 * 60 * 60)

      Dir.glob(File.join(@dir, "*")).each do |path|
        FileUtils.rm_f(path) if File.file?(path) && File.mtime(path) < cutoff
      end
    rescue SystemCallError
      # A directory that can't be tidied is not a reason to refuse the
      # file that was just asked for.
      nil
    end

    def human(bytes) = "#{(bytes / 1024.0 / 1024.0).round(1)}MB"
  end
end
