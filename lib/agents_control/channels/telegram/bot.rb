# frozen_string_literal: true

module AgentsControl
  module Channels
    module Telegram
      # The long-polling loop.
      #
      # Webhooks are deliberately not used: they need a public address
      # and a certificate. Long polling works behind NAT, from a coffee
      # shop, and with the laptop lid closed — everywhere this tool
      # actually lives.
      class Bot
        OFFSET_KEY = "telegram:offset"

        # Pause after a network failure: grows toward a ceiling so a
        # closed laptop doesn't hammer reconnects all night.
        BACKOFF = [1, 2, 5, 10, 30, 60].freeze

        def initialize(api:, router:, store:, config:, logger: $stdout)
          @api = api
          @router = router
          @store = store
          @config = config
          @logger = logger
          @running = false
        end

        # Polling runs on its own thread while the main one waits for a
        # stop signal: otherwise Ctrl-C has no effect while a long poll
        # is hanging, and launchd gets to send SIGKILL first. Kept
        # separate from wait so an interactive console can hold its own
        # input loop while the bot runs alongside.
        def start
          @running = true
          @stopped = Thread::Queue.new
          @poller = Thread.new { poll_loop }

          self
        end

        # Wait for a stop. Returns false if the reason was a second
        # instance on the same token.
        def wait
          reason = @stopped.pop

          @running = false
          @poller&.kill
          log(reason) if reason.is_a?(String)

          reason != :conflict
        end

        def run
          start
          trap_signals
          log("bot started, listening for updates")
          wait
        end

        def stop = @stopped&.push(nil)

        def running? = @running

        private

        def poll_loop
          failures = 0

          while @running
            begin
              poll_once
              failures = 0
            rescue Api::Conflict => e
              # Another process is reading updates — looping further is
              # pointless, exit with a clear explanation.
              log("stopping: #{e.message}. Is another agents_control running?")
              @stopped.push(:conflict)
              return
            rescue Api::TooManyRequests => e
              pause(e.retry_after.positive? ? e.retry_after : 5)
            rescue Api::Unavailable => e
              failures += 1
              log("network unavailable (#{e.message}), retrying in #{backoff(failures)}s")
              pause(backoff(failures))
            rescue Api::Error => e
              failures += 1
              log("API error: #{e.message}")
              pause(backoff(failures))
            end
          end
        end

        def poll_once
          updates = @api.get_updates(offset: offset, timeout: @config.get("telegram.poll_timeout", 30))

          updates.each do |update|
            handle(update)
            self.offset = update["update_id"] + 1
          end
        end

        # The offset advances even after a failed handling attempt: not
        # advancing it would mean replaying the same message forever.
        # Network errors don't reach here — they bubble up out of
        # get_updates before the loop.
        def handle(update)
          @router.handle(update)
        rescue Api::Unavailable
          raise
        rescue StandardError => e
          log("failed to handle update #{update['update_id']}: #{e.class}: #{e.message}")
        end

        def offset = @store.get(OFFSET_KEY)

        # The offset outlives buttons: it has to survive both a restart
        # and an overnight idle period, or the bot would replay old commands.
        def offset=(value)
          @store.put(value, ttl: 86_400 * 30, key: OFFSET_KEY)
        end

        def backoff(failures) = BACKOFF[[failures - 1, BACKOFF.size - 1].min]

        # Sleep in short slices so Ctrl-C doesn't have to wait out the full pause.
        # Not named wait — that's the name of the public stop-waiting method.
        def pause(seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds

          while @running && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            sleep(0.2)
          end
        end

        # A signal handler can safely do almost nothing — Queue#push is
        # one of the few things that's actually safe there.
        def trap_signals
          %w[INT TERM].each do |signal|
            Signal.trap(signal) { @stopped.push("received signal #{signal}, stopping") }
          end
        end

        def log(message) = @logger.puts("[#{Time.now.strftime('%H:%M:%S')}] #{message}")
      end
    end
  end
end
