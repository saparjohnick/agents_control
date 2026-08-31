# frozen_string_literal: true

module AgentsControl
  # The interactive console.
  #
  # The tool is meant to live in a tab, not run once and exit: that's
  # its working state — it listens to Telegram and receives agent events
  # while it's open. Separate subcommands would be misleading here: after
  # `setup` it would look like everything's running, while in fact
  # nothing is polling Telegram, and messages pile up unread on its side.
  #
  # So running with no arguments opens the console itself, and the
  # commands inside it are the same as the bot's — with a slash.
  class Console
    COMMANDS = {
      "/help" => "list of commands",
      "/sessions" => "sessions with a live agent",
      "/tabs" => "all terminal tabs",
      "/status" => "what's happening right now",
      "/away" => "intercept agent questions (before stepping out)",
      "/settings" => "settings; /settings NAME — toggle",
      "/token" => "set the Telegram token",
      "/doctor" => "check that everything is in place",
      "/hooks" => "hook status; /hooks install|uninstall",
      "/quit" => "quit"
    }.freeze

    # Values worth suggesting as a second word.
    ARGUMENTS = {
      "/away" => %w[on off],
      "/hooks" => %w[install uninstall]
    }.freeze

    def initialize(config: nil, store: nil, secrets: nil, output: $stdout)
      @config = config || Config.load
      @store = store || Store.new
      @secrets = secrets || Secrets.new
      @out = output
      @out.sync = true if @out.respond_to?(:sync=)
    end

    def run
      banner
      start_daemon
      loop_commands
    ensure
      say("")
      say("Stopping…")
      @daemon&.stop
    end

    private

    def say(text = "") = @out.puts(text)

    def banner
      say("agents_control #{VERSION}")
      say("Type / for the command list, arrows to pick, Enter to fill in.\nQuit with /quit or Ctrl-D.")
      say("")
    end

    # The line is passed as an argument rather than read from the editor
    # internally: this lets completions be tested without a live terminal.
    def complete(word, line: word)
      command, rest = line.split(/\s+/, 2)

      rest.nil? ? complete_command(word) : complete_argument(command, word)
    end

    # The slash is filled in automatically: typing it every time isn't
    # required, and the list is shown in full either way.
    def complete_command(word)
      needle = word.start_with?("/") ? word : "/#{word}"

      COMMANDS.keys.select { |name| name.start_with?(needle) }
    end

    def complete_argument(command, word)
      values = case command
               when "/settings" then setting_names
               else ARGUMENTS.fetch(command, [])
               end

      values.select { |value| value.start_with?(word) }
    end

    # A short setting name for the completion hint.
    #
    # Usually the key's last word, but for `anchors.enabled` that
    # degenerates into a meaningless "enabled" — unclear what's actually
    # on. For cases like that, the section is used instead: "anchors" speaks for itself.
    GENERIC = %w[enabled].freeze

    def setting_names
      (Channels::Telegram::SettingsMenu::TOGGLES +
       Channels::Telegram::SettingsMenu::CHOICES).map { |item| short_name(item[:key]) }
    end

    def short_name(key)
      section, *rest = key.split(".")

      GENERIC.include?(rest.last) ? section : rest.last
    end

    # The daemon comes up immediately: a console without it is just a
    # window, and the point is to already be connected the moment the tab opens.
    def start_daemon
      @daemon = Daemon.new(config: @config, store: @store, secrets: @secrets, logger: @out)

      return say("") if @daemon.start

      say("")
      say("The daemon isn't running — the commands below still work.")
      say("")
    end

    def loop_commands
      while (line = prompt)
        line = line.strip
        next if line.empty?

        break if %w[/quit /exit /q].include?(line)

        execute(line)
      end
    end

    # Without a terminal — a plain gets: control sequences over a pipe
    # would turn into garbage, and the console stays usable from scripts.
    def prompt
      return plain_prompt unless $stdin.tty?

      editor.read(prompt_text)
    rescue Interrupt
      # Ctrl-C mid-line clears the line rather than quitting the program:
      # quitting is /quit, so an accidental keypress doesn't drop the connection.
      say("^C")
      ""
    end

    def editor
      @editor ||= Prompt.new(
        output: @out,
        completer: ->(word) { complete(word, line: word) },
        describer: ->(name) { COMMANDS[name] }
      )
    end

    def plain_prompt
      @out.print(prompt_text)
      $stdin.gets
    end

    # The prompt itself shows the state: after stepping away it's easy
    # to forget interception is off, and end up with no notifications exactly when they're needed.
    def prompt_text
      @config.get("answers.away", false) ? "🚶 > " : "> "
    end

    def execute(line)
      command, argument = line.split(/\s+/, 2)
      command = "/#{command}" unless command.start_with?("/")

      case command
      # A bare slash means "show me what's here" — typing it and hitting
      # enter is more natural than remembering the word help.
      when "/", "//" then help
      when "/help" then help
      when "/sessions" then list(registry.refresh.agents, "Agent sessions")
      when "/tabs" then list(registry.refresh.sessions, "All tabs")
      when "/status" then status
      when "/away" then away(argument)
      when "/settings" then settings(argument)
      when "/token" then token
      when "/doctor" then doctor
      when "/hooks" then hooks(argument)
      else say("I don't know the command #{command}. Type /help.")
      end
    rescue StandardError => e
      say("Error: #{e.class}: #{e.message}")
    end

    def help
      width = COMMANDS.keys.map(&:length).max
      COMMANDS.each { |name, text| say("  #{name.ljust(width)}  #{text}") }
    end

    def registry = @registry ||= Registry.new

    def list(sessions, title)
      return say("#{title}: empty.") if sessions.empty?

      say(title)
      sessions.each_with_index do |session, index|
        say(format("%3d. %s %s", index + 1, marker(session), describe(session)))
      end
    end

    def marker(session)
      return "⏳" if session.processing?
      return "🖥" if session.terminalless?
      return "▸" if session.at_shell_prompt?

      "·"
    end

    def describe(session)
      agent = session.agent ? session.agent.to_s : (session.foreground_command || "—")
      place = session.terminalless? ? "vscode" : session.tty.to_s.sub(%r{\A/dev/}, "")

      "#{agent} · #{session.label} · #{place}"
    end

    def status
      sessions = registry.refresh.sessions

      say("Tabs: #{sessions.size}, with an agent: #{sessions.count(&:agent?)}")
      say("Backends: #{registry.available_backends.map(&:name).join(', ')}")
      say("Mode: #{@daemon&.away_label || 'daemon not running'}")
      say("Waiting for a reply: #{@daemon ? @daemon.pending.size : 0}")
      say("Chats: #{Array(@config.get('telegram.allowed_chat_ids', [])).join(', ')}")
    end

    def away(argument)
      value = case argument.to_s.strip.downcase
              when "on", "yes" then true
              when "off", "no" then false
              else !@config.get("answers.away", false)
              end

      @config.set("answers.away", value).save
      say(value ? "🚶 Away. Agent questions go to Telegram and wait for a reply." :
                  "🪑 Present. Questions stay in the terminal.")
    end

    def settings(argument)
      return open_settings if argument.to_s.strip.empty?

      key = resolve_setting(argument.strip)
      return say("I don't know the setting #{argument}. Type /settings with no argument.") unless key

      say(settings_menu.apply({ "key" => key }))
    end

    def settings_menu
      Channels::Telegram::SettingsMenu.new(store: @store, config: @config)
    end

    # Showing human-readable names but requiring the internal name back
    # is a trap: you see "Rate-limit anchors," type it, and get
    # rejected. So the settings list is navigated with arrows, same as the commands.
    def open_settings
      return say(settings_menu.text) unless $stdin.tty?

      items = Channels::Telegram::SettingsMenu::TOGGLES +
              Channels::Telegram::SettingsMenu::CHOICES

      Menu.new(output: @out).run(
        title: "⚙️ Settings",
        rows: -> { settings_menu.rows }
      ) { |index| settings_menu.apply({ "key" => items[index][:key] }) }
    end

    # Accepts the short name, the full key, and the exact label a human
    # saw on screen: rejecting the very string that was just shown is
    # the worst thing a completion hint could do.
    def resolve_setting(name)
      needle = name.to_s.strip.downcase
      items = Channels::Telegram::SettingsMenu::TOGGLES +
              Channels::Telegram::SettingsMenu::CHOICES

      item = items.find do |entry|
        key = entry[:key]
        [key, key.split(".").last, short_name(key), entry[:label]].compact
          .map { |value| value.downcase } .include?(needle)
      end

      item && item[:key]
    end

    def token
      say("The token isn't displayed and isn't kept in history.")
      value = ask_secret("Token from @BotFather: ")
      return say("Empty — nothing changed.") if value.empty?

      @secrets.set(:telegram_token, value)
      say("Saved to: #{@secrets.target.name}. Restart the console to apply it.")
    end

    def ask_secret(label)
      @out.print(label)
      $stdin.noecho(&:gets).to_s.strip
    rescue SystemCallError, IOError
      ""
    ensure
      say("")
    end

    def doctor
      Doctor.new(config: @config, secrets: @secrets).run.each do |check|
        say("#{check.icon} #{check.name.ljust(22)} #{check.detail}")
        say("  └ #{check.fix}") if check.fix
      end
    end

    def hooks(argument)
      agent = Agents::ClaudeCode.new

      case argument.to_s.strip
      when "install" then say(agent.install!(hook_url, secret: hook_secret) ? "Connected." : "Couldn't connect.")
      when "uninstall" then say(agent.uninstall! ? "Disconnected." : "Couldn't disconnect.")
      else say("Hooks are #{agent.installed? ? 'connected' : 'not connected'}.")
      end
    end

    def hook_url = "http://127.0.0.1:#{@config.get('hooks.port', Daemon::DEFAULT_PORT)}"

    def hook_secret = @secrets.get(:hook_secret)
  end
end
