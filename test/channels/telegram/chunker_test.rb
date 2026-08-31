# frozen_string_literal: true

require "test_helper"

module AgentsControl
  module Channels
    module Telegram
      class ChunkerTest < Minitest::Test
        # ── measuring length ──────────────────────────────────────────────

        # A non-Latin character is 2 bytes in UTF-8 but 1 unit in
        # UTF-16: a byte-based estimate would be twice as conservative
        # as necessary.
        def test_utf16_length_counts_cyrillic_as_one_unit_per_character
          assert_equal 6, "привет".length
          assert_equal 6, Chunker.utf16_length("привет")
        end

        # Characters outside the BMP (many emoji) take a surrogate pair
        # in UTF-16 — two units, not one, unlike String#length.
        def test_utf16_length_counts_astral_characters_as_two_units
          assert_equal 1, "🔥".length
          assert_equal 2, Chunker.utf16_length("🔥")
        end

        # ── splitting ─────────────────────────────────────────────────────

        def test_short_text_is_a_single_chunk
          chunks = Chunker.split("short text", limit: 4096)

          assert_equal ["short text"], chunks
        end

        def test_empty_text_produces_no_chunks
          assert_empty Chunker.split("", limit: 4096)
        end

        # The key difference from the old clipping: not a single
        # character may be lost — long text is delivered in full, just
        # as multiple messages.
        def test_splitting_never_drops_content
          text = (1..500).map { |i| "line number #{i} with some content" }.join("\n")

          chunks = Chunker.split(text, limit: 200)

          # each_line keeps the separator on every line — chunks already
          # carry their own "\n", so they must be joined with no separator.
          assert_equal text, chunks.join
        end

        def test_each_chunk_fits_the_limit_after_markdown_conversion
          text = (1..500).map { |i| "line #{i}: important.details.with.dots" }.join("\n")

          chunks = Chunker.split(text, limit: 200)

          assert chunks.size > 1
          chunks.each { |c| assert_operator Chunker.utf16_length(Markdown.convert(c)), :<=, 200 }
        end

        # Cut on a line boundary, not mid-line — less risk of breaking
        # formatting a human is looking at.
        def test_prefers_splitting_on_line_boundaries
          text = "#{'a' * 100}\n#{'b' * 100}"

          chunks = Chunker.split(text, limit: 110)

          assert_equal 2, chunks.size
          assert_equal "#{'a' * 100}\n", chunks.first
        end

        # A single line longer than the limit on its own (minified JSON
        # with no line breaks, say) leaves no line boundary to cut on —
        # cut by character instead.
        def test_a_single_line_longer_than_the_limit_is_still_split
          text = "x" * 10_000

          chunks = Chunker.split(text, limit: 100)

          assert chunks.size > 1
          assert_equal text, chunks.join
        end

        # Claude Code's markup (**bold**, code) must not get in the way
        # of splitting: a chunk might accidentally break a `**` pair, and
        # the converter must survive that without raising (Telegram
        # itself will then either accept the text or fall back to plain
        # — that's Channel/Router's concern, not Chunker's).
        def test_survives_splitting_in_the_middle_of_markdown_syntax
          text = "#{'word ' * 50}**important continuation** and more text"

          chunks = Chunker.split(text, limit: 50)

          assert chunks.size > 1
          assert_equal text, chunks.join
        end
      end
    end
  end
end
