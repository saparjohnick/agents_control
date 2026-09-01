# frozen_string_literal: true

require "net/http"
require "json"

module AgentsControl
  # Brings everything together: receiving hooks from agents and talking to Telegram.
  #
  # One process, because one Telegram token allows exactly one update
  # reader, and a thread waiting on a question's answer has to get that
  # answer from the same process that asked it.
  class Daemon
    # The port is fixed, not picked freely on every start: the address
    # is written into an agent's own settings and has to survive a
    # daemon restart, or every restart would leave hooks firing into nothing.
    DEFAULT_PORT = 47_653

    def initialize(config: nil, store: nil, secrets: nil, logger: $stdout)
      @config = config || Config.load
      @store = store || Store.new
      @secrets = secrets || Secrets.new
      @logger = logger

      # Without this, output buffers until the process exits. Under
      # launchd that means an empty log for a daemon that's actually
      # running — blind exactly when the log is what you'd reach for.
      @logger.sync = true if @logger.respond_to?(:sync=)
    end

    attr_reader :bot

    # Exposed: the console needs to show how many questions are
    # currently waiting for an answer.
    def pending = @pending ||= Pending.new

    # Bring everything up and return control immediately.
    #
    # Split from waiting for the sake of the interactive console: it
    # holds its own input loop while the daemon runs alongside. The
    # `daemon` command is this same start plus waiting.
    def start
      return false unless ready?

      start_hooks
      start_anchors
      start_screen_watcher
      start_rate_limit_watcher
      install_agents
      verify_hooks
      publish_commands
      start_bot

      log("hooks listening on #{server.url}, agents connected: #{installed_agents.size}")
      log("mode: #{away_label}")
      true
    rescue Hooks::Server::PortBusy => e
      fail_with(e.message)
    end

    def wait = @bot&.wait

    def stop
      @bot&.stop
      server&.stop
      @scheduler&.stop
      @screen_watcher&.stop
      @rate_limit_watcher&.stop
      remove_agents
    end

    def run
      return false unless start

      Signal.trap("INT") { @bot&.stop }
      Signal.trap("TERM") { @bot&.stop }
      wait
    ensure
      stop
    end

    def away_label
      @config.get("answers.away", false) ? "away — questions go to Telegram" : "present — notifications only"
    end

    def ready?
      return fail_with("Token not found. Enter /token or run agents_control setup") unless
        @secrets.get(:telegram_token)
      return fail_with("The allowed-chats list is empty. Run: agents_control setup") if chats.empty?

      true
    end

    private

    def chats = Array(@config.get("telegram.allowed_chat_ids", []))

    def port = @config.get("hooks.port", DEFAULT_PORT)

    def agents = @agents ||= [Agents::ClaudeCode.new]

    def installed_agents = agents.select(&:installed?)

    def server
      @server ||= Hooks::Server.new(port: port, secret: hook_secret, logger: @logger)
    end

    # The secret doesn't protect against another user on the same
    # machine — they can already read the settings file — it protects
    # against outside requests to the local port, including whatever a
    # page open in a browser might send.
    def hook_secret
      @hook_secret ||= @secrets.get(:hook_secret) || begin
        generated = SecureRandom.hex(16)
        @secrets.set(:hook_secret, generated)
        generated
      end
    end

    def start_hooks
      dispatcher = Dispatcher.new(
        agents: agents,
        channel: channel,
        config: @config,
        pending: pending,
        logger: @logger
      )

      server.start do |_path, payload|
        # Any event means a human was just working with the agent. This
        # is how the anchor scheduler knows whether a rate-limit window
        # is open — no separate polling needed.
        @store.put(Time.now.to_i, ttl: 86_400, key: Anchors::Scheduler::ACTIVITY_KEY)

        dispatcher.handle(payload)
      end
    end

    def start_anchors
      @scheduler = Anchors::Scheduler.new(
        config: @config, store: @store, logger: @logger
      ).start

      return unless @config.get("anchors.enabled", false)

      log("anchors enabled, next one at #{@scheduler.next_run_at&.strftime('%d.%m %H:%M') || 'never'}")
    end

    def channel
      @channel ||= Channels::Telegram::Channel.new(api: api, store: @store, config: @config,
                                                    registry: Registry.new)
    end

    def start_screen_watcher
      @screen_watcher = ScreenWatcher.new(
        registry: Registry.new, config: @config, store: @store, api: api, logger: @logger
      ).start
    end

    # Goes through the full Registry, like ScreenWatcher, but polls
    # noticeably less often (once a minute, not every 20 seconds) — a
    # limit doesn't hit every few seconds, and an AppleScript scan
    # (~0.9s) at that frequency costs less this way.
    def start_rate_limit_watcher
      @rate_limit_watcher = RateLimitWatcher.new(
        registry: Registry.new, config: @config, store: @store, api: api,
        interval: @config.get("terminal.rate_limit_poll_interval", 60), logger: @logger
      ).start
    end

    def api = @api ||= Channels::Telegram::Api.new(@secrets.get(:telegram_token))

    def install_agents
      @installed = true

      agents.each do |agent|
        # Headroom over the reply timeout: the hook has to outlive our
        # own timeout, not get cut off a second before it.
        agent.install!(server.url, secret: hook_secret,
                                   timeout: @config.get("answers.reply_timeout", 600) + 60)
      rescue StandardError => e
        log("couldn't connect #{agent.key}: #{e.message}")
      end
    end

    # Self-check: does an event from the agent actually reach us. The
    # entry in settings.json and the live server can drift apart — for
    # instance, if another agents_control is already running nearby with
    # a different secret.
    def verify_hooks
      settings = JSON.parse(File.read(Agents::ClaudeCode.settings_path))
      hook = settings.dig("hooks", "Stop", 0, "hooks", 0)
      return log("couldn't find our own hooks in settings — events won't arrive") unless hook

      code = probe_hook(hook)
      return if code == 200

      log("WARNING: the hook returned #{code}, agent events won't reach me.")
      log("This usually means another agents_control is running nearby — stop it.")
    rescue StandardError => e
      log("couldn't verify hooks: #{e.message}")
    end

    def probe_hook(hook)
      uri = URI(hook["url"])
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      hook.fetch("headers", {}).each { |key, value| request[key] = value }
      request.body = JSON.generate({ "hook_event_name" => "Ping" })

      Net::HTTP.start(uri.host, uri.port, read_timeout: 5) { |http| http.request(request) }.code.to_i
    end

    def publish_commands
      api.set_my_commands(Channels::Telegram::Router::COMMANDS)
    rescue Channels::Telegram::Api::Error => e
      log("couldn't update the command menu: #{e.message}")
    end

    # Hooks are removed on stop: otherwise the agent prints ECONNREFUSED
    # for every hook it has nowhere to reach. If the daemon crashes they
    # stay dangling; fixed with the hooks uninstall command.
    def remove_agents
      return unless @installed

      agents.each do |agent|
        agent.uninstall!
      rescue StandardError => e
        log("couldn't disconnect #{agent.key}: #{e.message}")
      end

      log("hooks disconnected")
    end

    def start_bot
      router = Channels::Telegram::Router.new(
        api: api, registry: Registry.new, store: @store,
        config: @config, pending: pending, logger: @logger
      )

      @bot = Channels::Telegram::Bot.new(api: api, router: router, store: @store,
                                         config: @config, logger: @logger).start
    end

    def fail_with(message)
      log(message)
      false
    end

    def log(message) = @logger.puts("[#{Time.now.strftime('%H:%M:%S')}] #{message}")
  end
end
