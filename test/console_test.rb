# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"

module AgentsControl
  class ConsoleTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @out = StringIO.new
      @config = Config.new({}, path: File.join(@dir, "config.yml"))
      @store = Store.new(path: File.join(@dir, "store.json"))
    end

    def teardown = FileUtils.remove_entry(@dir)

    # Without a token the daemon won't start, but the console must still
    # open: it's exactly where the token gets set.
    def test_opens_even_without_a_token
      output = run_console("/quit")

      assert_includes output, "agents_control"
      assert_includes output, "daemon isn't running"
    end

    def test_help_lists_every_command
      output = run_console("/help", "/quit")

      Console::COMMANDS.each_key { |name| assert_includes output, name }
    end

    def test_unknown_command_is_explained
      output = run_console("/somethingwrong", "/quit")

      assert_includes output, "I don't know the command"
    end

    # Typing a slash and hitting enter is more natural than remembering the word help.
    def test_bare_slash_shows_the_list
      assert_includes run_console("/", "/quit"), "/sessions"
    end

    # ── completions ─────────────────────────────────────────────────────────

    def test_slash_offers_every_command
      assert_equal Console::COMMANDS.keys.sort, complete("/").sort
    end

    def test_prefix_narrows_the_list
      assert_equal ["/settings"], complete("/se") - ["/sessions"]
      assert_includes complete("/se"), "/sessions"
    end

    # The slash can be skipped — completion finds the command anyway.
    def test_completion_works_without_the_slash
      assert_includes complete("doc"), "/doctor"
    end

    def test_unknown_prefix_offers_nothing
      assert_empty complete("/nomatch")
    end

    def test_settings_names_are_suggested_as_the_argument
      assert_includes complete("away", line: "/settings aw"), "away"
      assert_includes complete("", line: "/settings "), "auto_continue"
    end

    # "enabled" alone says nothing — for keys like that, the section is
    # suggested instead.
    def test_generic_setting_name_is_replaced_by_its_section
      names = complete("", line: "/settings ")

      assert_includes names, "anchors"
      refute_includes names, "enabled"
    end

    def test_section_name_toggles_the_setting
      run_console("/settings anchors", "/quit")

      assert Config.load(@config.path).get("anchors.enabled")
    end

    def test_away_offers_on_and_off
      assert_equal %w[on off], complete("", line: "/away ")
    end

    def test_hooks_offers_its_subcommands
      assert_equal %w[install uninstall], complete("", line: "/hooks ")
    end

    def test_command_without_arguments_offers_nothing
      assert_empty complete("", line: "/status ")
    end

    # The slash is optional: typing it every time gets tedious.
    def test_slash_is_optional
      assert_includes run_console("status", "/quit"), "Tabs:"
    end

    def test_away_toggles_and_persists
      run_console("/away", "/quit")

      assert Config.load(@config.path).get("answers.away")
    end

    def test_away_accepts_an_explicit_value
      run_console("/away off", "/quit")

      refute Config.load(@config.path).get("answers.away")
    end

    # After stepping away, it's easy to forget interception is off and
    # end up with no notifications exactly when they're needed. So the
    # mode is visible in the prompt.
    def test_prompt_shows_the_away_mode
      assert_includes run_console("/away", "/quit"), "🚶 > "
    end

    def test_settings_can_be_toggled_by_short_name
      run_console("/settings auto_continue", "/quit")

      refute Config.load(@config.path).get("answers.auto_continue")
    end

    def test_unknown_setting_is_reported
      assert_includes run_console("/settings nothing", "/quit"), "I don't know the setting"
    end

    # Showing "Rate-limit anchors" but accepting only the internal name
    # is a trap: a completion hint must not reject the exact string it just showed.
    def test_setting_can_be_named_the_way_it_is_displayed
      run_console("/settings Rate-limit anchors", "/quit")

      assert Config.load(@config.path).get("anchors.enabled")
    end

    def test_display_name_is_matched_regardless_of_case
      run_console('/settings auto-reply "continue"', "/quit")

      refute Config.load(@config.path).get("answers.auto_continue")
    end

    def test_settings_without_argument_shows_the_list
      assert_includes run_console("/settings", "/quit"), "Auto-approve tools"
    end

    # A failure in one command must not close the console.
    def test_a_failing_command_keeps_the_session_alive
      output = run_console("/hooks install", "/status", "/quit")

      assert_includes output, "Tabs:"
    end

    def test_quit_stops_the_daemon
      assert_includes run_console("/quit"), "Stopping"
    end

    def test_ctrl_d_ends_the_session
      # Empty input with no /quit — like a closed stdin.
      assert_includes run_console, "Stopping"
    end

    private

    def complete(word, line: nil)
      console = Console.new(config: @config, store: @store,
                            secrets: empty_secrets, output: @out)

      console.send(:complete, word, line: line || word)
    end

    def run_console(*lines)
      input = StringIO.new(lines.map { |l| "#{l}\n" }.join)

      with_stdin(input) do
        Console.new(config: @config, store: @store, secrets: empty_secrets, output: @out).run
      end

      @out.string
    end

    def empty_secrets
      Secrets.new(providers: [Secrets::Providers::File.new(path: File.join(@dir, "none.json"))])
    end

    def with_stdin(io)
      original = $stdin
      $stdin = io
      yield
    ensure
      $stdin = original
    end
  end
end
