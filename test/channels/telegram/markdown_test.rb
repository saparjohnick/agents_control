# frozen_string_literal: true

require "test_helper"

module AgentsControl
  module Channels
    module Telegram
      class MarkdownTest < Minitest::Test
        # ── rules checked directly against the real Bot API ─────────────
        #
        # sendMessage with these exact strings and parse_mode=MarkdownV2
        # either actually goes through, or answers with a specific error
        # — both facts verified with curl against a live bot, not taken
        # from the docs.

        def test_reserved_characters_are_escaped_outside_code
          # The API's actual response to an unescaped period:
          # "Character '.' is reserved and must be escaped with the
          # preceding '\'" — so escaping it is mandatory.
          assert_equal 'dot\.', Markdown.convert("dot.")
        end

        def test_every_reserved_character_gets_escaped
          Markdown::RESERVED.each do |char|
            next if char == "\\" # checked separately, below

            assert_equal "\\#{char}", Markdown.convert(char)
          end
        end

        def test_backslash_itself_is_escaped
          assert_equal '\\\\', Markdown.convert("\\")
        end

        # ── code is never touched ───────────────────────────────────────
        #
        # Confirmed against the real API: a period and a backslash inside
        # code pass through unescaped, with no error returned.

        def test_inline_code_content_is_left_untouched
          assert_equal "`code.with.dots`", Markdown.convert("`code.with.dots`")
        end

        def test_fenced_code_content_is_left_untouched
          text = "```\nputs \"hello.\"\n```"
          assert_equal text, Markdown.convert(text)
        end

        # Confirmed against the real API: a ```lang tag before a block
        # sends successfully and turns on syntax highlighting client-side.
        def test_language_tag_on_fenced_code_survives
          text = "```ruby\ndef f; end\n```"
          assert_equal text, Markdown.convert(text)
        end

        def test_prose_around_code_is_escaped_independently
          result = Markdown.convert("result: `x.y` done.")

          assert_equal "result: `x.y` done\\.", result
        end

        def test_backslash_inside_inline_code_is_left_alone
          assert_equal '`path\file`', Markdown.convert('`path\file`')
        end

        # ── **bold** → Telegram *bold* ────────────────────────────────────

        def test_double_asterisk_bold_becomes_single_asterisk
          assert_equal "*important*", Markdown.convert("**important**")
        end

        def test_bold_content_is_still_escaped_inside
          assert_equal "*important\\.*", Markdown.convert("**important.**")
        end

        def test_bold_survives_next_to_code
          result = Markdown.convert("**Summary:** `done`")

          assert_equal "*Summary:*  `done`".sub("  ", " "), result
        end

        # ── robustness ──────────────────────────────────────────────────────

        def test_unclosed_fence_does_not_crash_and_is_escaped_as_prose
          result = Markdown.convert("text ``` with no end")

          refute_nil result
          assert_includes result, "\\`\\`\\`"
        end

        def test_empty_string
          assert_equal "", Markdown.convert("")
        end

        def test_nil_is_handled
          assert_equal "", Markdown.convert(nil)
        end

        def test_consecutive_code_spans
          assert_equal "`a` `b`", Markdown.convert("`a` `b`")
        end

        # ── a realistic agent response ──────────────────────────────────────

        def test_realistic_claude_code_style_message
          input = <<~TEXT
            **Summary:** the build passed.

            Changed `DeviceListViewModel.swift`:

            ```swift
            func refresh() {
                browser.start()
            }
            ```

            Left to do: update AGENTS.md.
          TEXT

          result = Markdown.convert(input)

          assert_includes result, "*Summary:* the build passed\\."
          # A period inside inline code is not escaped — confirmed against the API.
          assert_includes result, "`DeviceListViewModel.swift`"
          assert_includes result, "func refresh() {\n    browser.start()\n}"
          assert_includes result, "Left to do: update AGENTS\\.md\\."
        end
      end
    end
  end
end
