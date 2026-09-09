# frozen_string_literal: true

require "thor"
require "open3"

module AgentsControl
  class CLI < Thor
    def self.exit_on_failure? = true

    # With no arguments the console opens: the tool's working state is
    # to live in a tab, not run once and exit.
    default_task :console

    desc "console", "Interactive console (default)"
    long_desc <<~TEXT
      Brings up the daemon and stays in the tab. Commands inside start
      with a slash, same as the bot's: /sessions, /tabs, /away, /settings, /doctor.
    TEXT
    def console = Console.new(config: config, store: store, secrets: secrets).run

    desc "sessions", "Show agent sessions"
    long_desc <<~TEXT
      By default prints only sessions with a confirmed live agent.
      Confirmation comes from the process tree, not the tab title: the
      title stays up after the agent exits and lies.

      With --all, prints every terminal tab.
    TEXT
    option :all, type: :boolean, default: false, aliases: "-a",
                 desc: "All tabs, not just agents"
    def sessions
      registry = Registry.new
      list = options[:all] ? registry.sessions : registry.agents

      if list.empty?
        say(options[:all] ? "No tabs found." : "No live agent sessions.", :yellow)
        say("Available backends: #{backend_names(registry)}", :white)
        return
      end

      print_table_of(list)
      say("")
      say("Total: #{list.size} · backends: #{backend_names(registry)}", :white)
    end

    desc "setup", "Set up the Telegram bot"
    long_desc <<~TEXT
      Asks for a token from @BotFather, verifies it, and waits for you
      to send the bot /start — to learn your chat_id and add it to the
      allowed list. While that list is empty, the bot answers nobody.

      The token is entered without echo and saved to the Keychain or
      libsecret. It's deliberately never accepted as a command-line
      argument: it would leak into `ps` and shell history.

      Finally, offers to set a passphrase for destructive commands
      (rm -rf ~, mkfs, dd to a device, a fork bomb) arriving from
      Telegram. Optional — without one they ask for a tap on a button
      instead.
    TEXT
    def setup
      token = ask_token
      return if token.nil? || !valid_shape?(token)

      api = Api.new(token)
      me = verify(api)
      return unless me

      secrets.set(:telegram_token, token)
      say("Token saved: #{secrets.target.name}", :green)
      publish_commands(api)

      return unless capture_chat_id(api, me)

      offer_passphrase
    end

    desc "daemon", "Run the daemon: agent hooks plus Telegram"
    long_desc <<~TEXT
      Listens to Telegram and receives events from agents. Stops with Ctrl-C.

      While "present" mode is on, agent questions are only mirrored to
      Telegram and stay in the terminal. The /away command in the bot
      switches to interception: then a question waits for a reply from your phone.
    TEXT
    def daemon = Daemon.new(config: config, store: store, secrets: secrets).run

    desc "hooks SUBCOMMAND", "Connect or disconnect agent hooks (install/uninstall/status)"
    def hooks(subcommand = "status")
      case subcommand
      when "install" then hooks_install
      when "uninstall" then hooks_uninstall
      when "status" then hooks_status
      else say("I don't know the subcommand #{subcommand}. Try install, uninstall, status.", :red)
      end
    end

    desc "stop", "Stop a running daemon"
    long_desc <<~TEXT
      Finds the process holding the hooks port and asks it to exit.
      Useful when an instance was left running somewhere and a new one won't start.
    TEXT
    def stop
      port = config.get("hooks.port", Daemon::DEFAULT_PORT).to_i
      # argv array, not a shell string: no reason to trust a shell to
      # parse a port number pulled from config.
      out, = Open3.capture3("lsof", "-nP", "-iTCP:#{port}", "-sTCP:LISTEN", "-t")
      pids = out.split
      return say("Nothing is running.", :yellow) if pids.empty?

      pids.each do |pid|
        Process.kill("TERM", pid.to_i)
        say("Stopped #{pid}", :green)
      rescue Errno::ESRCH, Errno::EPERM => e
        say("Couldn't stop #{pid}: #{e.message}", :red)
      end
    end

    desc "doctor", "Check that everything is in place"
    long_desc <<~TEXT
      Checks the environment the daemon will actually get, not the one
      you're sitting in right now: an interactive shell lies about
      versions and paths.
    TEXT
    def doctor
      checks = Doctor.new(config: config, secrets: secrets).run

      checks.each do |check|
        colour = { ok: :green, warn: :yellow, fail: :red }[check.status]
        say("#{check.icon} #{check.name.ljust(22)} #{check.detail}", colour)
        say("  └ #{check.fix}", :white) if check.fix
      end

      broken = checks.count(&:failed?)
      say("")
      say(broken.zero? ? "Everything checks out." : "Not okay: #{broken}",
          broken.zero? ? :green : :red)
    end

    desc "service SUBCOMMAND", "Autostart the daemon (install/uninstall/status)"
    def service(subcommand = "status")
      unit = Service.for_platform

      case subcommand
      when "install"
        say("Installed #{unit.install}", :green)
        say("Ruby: #{unit.ruby}", :white)
        say("Log: #{unit.log_path}", :white)
      when "uninstall" then unit.uninstall && say("Autostart removed", :green)
      else say(unit.installed? ? "Autostart configured: #{unit.path}" : "Autostart not configured")
      end
    end

    desc "passphrase SUBCOMMAND", "Passphrase for destructive commands (set/clear/status)"
    long_desc <<~TEXT
      A handful of commands are held back when they arrive from
      Telegram — a recursive force delete aimed at / or $HOME, a fork
      bomb, mkfs, dd to a raw device. Without a passphrase they come
      back as a confirmation button. With one, they come back asking
      for it, so an unlocked phone in someone else's hand can't tap
      its way past them.

      Entered without echo and stored derived (PBKDF2) in the Keychain
      or libsecret. Deliberately never a command-line argument: it
      would leak into `ps` and shell history.
    TEXT
    def passphrase(subcommand = "status")
      store = Passphrase.new(secrets: secrets)

      case subcommand
      when "set" then set_passphrase(store)
      when "clear" then clear_passphrase(store)
      when "status" then say(store.configured? ? "Passphrase is set." : "No passphrase — a button is used instead.")
      else say("Usage: agents_control passphrase set|clear|status", :yellow)
      end
    end

    desc "version", "Version"
    def version = say(AgentsControl::VERSION)

    private

    # Offered at the end of setup rather than left to be found later:
    # finishing setup is the moment the bot can start typing into this
    # machine, and the only moment its owner is guaranteed to be
    # reading. Skippable — a setup that can't be finished without
    # inventing a passphrase on the spot is a setup people abandon.
    def offer_passphrase
      return unless $stdin.tty?

      store = Passphrase.new(secrets: secrets)
      return say("A passphrase is already set. Change it with: agents_control passphrase set") if store.configured?

      say("")
      say("Optional: a passphrase for destructive commands", :yellow)
      say("")
      say("A few commands are held back when they arrive from Telegram —")
      say("`rm -rf ~`, `mkfs`, `dd` writing to a device, a fork bomb. Set a")
      say("passphrase and you'll be asked to type it before one of those is")
      say("sent; leave this blank and they ask for a tap on a button instead.")
      say("")
      say("The difference shows up when it isn't you holding the phone: a")
      say("button taps just as easily for whoever picked it up. Typing a")
      say("passphrase doesn't.")
      say("")
      say("Blank to skip — you can set one any time with:", :white)
      say("  agents_control passphrase set", :white)
      say("")

      set_passphrase(store, skippable: true)
    end

    def set_passphrase(store, skippable: false)
      value = ask_passphrase("Passphrase: ")
      return skipped(skippable) if value.empty?

      return say("They don't match — left unchanged.", :yellow) unless value == ask_passphrase("Again: ")

      store.set(value)
      say("Passphrase saved: #{secrets.target.name}", :green)
    rescue Passphrase::TooShort => e
      say("#{e.message.capitalize} — left unchanged.", :yellow)
    rescue Passphrase::NotSaved, AgentsControl::Error => e
      say("Couldn't save it: #{e.message}", :red)
      say("Check `agents_control doctor` — the secret store may be locked or missing.", :white)
    end

    def skipped(skippable)
      return say("Nothing entered — left unchanged.", :yellow) unless skippable

      say("Skipped — destructive commands will ask for a tap.", :white)
    end

    def clear_passphrase(store)
      return say("There was no passphrase set.", :yellow) unless store.configured?

      store.clear
      say("Passphrase removed — destructive commands go back to a confirmation button.", :green)
    end

    def ask_passphrase(label)
      return $stdin.gets.to_s.chomp unless $stdin.tty?

      $stderr.print(label)
      # Same class of failures as the token prompt: ENOTTY, ENODEV, ENXIO.
      $stdin.noecho(&:gets).to_s.chomp
    rescue SystemCallError, IOError
      ""
    ensure
      $stderr.puts if $stdin.tty?
    end

    Api = Channels::Telegram::Api
    Router = Channels::Telegram::Router
    Bot = Channels::Telegram::Bot

    def config = @config ||= Config.load

    def store = @store ||= Store.new

    def secrets = @secrets ||= Secrets.new

    def agents = [Agents::ClaudeCode.new]

    # Connecting hooks as a separate command usually isn't necessary —
    # the daemon does it itself on start. The command exists for
    # inspecting and fixing things by hand.
    def hooks_install
      url = "http://127.0.0.1:#{config.get('hooks.port', Daemon::DEFAULT_PORT)}"
      secret = secrets.get(:hook_secret) || SecureRandom.hex(16)
      secrets.set(:hook_secret, secret)

      agents.each do |agent|
        agent.install!(url, secret: secret)
        say("#{agent.key}: connected on #{url}", :green)
      rescue StandardError => e
        say("#{agent.key}: #{e.message}", :red)
      end
    end

    def hooks_uninstall
      agents.each do |agent|
        agent.uninstall!
        say("#{agent.key}: disconnected", :green)
      rescue StandardError => e
        say("#{agent.key}: #{e.message}", :red)
      end
    end

    def hooks_status
      agents.each do |agent|
        state = agent.installed? ? "connected" : "not connected"
        say("#{agent.key}: hooks #{state}")
      rescue StandardError => e
        say("#{agent.key}: #{e.message}", :red)
      end
    end

    # The token is read only from the terminal or stdin — deliberately
    # never accepted as a command-line flag, or it would leak into `ps`
    # and shell history.
    def ask_token
      token = $stdin.tty? ? ask_token_interactively : $stdin.gets.to_s.strip

      return nil if token.empty? && warn_empty_token

      token
    end

    def ask_token_interactively
      $stderr.print("Token from @BotFather: ")
      # Different devices fail differently: ENOTTY, ENODEV, ENXIO.
      # Catching the whole class of system errors, not individual codes.
      $stdin.noecho(&:gets).to_s.strip
    rescue SystemCallError, IOError
      ""
    ensure
      $stderr.puts
    end

    def warn_empty_token
      say("No token received.", :yellow)
      say("Enter it in the terminal, pipe it via stdin, or set " \
          "AGENTS_CONTROL_TELEGRAM_TOKEN.", :white)
      true
    end

    # A token from BotFather looks like `<digits>:<letters-digits-dashes>`.
    # The shape is checked before touching the network: unprintable
    # characters would land straight in the URL and fail the request
    # with a cryptic address-parsing error.
    TOKEN_SHAPE = /\A\d+:[A-Za-z0-9_-]{30,}\z/

    def verify(api)
      me = api.get_me
      say("Bot: @#{me['username']}", :green)
      me
    rescue Channels::Telegram::Api::Error => e
      say("Token was rejected: #{e.message}", :red)
      nil
    end

    # Without this, the bot's command menu only appeared after the first
    # daemon run (agents_control / agents_control daemon) — right after
    # setup the bot would already answer, but the command list wouldn't
    # be in Telegram's UI yet.
    def publish_commands(api)
      api.set_my_commands(Channels::Telegram::Router::COMMANDS)
    rescue Channels::Telegram::Api::Error
      nil
    end

    def valid_shape?(token)
      return true if token.match?(TOKEN_SHAPE)

      say("This doesn't look like a BotFather token.", :red)
      say("Expecting something like 123456789:AA... — copy the whole string.", :white)
      false
    end

    # chat_id is learned without asking: the user writes to the bot, and
    # we read who from. This rules out a typo in a long number.
    def capture_chat_id(api, me)
      say("")
      say("Now message the bot @#{me['username']} with /start", :yellow)
      say("Waiting up to 120 seconds…")

      chat = wait_for_message(api)
      return say("Timed out. Run setup again.", :red) unless chat

      allow(chat)
      true
    end

    def wait_for_message(api, seconds: 120)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      offset = nil

      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        updates = api.get_updates(offset: offset, timeout: 20)
        found = updates.find { |update| update.dig("message", "chat", "id") }

        return found["message"]["chat"] if found

        offset = updates.last["update_id"] + 1 unless updates.empty?
      end

      nil
    rescue Channels::Telegram::Api::Error => e
      say("Error while waiting: #{e.message}", :red)
      nil
    end

    def allow(chat)
      allowed = (config.get("telegram.allowed_chat_ids", []) + [chat["id"]]).uniq
      config.set("telegram.allowed_chat_ids", allowed).save

      name = [chat["first_name"], chat["username"] && "@#{chat['username']}"].compact.join(" ")
      say("Done. Chat allowed: #{chat['id']} #{name}".strip, :green)
      say("Run: agents_control bot")
    end

    def backend_names(registry)
      names = registry.available_backends.map(&:name)
      names.empty? ? "none" : names.join(", ")
    end

    def print_table_of(list)
      rows = list.map { |session| row_for(session) }
      widths = column_widths(rows)

      rows.each do |cells|
        say(cells.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join("  ").rstrip)
      end
    end

    def row_for(session)
      [
        state_marker(session),
        session.agent ? session.agent.to_s : (session.foreground_command || "—"),
        session.label,
        location(session),
        session.id
      ]
    end

    # State is encoded as an icon so the list reads at a glance, not
    # column by column.
    def state_marker(session)
      return "⏳" if session.processing?
      return "🖥" if session.terminalless?
      return "▸" if session.at_shell_prompt?

      "·"
    end

    # For a tabless session, printing a tty is meaningless — there isn't one.
    def location(session)
      return "vscode" if session.terminalless?

      session.tty.to_s.sub(%r{\A/dev/}, "")
    end

    def column_widths(rows)
      count = rows.map(&:size).max.to_i
      (0...count).map { |i| rows.map { |cells| cells[i].to_s.length }.max }
    end
  end
end
