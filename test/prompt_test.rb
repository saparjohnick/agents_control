# frozen_string_literal: true

require "test_helper"
require "stringio"

module AgentsControl
  class PromptTest < Minitest::Test
    Keys = AgentsControl::Keys

    COMMANDS = {
      "/help" => "help",
      "/sessions" => "agent sessions",
      "/settings" => "settings",
      "/status" => "status",
      "/quit" => "quit"
    }.freeze

    def setup
      @out = StringIO.new
    end

    # ── plain input ──────────────────────────────────────────────────────

    def test_returns_the_typed_line
      assert_equal "hello", read("hello\r")
    end

    # A multi-byte character arrives as several bytes — it has to be
    # assembled whole, or the string comes apart into fragments.
    def test_multibyte_characters_survive
      assert_equal "тест", read("тест\r")
    end

    def test_backspace_deletes
      assert_equal "ab", read("abc\x7F\r")
    end

    def test_ctrl_u_clears_the_line
      assert_equal "new", read("old\x15new\r")
    end

    def test_ctrl_d_on_empty_line_ends_input
      assert_nil read("\x04")
    end

    def test_ctrl_c_interrupts
      assert_raises(Interrupt) { read("something\x03") }
    end

    def test_closed_input_ends_the_session
      assert_nil read("")
    end

    # ── command list ─────────────────────────────────────────────────────

    def test_arrow_down_moves_the_selection_and_enter_picks_it
      # "/" → list, ↓ moves to the second command, Enter fills it in.
      assert_equal "/sessions", read("/", "\e[B", "\r", "\r").strip
    end

    def test_arrow_up_wraps_to_the_last_command
      assert_equal "/quit", read("/", "\e[A", "\r", "\r").strip
    end

    def test_typing_narrows_the_list
      # "/se" leaves sessions and settings; the second one is settings.
      assert_equal "/settings", read("/se", "\e[B", "\r", "\r").strip
    end

    def test_enter_appends_a_space_for_arguments
      assert_equal "/settings ", read("/settings\r\r")
    end

    def test_tab_picks_the_selection_too
      assert_equal "/sessions", read("/", "\e[B", "\t", "\r").strip
    end

    def test_escape_closes_the_list
      # After Esc, the first Enter submits the line rather than picking an item.
      assert_equal "/", read("/", "\e", "\r")
    end

    # Arrows serve the list only while it's open.
    def test_arrows_walk_history_when_no_list_is_shown
      prompt = build(Keys.new("first\r"))
      prompt.read("> ")

      assert_equal "first", continue(prompt, "\e[A", "\r")
    end

    def test_list_hides_once_arguments_begin
      # A space means an argument follows: the list would only get in the way there.
      assert_equal "/run 1", read("/run 1\r")
    end

    def test_unknown_prefix_shows_nothing_and_enter_submits
      assert_equal "/nomatch", read("/nomatch\r")
    end

    # ── rendering ─────────────────────────────────────────────────────────

    def test_selected_item_is_highlighted
      read("/\r\r")

      assert_includes @out.string, "\e[7m"
    end

    def test_descriptions_are_shown_next_to_commands
      read("/\r\r")

      assert_includes @out.string, "agent sessions"
    end

    def test_long_lists_are_windowed
      many = (1..30).to_h { |i| ["/cmd#{i}", "description"] }
      prompt = build(Keys.new("/\r\r"), commands: many)
      prompt.read("> ")

      shown = @out.string.scan(%r{/cmd\d+}).uniq.size

      assert_operator shown, :<=, Prompt::WINDOW
    end

    private

    # Every argument is a separate call.
    def read(*presses) = build(Keys.new(*presses)).read("> ")

    def continue(prompt, *presses)
      prompt.instance_variable_set(:@in, Keys.new(*presses))
      prompt.read("> ")
    end

    def build(keys, commands: COMMANDS)
      Prompt.new(
        input: keys,
        output: @out,
        completer: ->(word) { commands.keys.select { |name| name.start_with?(word) } },
        describer: ->(name) { commands[name] }
      )
    end
  end
end
