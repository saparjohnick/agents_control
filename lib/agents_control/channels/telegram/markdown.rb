# frozen_string_literal: true

module AgentsControl
  module Channels
    module Telegram
      # Turns plain GFM-like text — the shape Claude Code writes — into
      # Telegram MarkdownV2.
      #
      # Escaping rules:
      #
      #   - outside code, the 18 characters `_*[]()~`>#+-=|{}.!` must be
      #     backslash-escaped, or sendMessage answers with a 400: Bad
      #     Request: can't parse entities: Character '.' is reserved…
      #   - inside `inline code` and ```blocks``` those same characters
      #     must NOT be escaped — there they're just text;
      #   - a ```lang tag before a block is accepted and syntax-highlighted.
      #
      # This is Telegram's strict mode: one incorrectly escaped period
      # and the whole message fails to send. So the converter is written
      # conservatively (it never touches code, and escapes prose in
      # full), and the Api side still carries its own separate
      # safety net — falling back to plain text if Telegram rejects it anyway.
      module Markdown
        # Escaped outside code. Order matters: `\` goes first, or the
        # escaping slashes would themselves get escaped again.
        RESERVED = %w[\\ _ * [ ] ( ) ~ ` > # + - = | { } . !].freeze

        # Code is what must never be touched: even the opening triple
        # quote can carry a language tag (```ruby) that has to be kept
        # literal, not escaped.
        CODE = /(```.*?```|`[^`\n]+`)/m

        # One of the few GFM constructs worth preserving as actual
        # formatting rather than turning into escaped asterisks: Claude
        # Code often puts **important** text in headings and summaries.
        BOLD = /\*\*(.+?)\*\*/m

        module_function

        def convert(text)
          text.to_s.split(CODE).each_with_index.map do |chunk, index|
            index.odd? ? chunk : escape_prose(chunk)
          end.join
        end

        def escape_prose(text)
          text.split(BOLD).each_with_index.map do |chunk, index|
            index.odd? ? "*#{escape_literal(chunk)}*" : escape_literal(chunk)
          end.join
        end

        def escape_literal(text)
          pattern = Regexp.union(RESERVED)
          text.gsub(pattern) { |char| "\\#{char}" }
        end
      end
    end
  end
end
