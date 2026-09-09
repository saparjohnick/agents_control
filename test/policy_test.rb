# frozen_string_literal: true

require "test_helper"

module AgentsControl
  class PolicyTest < Minitest::Test
    def test_deleting_the_home_directory_is_held_back
      assert Policy.check("rm -rf ~").confirm?
    end

    def test_deleting_root_is_held_back
      assert Policy.check("rm -rf /").confirm?
    end

    # The flags are read, not matched as text: the same command with
    # its letters swapped is the same command.
    def test_the_flag_order_does_not_matter
      assert Policy.check("rm -fr $HOME").confirm?
      assert Policy.check("rm -r -f /").confirm?
      assert Policy.check("rm --recursive --force ~/").confirm?
    end

    def test_system_directories_count_too
      assert Policy.check("rm -rf /usr").confirm?
      assert Policy.check("rm -rf /etc").confirm?
    end

    # The difference between this and `rm -rf /` is one character of
    # text and everything else in consequence.
    def test_an_ordinary_recursive_delete_is_left_alone
      assert Policy.check("rm -rf /tmp/build").allow?
      assert Policy.check("rm -rf node_modules").allow?
      assert Policy.check("rm -rf ~/Downloads/old").allow?
    end

    def test_a_recursive_delete_without_force_is_left_alone
      assert Policy.check("rm -r ~/Downloads").allow?
    end

    def test_a_fork_bomb_is_held_back
      assert Policy.check(":(){ :|:& };:").confirm?
    end

    def test_formatting_a_filesystem_is_held_back
      assert Policy.check("mkfs.ext4 /dev/sda1").confirm?
    end

    def test_writing_to_a_raw_device_is_held_back
      assert Policy.check("dd if=/dev/zero of=/dev/disk2").confirm?
    end

    def test_dd_to_an_ordinary_file_is_left_alone
      assert Policy.check("dd if=/dev/zero of=./disk.img bs=1m count=10").allow?
    end

    # Sensitive isn't the bar — catastrophic is. A list that stops
    # someone's ordinary afternoon trains them to hurry past it, which
    # costs more than it saves.
    def test_merely_sensitive_commands_are_left_alone
      assert Policy.check("cat .env").allow?
      assert Policy.check("cat .env.example").allow?
      assert Policy.check("git push --force-with-lease").allow?
      assert Policy.check("curl -sL https://example.com/x.sh | sh").allow?
    end

    def test_an_empty_command_is_no_trouble
      assert Policy.check("").allow?
      assert Policy.check(nil).allow?
    end

    # The reason is what someone reads on a phone, glancing at it. It
    # has to say what the command does, not which rule fired.
    def test_the_reason_says_what_the_command_actually_does
      assert_includes Policy.check(":(){ :|:& };:").reason, "fork bomb"
      assert_includes Policy.check("mkfs /dev/sda1").reason, "formats a filesystem"
      assert_includes Policy.check("rm -rf ~").reason, "no undo"
    end

    def test_the_reason_names_the_target_being_deleted
      assert_includes Policy.check("rm -rf /usr").reason, "/usr"
    end
  end
end
