# frozen_string_literal: true

module AgentsControl
  module Channels
    module Telegram
      # Splits long text into multiple messages instead of clipping the
      # tail or the head — an agent's response is never allowed to be cut short.
      #
      # Telegram's real limit is 4096 UTF-16 code units in the `text`
      # field AFTER entity parsing (core.telegram.org/bots/api#sendmessage,
      # the unit is confirmed at core.telegram.org/api/entities). That's
      # neither UTF-8 bytes nor `String#length` (codepoint count): a
      # non-Latin character is 2 bytes in UTF-8 but 1 unit in UTF-16, so a
      # byte-based estimate is up to twice as conservative as necessary
      # for any non-ASCII text.
      module Chunker
        MAX_MESSAGE = 4096

        module_function

        def utf16_length(text) = text.to_s.encode(Encoding::UTF_16LE).bytesize / 2

        # The RAW text has to be cut, not text already converted to
        # MarkdownV2: a cut inside an escaping pair or a code block would
        # make Telegram reject the whole chunk's parsing. So the chunk
        # boundary is chosen on the raw lines, but measured against the
        # final, converted length — exactly what the API will see.
        def split(text, limit: MAX_MESSAGE)
          lines = text.to_s.each_line.flat_map { |line| fit_line(line, limit) }
          pack(lines, limit)
        end

        # A single line longer than the limit on its own (minified JSON
        # with no line breaks, say) leaves no line boundary to cut at, so
        # it's cut by character with a 2x safety margin: MarkdownV2
        # escaping adds at most one backslash per character, so it can
        # never more than double the text's length.
        def fit_line(line, limit)
          return [line] if utf16_length(line) <= limit

          line.chars.each_slice(limit / 2).map(&:join)
        end

        def pack(pieces, limit)
          chunks = []
          current = +""

          pieces.each do |piece|
            candidate = current + piece
            if !current.empty? && utf16_length(Markdown.convert(candidate)) > limit
              chunks << current
              current = piece
            else
              current = candidate
            end
          end
          chunks << current unless current.empty?

          chunks
        end
      end
    end
  end
end
