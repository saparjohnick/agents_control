# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  class ConfigTest < Minitest::Test
    def test_defaults_are_available_without_a_file
      config = Config.new

      assert_equal "haiku", config.get("anchors.model")
    end

    # Answering "continue" on the user's behalf is safe; granting a tool
    # is not. The settings are deliberately separate: merged into one,
    # they'd produce an agent that approves itself everything while
    # nobody is watching.
    def test_auto_continue_is_on_but_auto_approve_is_off
      config = Config.new

      assert config.get("answers.auto_continue")
      refute config.get("answers.auto_approve_permissions")
    end

    def test_chat_allowlist_starts_empty_so_bot_answers_nobody
      assert_empty Config.new.get("telegram.allowed_chat_ids")
    end

    # The braces are required: without them Ruby parses `k => v` as keyword arguments.
    def test_user_values_override_defaults_without_dropping_the_rest
      config = Config.new({ "anchors" => { "model" => "opus" } })

      assert_equal "opus", config.get("anchors.model")
      assert_equal ["07:00", "12:00", "17:00"], config.get("anchors.schedule")
    end

    def test_accepts_symbol_keys
      config = Config.new({ anchors: { model: "sonnet" } })

      assert_equal "sonnet", config.get("anchors.model")
    end

    def test_missing_key_returns_given_default
      assert_equal :fallback, Config.new.get("nothing.here", :fallback)
    end

    def test_set_creates_missing_branches
      config = Config.new.set("hooks.port", 47_123)

      assert_equal 47_123, config.get("hooks.port")
    end

    # Hash#merge only copies the top level — nested branches must be
    # independent copies, not objects shared with DEFAULTS.
    def test_instances_do_not_share_nested_state
      Config.new.set("telegram.allowed_chat_ids", [42])

      assert_empty Config.new.get("telegram.allowed_chat_ids")
      assert_empty Config::DEFAULTS["telegram"]["allowed_chat_ids"]
    end

    def test_mutating_a_returned_array_does_not_touch_defaults
      Config.new.get("answers.never_auto_approve") << "something custom"

      assert_equal 5, Config.new.get("answers.never_auto_approve").size
    end

    def test_saved_file_is_not_world_readable
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "config.yml")
        Config.new({}, path: path).set("telegram.allowed_chat_ids", [42]).save

        assert_equal "600", format("%o", File.stat(path).mode & 0o777)
        assert_equal [42], Config.load(path).get("telegram.allowed_chat_ids")
      end
    end

    # A broken config must not keep the daemon from starting.
    def test_broken_yaml_falls_back_to_defaults
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yml")
        File.write(path, "anchors: [unclosed\n")

        assert_equal "haiku", Config.load(path).get("anchors.model")
      end
    end
  end
end
