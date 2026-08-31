# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  module Channels
    module Telegram
      class SettingsMenuTest < Minitest::Test
        def setup
          @dir = Dir.mktmpdir
          @store = Store.new(path: File.join(@dir, "store.json"))
          @config = Config.new({}, path: File.join(@dir, "config.yml"))
          @menu = SettingsMenu.new(store: @store, config: @config)
        end

        def teardown = FileUtils.remove_entry(@dir)

        def test_shows_current_values
          text = @menu.text

          assert_includes text, "🪑 present"
          assert_includes text, "Auto-reply \"continue\": ✅ on"
          assert_includes text, "Auto-approve tools: ❌ off"
        end

        def test_every_button_fits_the_callback_limit
          buttons = @menu.markup[:inline_keyboard].flatten

          refute_empty buttons
          buttons.each { |b| assert_operator b[:callback_data].bytesize, :<=, 64 }
        end

        def test_toggle_flips_and_persists
          key = press("answers.away")

          assert @config.get("answers.away")
          assert_equal true, Config.load(@config.path).get("answers.away")
          assert_includes key, "🚶 away"
        end

        def test_toggle_flips_back
          press("answers.away")
          press("answers.away")

          refute @config.get("answers.away")
        end

        # On a phone, cycling through a step is faster than typing a number.
        def test_numeric_setting_cycles_through_values
          assert_equal 900, @config.get("answers.reply_timeout")

          press("answers.reply_timeout")
          assert_equal 1800, @config.get("answers.reply_timeout")

          press("answers.reply_timeout")
          assert_equal 3600, @config.get("answers.reply_timeout")

          press("answers.reply_timeout")
          assert_equal 300, @config.get("answers.reply_timeout"), "should wrap around"
        end

        def test_unknown_setting_is_ignored
          assert_nil @menu.apply({ "key" => "no.such.thing" })
        end

        # The one setting that hands the agent permissions with nobody
        # around must be visible right in the menu.
        def test_auto_approve_shows_a_warning_when_on
          refute_includes @menu.text, "⚠️ Auto-approve is on"

          press("answers.auto_approve_permissions")

          assert_includes @menu.text, "⚠️ Auto-approve is on"
          assert_includes @menu.text, "Blocked commands still ask regardless"
        end

        private

        def press(key)
          @menu.apply({ "key" => key })
        end
      end
    end
  end
end
