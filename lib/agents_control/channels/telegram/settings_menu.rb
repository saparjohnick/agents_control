# frozen_string_literal: true

module AgentsControl
  module Channels
    module Telegram
      # The settings menu inside the bot.
      #
      # Settings are needed here, not just in the CLI: they need
      # changing exactly when the keyboard is out of reach. The token is
      # the exception — it's set only via the CLI, because without it
      # there's no way to talk to the bot at all.
      class SettingsMenu
        # What can be toggled. Order is display order.
        TOGGLES = [
          { key: "answers.away", label: "Mode",
            on: "🚶 away", off: "🪑 present", default: false },
          { key: "answers.auto_continue", label: "Auto-reply \"continue\"",
            on: "✅ on", off: "❌ off", default: true },
          { key: "answers.auto_approve_permissions", label: "Auto-approve tools",
            on: "⚠️ on", off: "❌ off", default: false },
          { key: "answers.notify_when_present", label: "Notify while present",
            on: "✅ on", off: "❌ off", default: true },
          { key: "anchors.enabled", label: "Rate-limit anchors",
            on: "✅ on", off: "❌ off", default: false }
        ].freeze

        # Numeric settings: cycling through a step instead of typing text
        # — noticeably faster on a phone.
        CHOICES = [
          { key: "answers.reply_timeout", label: "Reply timeout",
            values: [300, 600, 900, 1800, 3600], unit: "s", default: 900 },
          { key: "terminal.context_lines", label: "Context lines",
            values: [40, 80, 200, 500], unit: "", default: 80 }
        ].freeze

        def initialize(store:, config:)
          @store = store
          @config = config
        end

        # List rows without a header — the console shows the same rows
        # in a menu navigated with arrow keys.
        def rows
          (TOGGLES + CHOICES).map { |item| "#{item[:label]}: #{value_label(item)}" }
        end

        def text
          (["⚙️ Settings", ""] + rows + ["", warning].compact).join("\n")
        end

        def markup
          rows = TOGGLES.map { |item| [toggle_button(item)] }
          rows += CHOICES.map { |item| [choice_button(item)] }

          { inline_keyboard: rows }
        end

        # Apply a press and return what changed, to show the human.
        def apply(payload)
          item = find(payload["key"])
          return nil unless item

          @config.set(item[:key], next_value(item)).save

          "#{item[:label]}: #{value_label(item)}"
        end

        private

        def find(key) = (TOGGLES + CHOICES).find { |item| item[:key] == key }

        def current(item) = @config.get(item[:key], item[:default])

        def next_value(item)
          return !current(item) unless item[:values]

          values = item[:values]
          values[(values.index(current(item)).to_i + 1) % values.size]
        end

        def value_label(item)
          return "#{current(item)}#{item[:unit].empty? ? '' : " #{item[:unit]}"}" if item[:values]

          current(item) ? item[:on] : item[:off]
        end

        def toggle_button(item)
          { text: "#{item[:label]}: #{value_label(item)}",
            callback_data: action(item) }
        end

        def choice_button(item)
          { text: "#{item[:label]}: #{value_label(item)} →",
            callback_data: action(item) }
        end

        def action(item)
          @store.put({ "action" => "setting", "key" => item[:key] }, ttl: 3600)
        end

        # Auto-approve is the one setting that hands the agent
        # permissions with nobody around. Worth a reminder right in the menu.
        def warning
          return nil unless @config.get("answers.auto_approve_permissions", false)

          "⚠️ Auto-approve is on: the agent runs tools without asking.\n" \
            "Blocked commands still ask regardless."
        end
      end
    end
  end
end
