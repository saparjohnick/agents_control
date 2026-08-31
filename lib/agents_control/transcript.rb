# frozen_string_literal: true

require "json"

module AgentsControl
  # The tail of a conversation with an agent.
  #
  # Read from the JSONL file whose path the agent sends with every hook.
  # This beats scraping text off the screen for three reasons: it works
  # the same for a terminal tab and for a VS Code session, which has no
  # screen at all; it gives structure instead of ANSI noise; and it isn't
  # limited to what fit in the visible area.
  class Transcript
    # The file grows without bound, and only the end matters. Read from
    # the end in blocks, so a multi-megabyte history never has to be
    # pulled fully into memory.
    TAIL_BYTES = 256 * 1024

    PROJECTS = File.expand_path("~/.claude/projects")

    class << self
      # The transcript of a tab the hooks never sent anything about.
      #
      # Claude Code lays out histories in directories named after the
      # working path, with `/` and `_` replaced by `-`. If that scheme
      # ever changes, this method just returns an empty transcript
      # instead of breaking its caller.
      def for_cwd(cwd, root: PROJECTS)
        return new(nil) if cwd.to_s.empty?

        directory = File.join(root, slug(cwd))
        new(newest_in(directory))
      end

      def slug(cwd) = cwd.to_s.tr("/_", "--")

      private

      # One directory maps to many sessions — take the most recently modified.
      def newest_in(directory)
        Dir.glob(File.join(directory, "*.jsonl")).max_by { |path| File.mtime(path) }
      end
    end

    def initialize(path)
      @path = path
    end

    def exists? = @path && File.exist?(@path)

    # The last N messages as [{role:, text:}].
    def last(count = 6)
      return [] unless exists?

      messages = parse(tail)
      messages.last(count)
    end

    # Ready-to-send text, in full — splitting across multiple Telegram
    # messages, if needed, is the caller's job (Router#say_chunked).
    def render(count = 6)
      entries = last(count)
      return "The conversation is empty." if entries.empty?

      entries.map { |entry| "#{prefix(entry[:role])} #{entry[:text]}" }.join("\n\n")
    end

    private

    def tail
      size = File.size(@path)
      offset = [size - TAIL_BYTES, 0].max

      File.open(@path, "rb") do |file|
        file.seek(offset)
        # The first line after the offset is almost certainly cut off — discard it.
        file.gets if offset.positive?
        file.read.to_s
      end
    end

    def parse(raw)
      raw.each_line.filter_map do |line|
        entry = JSON.parse(line)
        text = extract(entry)
        next if text.nil? || text.empty?

        { role: entry["type"] || entry.dig("message", "role"), text: text }
      rescue JSON::ParserError
        nil
      end
    end

    # Content is either a string or an array of blocks; tool calls are
    # shown by name, not as the full argument JSON — a notification needs
    # to convey what's happening, not reproduce the call.
    def extract(entry)
      content = entry.dig("message", "content")

      case content
      when String then content
      when Array then extract_blocks(content)
      end
    end

    def extract_blocks(blocks)
      blocks.filter_map do |block|
        case block["type"]
        when "text" then block["text"]
        when "tool_use" then "→ #{block['name']}"
        end
      end.join("\n").strip
    end

    def prefix(role)
      case role.to_s
      when "user" then "🙋"
      when "assistant" then "🤖"
      else "·"
      end
    end
  end
end
