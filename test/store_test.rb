# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  class StoreTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @now = 1_000_000
      @store = build
    end

    def teardown = FileUtils.remove_entry(@dir)

    def test_stores_and_reads_back
      key = @store.put({ "action" => "focus" })

      assert_equal({ "action" => "focus" }, @store.get(key))
    end

    def test_generated_keys_fit_telegram_callback_limit
      # The Bot API allows 64 bytes for callback_data — the key has to be short.
      key = @store.put({ "action" => "focus" })

      assert_operator key.bytesize, :<=, 64
      assert_equal 8, key.length
    end

    def test_keys_are_unique
      keys = Array.new(50) { @store.put({ "n" => _1 }) }

      assert_equal 50, keys.uniq.size
    end

    # Exactly why take exists: Telegram redelivers the callback on a
    # dropped connection, and a finger can tap twice.
    def test_take_returns_value_only_once
      key = @store.put({ "action" => "close" })

      assert_equal({ "action" => "close" }, @store.take(key))
      assert_nil @store.take(key)
    end

    # An early return from the block would unwind past the file write,
    # and the button would fire again after a restart.
    def test_take_persists_removal_to_disk
      key = @store.put({ "action" => "close" })
      @store.take(key)

      assert_nil build.get(key)
    end

    def test_expired_entries_are_invisible
      key = @store.put({ "action" => "focus" }, ttl: 60)

      @now += 61

      assert_nil @store.get(key)
      assert_nil @store.take(key)
    end

    def test_survives_restart
      key = @store.put({ "action" => "focus" })

      assert_equal({ "action" => "focus" }, build.get(key))
    end

    # Losing pending questions is unfortunate, but failing to start at
    # all is worse — the agent would be left blocked with no way to answer.
    def test_broken_file_does_not_prevent_startup
      File.write(path, "{this is not json")

      assert_nil @store.get("whatever")
      assert @store.put({ "action" => "focus" })
    end

    def test_file_is_not_world_readable
      @store.put({ "action" => "focus" })

      assert_equal "600", format("%o", File.stat(path).mode & 0o777)
    end

    def test_explicit_key_overwrites
      @store.put(1, key: "offset")
      @store.put(2, key: "offset")

      assert_equal 2, @store.get("offset")
    end

    def test_all_skips_expired
      @store.put("alive", ttl: 600, key: "a")
      @store.put("dead", ttl: 10, key: "b")

      @now += 60

      assert_equal({ "a" => "alive" }, @store.all)
    end

    def test_prune_drops_expired_from_disk
      @store.put("dead", ttl: 10, key: "b")
      @now += 60
      @store.prune

      assert_empty JSON.parse(File.read(path))
    end

    # Two simultaneous presses must not both get the value.
    def test_concurrent_take_yields_one_winner
      key = @store.put({ "action" => "close" })

      results = Array.new(8) { Thread.new { @store.take(key) } }.map(&:value)

      assert_equal 1, results.compact.size
    end

    private

    def path = File.join(@dir, "store.json")

    def build = Store.new(path: path, clock: -> { @now })
  end
end
