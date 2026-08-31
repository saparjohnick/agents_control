# frozen_string_literal: true

require "test_helper"
require "stringio"

module AgentsControl
  class MenuTest < Minitest::Test
    Keys = AgentsControl::Keys

    def setup
      @out = StringIO.new
      @values = { "Mode" => "present", "Anchors" => "off", "Lines" => "80" }
    end

    def test_shows_the_title_and_every_row
      run_menu("\e")

      assert_includes @out.string, "⚙️ Settings"
      @values.each_key { |name| assert_includes @out.string, name }
    end

    def test_hint_explains_the_keys
      run_menu("\e")

      assert_includes @out.string, "↑↓"
      assert_includes @out.string, "Enter"
    end

    def test_enter_toggles_the_first_row_by_default
      toggled = run_menu("\r", "\e")

      assert_equal ["Mode"], toggled
    end

    def test_arrows_move_the_selection
      toggled = run_menu("\e[B", "\r", "\e")

      assert_equal ["Anchors"], toggled
    end

    def test_selection_wraps_around
      toggled = run_menu("\e[A", "\r", "\e")

      assert_equal ["Lines"], toggled
    end

    # After toggling, the screen must show the new value, not the old one.
    def test_rows_are_reread_after_a_change
      run_menu("\r", "\e")

      assert_includes @out.string, "Mode: away"
    end

    def test_selected_row_is_highlighted
      run_menu("\e")

      assert_includes @out.string, "\e[7m"
    end

    def test_escape_closes_the_menu
      toggled = run_menu("\e")

      assert_empty toggled
    end

    def test_q_closes_the_menu_too
      assert_empty run_menu("q")
    end

    def test_closed_input_closes_the_menu
      assert_empty run_menu("")
    end

    private

    # Returns the list of names that were toggled.
    def run_menu(*presses)
      toggled = []

      Menu.new(input: Keys.new(*presses), output: @out).run(
        title: "⚙️ Settings",
        rows: -> { @values.map { |name, value| "#{name}: #{value}" } }
      ) do |index|
        name = @values.keys[index]
        toggled << name
        @values[name] = "away"
      end

      toggled
    end
  end
end
