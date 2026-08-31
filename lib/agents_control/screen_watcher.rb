# frozen_string_literal: true

require "digest"

module AgentsControl
  # Notices Claude Code's local menus on a session's screen.
  #
  # Dialogs the CLI shows itself in response to a local human command —
  # switching models via /model, folder trust on first launch — never
  # produce a hook event at all. The only way to see this state is to
  # read the screen itself.
  #
  # Goes through the full Registry — sees bare iTerm2 tabs too, not just
  # tmux panes, same as RateLimitWatcher.
  #
  # The heuristic is narrow: consecutive lines "❯ 1. …" and "  2. …" —
  # this is how Claude Code draws any choice (folder trust, model switch,
  # a tool permission if it ever made it to the screen), and almost
  # nothing else draws like this.
  class ScreenWatcher
    # "1." next to the cursor marks the first option — the start of a menu.
    CURSOR_OPTION = /^\s*❯\s*1\.\s+(.+?)\s*$/

    # Later options come without the cursor, just numbered.
    OPTION = /^\s*(\d+)\.\s+(.+?)\s*$/

    # A 30-line screen comfortably covers any CLI dialog worth catching —
    # Claude Code doesn't draw menus that long.
    LINES = 30

    def initialize(registry:, config:, store:, api:, logger: nil)
      @registry = registry
      @config = config
      @store = store
      @api = api
      @logger = logger
      @running = false
    end

    def start
      return self unless enabled?

      @running = true
      @thread = Thread.new do
        tick while @running
      ensure
        nil
      end

      self
    end

    def stop
      @running = false
      @thread&.kill
    end

    # One pass over all agent sessions. Public method — tests call it
    # directly, without spinning up a real background thread.
    def tick
      candidates.each { |session| check(session) }
    rescue StandardError => e
      log("failure: #{e.class}: #{e.message}")
    ensure
      sleep(interval) if @running
    end

    private

    def enabled? = @config.get("terminal.watch_menus", true)

    def interval = @config.get("terminal.menu_poll_interval", 20)

    def candidates
      @registry.refresh.agents.reject(&:terminalless?)
    rescue StandardError
      []
    end

    def check(session)
      options = parse_menu(@registry.backend_for(session).capture(session.id, lines: LINES))
      key = menu_key(session)

      return @store.delete(key) if options.empty?

      digest = Digest::SHA1.hexdigest(options.join("\n"))
      return if @store.get(key) == digest # the same dialog — already notified

      @store.put(digest, ttl: 3600, key: key)
      notify(session, options)
    end

    def menu_key(session) = "menu:#{session.id}"

    # Looks for the last textual occurrence of "❯ 1. …" — the one
    # closest to the screen's current state, not a random numbered list
    # left over somewhere higher in the scrollback.
    def parse_menu(text)
      lines = text.to_s.each_line.map(&:chomp)
      start = lines.rindex { |line| line.match?(CURSOR_OPTION) }
      return [] unless start

      options = [lines[start][CURSOR_OPTION, 1]]
      index = start + 1

      while index < lines.size && (m = lines[index].match(OPTION)) && m[1].to_i == options.size + 1
        options << m[2]
        index += 1
      end

      options.size >= 2 ? options : []
    end

    def notify(session, options)
      text = "🖥 #{session.label} is waiting for a choice in the terminal:\n\n" +
             options.each_with_index.map { |option, i| "#{i + 1}. #{option}" }.join("\n")

      chats.each do |chat_id|
        sent = @api.send_message(chat_id: chat_id, text: text, reply_markup: buttons(session, options))
        remember_reply(chat_id, sent, session)
      rescue StandardError
        # One unreachable chat must not affect the rest.
        next
      end
    end

    def remember_reply(chat_id, sent, session)
      id = sent.is_a?(Hash) ? sent["message_id"] : nil
      return unless id

      @store.put({ "session_id" => session.id, "cwd" => session.cwd, "label" => session.label },
                 ttl: 30 * 86_400, key: "reply:#{chat_id}:#{id}")
    end

    def buttons(session, options)
      rows = options.each_with_index.map do |option, i|
        [{
          text: "#{i + 1}. #{option}"[0, 60],
          callback_data: @store.put({ "action" => "menu_choice", "session_id" => session.id,
                                      "choice" => i + 1 }, ttl: 3600)
        }]
      end

      { inline_keyboard: rows }
    end

    def chats = Array(@config.get("telegram.allowed_chat_ids", []))

    # log() catches any write failure itself: an exception raised inside
    # a rescue isn't caught by that same rescue, and would kill the
    # thread for good.
    def log(message)
      @logger&.puts("[screen-watcher] #{message}")
    rescue StandardError
      nil
    end
  end
end
