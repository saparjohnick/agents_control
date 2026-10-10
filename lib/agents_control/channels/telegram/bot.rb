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

        # Pause after a network failure. The ceiling is low on purpose:
        # nothing tells us the network is back, so the pause is how long
        # the bot stays deaf after a switch between networks — and a
        # minute of that read as "it froze". A closed laptop is asleep
        # and doesn't retry at all, so a short ceiling costs nothing there.
        BACKOFF = [1, 2, 5, 10].freeze

        # A successful poll leaves a timestamp behind, so something
        # outside this process can tell a bot that is listening from one
        # that stopped hours ago. `polling?` answers that in-process, and
        # doctor runs as a separate command — the daemon's port reports
        # only that it is up, which a deaf daemon is too.
        HEARTBEAT_KEY = "telegram:last_poll"

        # A healthy poll returns at least every telegram.poll_timeout
        # (30s), and immediately when something arrives. Writing on each
        # one would rewrite the store several times a second under
        # traffic, for a reading nobody needs that finely.
        HEARTBEAT_EVERY = 15

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

        # Whether the Telegram side is actually alive. The daemon holds
        # its port and answers hooks whether or not this thread is
        # running, so without asking there is no way to tell a bot that
        # is listening from one that died quietly hours ago.
        def polling? = @poller&.alive? || false

        def running? = @running

        private

        def poll_loop
          failures = 0

          while @running
            begin
              poll_once
              heartbeat
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
            rescue StandardError => e
              # A backstop, not a place to add expected errors above it.
              # Whatever it is, the bot going deaf until someone notices
              # is worse than retrying: the daemon keeps its port and its
              # hooks either way, so a dead poller looks exactly like a
              # healthy one from outside.
              failures += 1
              log("unexpected #{e.class}: #{redacted(e)}, retrying in #{backoff(failures)}s")
              pause(backoff(failures))
            end
          end
        end

        # The message may carry the token, so it is only printed once
        # redaction has actually succeeded — and redaction failing must
        # not take the handler down with it, which is how the backstop
        # above managed to kill the very thread it exists to keep alive.
        def redacted(error)
          @api.redact(error.message)
        rescue StandardError
          "(message withheld — could not redact)"
        end

        # Best-effort by design: a store that can't be written is not a
        # reason to stop reading Telegram, which is the whole job.
        def heartbeat
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return if @last_heartbeat && now - @last_heartbeat < HEARTBEAT_EVERY

          @last_heartbeat = now
          @store.put(Time.now.to_i, ttl: 86_400, key: HEARTBEAT_KEY)
        rescue StandardError => e
          log("couldn't record the poll heartbeat: #{e.class}")
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
