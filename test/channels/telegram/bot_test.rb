# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  module Channels
    module Telegram
      class BotTest < Minitest::Test
        # A client that hands back prepared batches of updates, then goes quiet.
        class ScriptedApi
          attr_reader :offsets

          def initialize(*batches, error: nil)
            @batches = batches
            @error = error
            @offsets = []
          end

          # The real Api has this, and the poller's error path calls it.
          def redact(text) = text.to_s

          def get_updates(offset: nil, timeout: 30)
            @offsets << offset
            raise @error if @error

            batch = @batches.shift
            return batch if batch

            sleep(0.05)
            []
          end
        end

        class CountingRouter
          attr_reader :handled

          def initialize(raise_on: nil)
            @handled = []
            @raise_on = raise_on
          end

          def handle(update)
            raise "handler fell over" if @raise_on == update["update_id"]

            @handled << update
          end
        end

        def setup
          @dir = Dir.mktmpdir
          @store = Store.new(path: File.join(@dir, "store.json"))
          @config = Config.new
          @log = StringIO.new
        end

        def teardown = FileUtils.remove_entry(@dir)

        def test_handles_updates_and_advances_the_offset
          api = ScriptedApi.new([update(10), update(11)])
          router = CountingRouter.new
          bot = build(api, router)

          bot.start
          wait_until { router.handled.size == 2 }
          bot.stop
          bot.wait

          assert_equal [10, 11], router.handled.map { |u| u["update_id"] }
          assert_equal 12, @store.get(Bot::OFFSET_KEY)
        end

        # A broken update is skipped, not retried forever: otherwise one
        # poison message would wedge the bot permanently.
        def test_a_broken_update_does_not_wedge_the_queue
          api = ScriptedApi.new([update(10), update(11), update(12)])
          router = CountingRouter.new(raise_on: 11)
          bot = build(api, router)

          bot.start
          wait_until { router.handled.size == 2 }
          bot.stop
          bot.wait

          assert_equal [10, 12], router.handled.map { |u| u["update_id"] }
          assert_equal 13, @store.get(Bot::OFFSET_KEY)
          assert_includes @log.string, "failed to handle update 11"
        end

        # The private pause helper must not be named wait — it would
        # silently shadow the public stop-waiting method.
        def test_wait_is_public_and_returns_after_stop
          bot = build(ScriptedApi.new, CountingRouter.new)

          assert_includes bot.public_methods(false), :wait

          bot.start
          bot.stop

          assert bot.wait
          refute_predicate bot, :running?
        end

        # One token, one reader. Looping further is pointless.
        def test_conflict_stops_the_bot_and_reports_why
          api = ScriptedApi.new(error: Api::Conflict.new("already being read by another process"))
          bot = build(api, CountingRouter.new)

          bot.start

          refute bot.wait, "a conflict is not a normal stop"
          assert_includes @log.string, "Is another agents_control running?"
        end

        def test_network_failure_is_retried_not_fatal
          api = ScriptedApi.new(error: Api::Unavailable.new("network dropped"))
          bot = build(api, CountingRouter.new)

          bot.start
          wait_until { @log.string.include?("network unavailable") }
          bot.stop
          bot.wait

          assert_includes @log.string, "retrying in"
        end

        # A poller that dies takes Telegram with it while the daemon
        # keeps its port and its hooks, so from outside it looks
        # perfectly healthy. This happened: Errno::EADDRNOTAVAIL, which
        # a VPN reconnecting produces, was not on the recognised list
        # and killed the thread. Messages stopped arriving for days.
        def test_an_unlisted_system_error_does_not_kill_the_poller
          api = ScriptedApi.new(error: Errno::EADDRNOTAVAIL.new("api.telegram.org:443"))
          bot = build(api, CountingRouter.new)

          bot.start
          wait_until { @log.string.include?("retrying in") }

          assert_predicate bot, :polling?, "the poller died instead of retrying"

          bot.stop
          bot.wait

          assert_includes @log.string, "retrying in"
        end

        # Anything at all, not just the errors anyone thought of.
        def test_an_unexpected_error_does_not_kill_the_poller_either
          api = ScriptedApi.new(error: RuntimeError.new("something nobody predicted"))
          bot = build(api, CountingRouter.new)

          bot.start
          wait_until { @log.string.include?("unexpected RuntimeError") }
          bot.stop
          bot.wait

          assert_includes @log.string, "something nobody predicted"
        end

        # Something outside the process has to be able to tell a bot
        # that is listening from one that died hours ago — the daemon's
        # port answers the same either way.
        def test_a_successful_poll_leaves_a_heartbeat
          bot = build(ScriptedApi.new([update(1)]), CountingRouter.new)

          bot.start
          wait_until { @store.get(Bot::HEARTBEAT_KEY) }
          bot.stop
          bot.wait

          assert_in_delta Time.now.to_i, @store.get(Bot::HEARTBEAT_KEY).to_i, 5
        end

        # A store that cannot be written is not a reason to stop reading
        # Telegram, which is the actual job.
        def test_a_failing_store_does_not_stop_the_poller
          bot = Bot.new(api: ScriptedApi.new([update(1)]), router: CountingRouter.new,
                        store: BrokenStore.new, config: @config, logger: @log)

          bot.start
          wait_until { @log.string.include?("heartbeat") }

          assert_predicate bot, :polling?

          bot.stop
          bot.wait
        end

        class BrokenStore
          def get(_key) = nil
          def put(*, **) = raise(Errno::EACCES, "store.json")
        end

        private

        def build(api, router)
          Bot.new(api: api, router: router, store: @store, config: @config, logger: @log)
        end

        def update(id) = { "update_id" => id, "message" => { "text" => "hello" } }

        def wait_until(seconds = 3)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          sleep(0.01) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        end
      end
    end
  end
end
