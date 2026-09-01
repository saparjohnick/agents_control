# frozen_string_literal: true

module AgentsControl
  module Channels
    module Telegram
      # Parses incoming updates and runs commands.
      #
      # The sender check runs first, before anything else is parsed.
      # An empty allowed-chats list means "answer nobody".
      class Router
        MAX_MESSAGE = Chunker::MAX_MESSAGE

        # Commands in these tabs go to a remote server, not the laptop —
        # they get a separate confirmation.
        REMOTE_COMMANDS = %w[ssh mosh].freeze

        # Shared list for the Telegram menu and for /help: a menu that's
        # drifted from reality is worse than no menu. The third element
        # is the argument syntax, needed only in /help; setMyCommands
        # doesn't show the argument.
        COMMANDS = [
          ["agents", "sessions with a live agent"],
          ["tabs", "all terminal tabs"],
          ["status", "what's happening right now"],
          ["away", "intercept agent questions"],
          ["settings", "settings"],
          ["context", "the agent's recent messages", "N"],
          ["screen", "show a tab's screen", "N"],
          ["focus", "switch to a tab", "N"],
          ["run", "run a command in a tab", "N command"],
          ["new", "new tab", "[directory]"],
          ["help", "this help text"]
        ].freeze

        HELP = (["Commands:", ""] +
                COMMANDS.map { |name, text, hint| "/#{name}#{hint ? " #{hint}" : ''} — #{text}" }).join("\n")

        def initialize(api:, registry:, store:, config:, keyboards: nil, pending: nil, logger: nil)
          @api = api
          @registry = registry
          @store = store
          @config = config
          @keyboards = keyboards || Keyboards.new(store: store)
          @pending = pending
          @logger = logger
        end

        def handle(update)
          if (callback = update["callback_query"])
            handle_callback(callback)
          elsif (message = update["message"])
            handle_message(message)
          end
        rescue Api::Unavailable
          # The offset only advances after successful handling — the update will come back.
          raise
        rescue StandardError => e
          warn("agents_control: #{@api.redact(e.message)}")
        end

        private

        def allowed?(chat_id)
          allowed = @config.get("telegram.allowed_chat_ids", [])

          allowed.map(&:to_s).include?(chat_id.to_s)
        end

        def handle_message(message)
          chat_id = message.dig("chat", "id")
          return unless allowed?(chat_id)

          text = message["text"].to_s.strip

          replied = message["reply_to_message"]
          return answer_by_reply(chat_id, replied, text) if replied && !text.empty?

          return compose_answer(chat_id, text) if composing?(chat_id) && !text.start_with?("/")

          command, argument = text.split(/\s+/, 2)

          dispatch(chat_id, command.to_s.sub(/@.*\z/, ""), argument.to_s)
        end

        # If the agent is still waiting, the reply goes straight into the
        # open hook — this works even for terminalless sessions.
        # Otherwise the text is typed into the tab, found via target.
        def answer_by_reply(chat_id, replied, text)
          target = @store.get("reply:#{chat_id}:#{replied['message_id']}")
          return say(chat_id, "I don't remember which session that message was about.") unless target

          question = target["question_id"]
          return deliver(chat_id, question, Reply.text(text)) if question && @pending&.find(question)

          type_into_session(chat_id, target, text)
        end

        # First, the exact session by session_id — unambiguous even when
        # several tabs share one cwd, and works for any session type:
        # /run and /screen remember the terminal's own session id, not
        # an agent's hook id, so this resolves directly whether the
        # target is an agent or a plain shell tab. Matching by cwd is
        # the fallback for when that tab has already closed — an agent
        # match wins there if one exists (the common case: replying to
        # an agent's own notification), otherwise any matching tab does
        # (a plain tab mid-interactive-command has no agent to prefer).
        def type_into_session(chat_id, target, text)
          exact = @registry.refresh.find(target["session_id"])
          return execute(chat_id, exact, text, show_result: !exact.agent?) if exact && !exact.terminalless?

          candidates = @registry.sessions.select { |s| s.cwd == target["cwd"] && !s.terminalless? }
          agent_matches = candidates.select(&:agent?)
          matching = agent_matches.empty? ? candidates : agent_matches

          case matching.size
          when 0 then say(chat_id, "#{target['label']} isn't waiting anymore, and I couldn't find the tab.")
          when 1 then execute(chat_id, matching.first, text, show_result: !matching.first.agent?)
          else say(chat_id, "#{target['label']} has several tabs — use /run NUMBER to pick one.")
          end
        end

        def composing_key(chat_id) = "composing:#{chat_id}"

        def composing?(chat_id) = !@store.get(composing_key(chat_id)).nil?

        def compose_answer(chat_id, text)
          question_id = @store.take(composing_key(chat_id))
          return say(chat_id, "That question isn't current anymore.") unless question_id

          deliver(chat_id, question_id, Reply.text(text))
        end

        def deliver(chat_id, question_id, reply)
          return say(chat_id, "There's nobody to deliver this reply to.") unless @pending

          if @pending.answer(question_id, reply)
            say(chat_id, "Sent to the agent.")
          else
            say(chat_id, "The agent isn't waiting anymore — the question timed out.")
          end
        end

        def dispatch(chat_id, command, argument)
          case command
          when "/start", "/help" then say(chat_id, HELP, markup: @keyboards.main_menu)
          when "/agents", "" then agents_list(chat_id)
          when "/tabs" then tabs_list(chat_id)
          when "/screen" then screen(chat_id, argument)
          when "/focus" then focus(chat_id, argument)
          when "/run" then run(chat_id, argument)
          when "/new" then create_tab(chat_id, argument)
          when "/away" then toggle_away(chat_id, argument)
          when "/settings" then show_settings(chat_id)
          when "/context" then context(chat_id, argument)
          when "/status" then status(chat_id)
          else say(chat_id, "I don't know that command.\n\n#{HELP}")
          end
        end

        # A shared refresh for both lists — otherwise the same session's
        # number could differ between "All tabs" and "Agents".
        def agents_list(chat_id)
          universe = @registry.refresh.sessions
          list(chat_id, universe.select(&:agent?), "🤖 Agent sessions", universe: universe)
        end

        def tabs_list(chat_id)
          universe = @registry.refresh.sessions
          list(chat_id, universe, "🖥 All tabs", universe: universe)
        end

        def list(chat_id, sessions, title, universe: sessions)
          if sessions.empty?
            return say(chat_id, "#{title}\n\nEmpty.", markup: @keyboards.list_actions)
          end

          say(chat_id, @keyboards.render_list(sessions, universe: universe, chat_id: chat_id, title: title),
              markup: @keyboards.list_actions)
        end

        def screen(chat_id, argument)
          with_session(chat_id, argument) { |session| show_screen(chat_id, session) }
        end

        def focus(chat_id, argument)
          with_session(chat_id, argument) do |session|
            ok = @registry.backend_for(session).focus(session.id)
            say(chat_id, ok ? "Switched to #{session.label}." : "Couldn't switch.")
          end
        end

        def run(chat_id, argument)
          number, command = argument.split(/\s+/, 2)

          return say(chat_id, "Usage: /run NUMBER command") if command.to_s.empty?

          with_session(chat_id, number) do |session|
            next say(chat_id, "This session has no terminal — nothing to run there.") if session.terminalless?

            if remote?(session)
              confirm_remote(chat_id, session, command)
            else
              # An agent isn't a shell command that finishes in a
              # couple of seconds — it's a real task, and hooks already
              # own telling Telegram when it's actually done or needs
              # something. Capturing a "result" a moment after typing
              # would just catch it mid-thought and fall back to
              # dumping its whole transcript, which isn't a result at
              # all — same reasoning as replying to an agent's own
              # question (type_into_session).
              execute(chat_id, session, command, show_result: !session.agent?)
            end
          end
        end

        # A tab's title isn't trustworthy — the foreground process is
        # read from the process tree, same as when looking for an agent.
        def remote?(session)
          REMOTE_COMMANDS.include?(session.foreground_command.to_s)
        end

        def confirm_remote(chat_id, session, command)
          key = @store.put({ "action" => "run", "session_id" => session.id, "text" => command },
                           ttl: 300)

          markup = { inline_keyboard: [[
            { text: "⚠️ Run on #{session.label}", callback_data: key },
            { text: "cancel", callback_data: @store.put({ "action" => "cancel" }, ttl: 300) }
          ]] }

          say(chat_id, "Tab #{session.label} is busy with #{session.foreground_command}.\n" \
                       "The command will go to the remote machine:\n\n`#{command}`",
              markup: markup)
        end

        # Enter is sent as a separate call, not tacked onto the same
        # input: a merged call can fail to send multi-line text at all.
        TYPING_PAUSE = 0.4

        # How long to wait after the command lands before reading the
        # screen back. There's no way to know when a command actually
        # finishes without polling for it, so this is a fixed guess
        # tuned for the common case (git status, ls, a quick build
        # check) — long enough for those, short enough not to feel
        # laggy. A slower command just gets caught mid-flight, same as
        # looking over someone's shoulder while it's still running;
        # /screen still shows the up-to-date state a moment later.
        RUN_SETTLE_PAUSE = 1.2

        def run_result_lines = @config.get("terminal.run_result_lines", 200)

        def execute(chat_id, session, command, show_result: false)
          backend = @registry.backend_for(session)
          before = show_result ? capture_screen(session, lines: run_result_lines) : nil

          ok = backend.send_text(session.id, command, newline: false) &&
               sleep(TYPING_PAUSE).then { backend.send_text(session.id, "", newline: true) }

          return say(chat_id, "Couldn't send.") unless ok
          return say(chat_id, "Sent to #{session.label}.") unless show_result

          sleep(RUN_SETTLE_PAUSE)
          show_command_result(chat_id, session, since: before, command: command)
        end

        # Shows what's new since `since` (the screen right before the
        # command was typed) rather than an arbitrary tail slice of the
        # current screen — otherwise a short result could be padded out
        # with whatever the terminal already had on it a moment ago.
        def show_command_result(chat_id, session, since:, command:)
          after = capture_screen(session, lines: run_result_lines)
          text = new_output_since(after, since, command: command)
          log("run result: session=#{session.id} before=#{since.to_s.length}b " \
              "after=#{after.to_s.length}b prefix_match=#{after.to_s.start_with?(since.to_s)} " \
              "command_anchor=#{command.to_s.strip.length >= MIN_COMMAND_ANCHOR && after.to_s.include?(command.to_s.strip)} " \
              "result=#{text.to_s.length}b")

          if text && !text.empty?
            sent = say_chunked(chat_id, "🖥 #{session_descriptor(session)}\n\n", text, code: true)
            return sent.each { |msg| remember_reply(chat_id, msg, session) }
          end

          # new_output_since only comes back empty when the capture
          # itself was empty — a genuinely blank screen. The transcript
          # fallback below is keyed by cwd, not by this specific session
          # — several tabs (or VS Code sessions) can sit on the exact
          # same project directory, and it'll pick whichever of them
          # wrote to its transcript most recently. For a plain shell tab
          # that's cross-session noise: a result from a totally
          # different session shown as if it were this one's. Only
          # worth the ambiguity when there's genuinely nothing else to
          # offer — an agent (its own conversation is at least
          # thematically the right session) or a session with no
          # terminal at all (nothing else exists to show).
          return say(chat_id, "The screen is empty.") unless session.agent? || session.terminalless?

          show_agent_context(chat_id, session)
        end

        # A one- or two-character reply ("y", "n", "q" mid `git add -p`)
        # turns up constant false matches in ordinary output — not a
        # safe anchor at all. Anything shorter than this falls straight
        # through to the prefix/marker fallback instead.
        MIN_COMMAND_ANCHOR = 3

        # Returns whatever showed up in `after` beyond `since`.
        #
        # The command itself is the sharpest anchor available: the
        # shell echoes it back verbatim, and unlike the prompt (which
        # looks identical after every command) the command text is
        # specific to this exact invocation. rindex, not index — the
        # *last* occurrence is the one nearest to now, i.e. this send,
        # not some earlier time the same command happened to run. This
        # is also what makes it more reliable than prefix/marker
        # matching when the tab is shared with a human actively typing
        # in it: `since` doesn't have to relate to `after` at all for
        # this to work, since it just locates the command's own echo
        # directly.
        #
        # An exact prefix match is the fallback: unambiguous whenever
        # nothing scrolled out of the capture window between the two
        # snapshots, since `after` is then simply `since` with new
        # content appended and there's nothing to search for at all.
        #
        # Marker search (since's own last two lines, most recent
        # occurrence) is the last resort, for whatever's too short to
        # anchor on and doesn't fit as a literal prefix either.
        #
        # No matter which method resolves it, an anchor is never
        # allowed to produce silence: if it lands on nothing (the
        # reference point itself, unchanged, or a boundary right at the
        # tail), what's actually on screen right now is still real and
        # still worth showing — the whole point of /run is seeing the
        # result, and reporting "no new output" when there's visibly a
        # result sitting right there is a worse failure than
        # occasionally including a line of stale context.
        def new_output_since(after, since, command: nil)
          after_s = after.to_s
          since_s = since.to_s

          needle = command.to_s.strip
          if needle.length >= MIN_COMMAND_ANCHOR
            index = after_s.rindex(needle)
            return after_s[index..].to_s if index
          end

          return after_s if since_s.strip.empty?

          tail = if after_s.start_with?(since_s)
                   after_s[since_s.length..]
                 else
                   marker = since_s.rstrip.lines.last(2).join
                   index = marker.strip.empty? ? nil : after_s.rindex(marker)
                   index ? after_s[(index + marker.length)..] : nil
                 end

          tail = tail.to_s.sub(/\A\n+/, "")
          tail.empty? ? after_s : tail
        end

        def create_tab(chat_id, directory)
          backend = @registry.available_backends.first
          return say(chat_id, "No terminal available.") unless backend

          id = backend.create_tab(cwd: directory.empty? ? nil : directory)
          say(chat_id, id ? "Created tab #{id}." : "Couldn't create a tab.")
        end

        # Interception is turned on explicitly: while a human is at the
        # keyboard, they'll answer in the terminal faster themselves, and
        # a busy hook keeps the dialog from ever reaching the screen at all.
        def toggle_away(chat_id, argument)
          value = case argument.strip.downcase
                  when "on", "yes" then true
                  when "off", "no" then false
                  else !@config.get("answers.away", false)
                  end

          @config.set("answers.away", value).save

          say(chat_id, value ? "🚶 Away. Agent questions now come here." :
                               "🪑 Present. Questions stay in the terminal.")
        end

        def settings_menu
          @settings_menu ||= SettingsMenu.new(store: @store, config: @config)
        end

        def show_settings(chat_id)
          say(chat_id, settings_menu.text, markup: settings_menu.markup)
        end

        def transcript_root
          @config.get("terminal.transcript_root", Transcript::PROJECTS)
        end

        def context(chat_id, argument)
          with_session(chat_id, argument) do |session|
            transcript = Transcript.for_cwd(session.cwd, root: transcript_root)

            unless transcript.exists?
              next say(chat_id, "No transcript found — the agent may not have run here.")
            end

            sent = say_chunked(chat_id, "📄 #{session.label}\n\n", transcript.render)
            sent.each { |msg| remember_reply(chat_id, msg, session) }
          end
        end

        # Not necessarily an immediate reply, but whenever convenient — TTL 30 days, not a day.
        REPLY_TARGET_TTL = 30 * 86_400

        def remember_reply(chat_id, sent, session)
          id = sent.is_a?(Hash) ? sent["message_id"] : nil
          return unless id

          @store.put({ "session_id" => session.id, "cwd" => session.cwd, "label" => session.label },
                     ttl: REPLY_TARGET_TTL, key: "reply:#{chat_id}:#{id}")
        end

        def status(chat_id)
          sessions = @registry.refresh.sessions
          backends = @registry.available_backends.map(&:name).join(", ")

          say(chat_id, "Tabs: #{sessions.size}\nAgents: #{sessions.count(&:agent?)}\n" \
                       "Backends: #{backends.empty? ? 'none' : backends}\n" \
                       "Mode: #{@config.get('answers.away', false) ? '🚶 away' : '🪑 present'}\n" \
                       "Waiting for a reply: #{@pending ? @pending.size : 0}")
        end

        def handle_callback(callback)
          chat_id = callback.dig("message", "chat", "id")
          return unless allowed?(chat_id)

          # The Bot API gives ten seconds to answer a button press.
          @api.answer_callback_query(callback["id"])

          # take — the key is one-shot, redelivery won't run the action twice.
          payload = @store.take(callback["data"].to_s)
          return say(chat_id, "This button expired — pull up the list again.") if payload.nil?

          perform(chat_id, payload)
        rescue Terminals::Unsupported => e
          say(chat_id, e.message)
        end

        def perform(chat_id, payload)
          case payload["action"]
          when "list_agents" then agents_list(chat_id)
          when "list_tabs" then tabs_list(chat_id)
          when "status" then status(chat_id)
          when "show_settings" then show_settings(chat_id)
          when "cancel" then say(chat_id, "Cancelled.")
          when "answer" then answer_question(chat_id, payload)
          when "compose" then start_compose(chat_id, payload)
          when "transcript" then show_transcript(chat_id, payload)
          when "setting" then change_setting(chat_id, payload)
          when "menu_choice" then choose_menu_option(chat_id, payload)
          when "ask_question_choice" then answer_ask_user_question(chat_id, payload)
          else act_on_session(chat_id, payload)
          end
        end

        def answer_question(chat_id, payload)
          spec = payload["reply"] || {}
          reply = case spec["kind"]
                  when "allow" then Reply.allow(remember: spec["remember"])
                  when "deny" then Reply.deny
                  else Reply.text(spec["text"].to_s)
                  end

          deliver(chat_id, payload["question_id"], reply)
        end

        def start_compose(chat_id, payload)
          @store.put(payload["question_id"], ttl: 600, key: composing_key(chat_id))
          say(chat_id, "Write your reply as the next message.")
        end

        def change_setting(chat_id, payload)
          changed = settings_menu.apply(payload)
          return say(chat_id, "That setting no longer exists.") unless changed

          say(chat_id, "#{settings_menu.text}\n\nChanged — #{changed}",
              markup: settings_menu.markup)
        end

        # Types the option number and Enter right into the pane — the
        # way a human would from the keyboard. There's no structured
        # reply here, unlike with hooks.
        def choose_menu_option(chat_id, payload)
          session = @registry.refresh.find(payload["session_id"])
          return say(chat_id, "That session is already closed.") unless session

          ok = @registry.backend_for(session).send_text(session.id, payload["choice"].to_s)
          say(chat_id, ok ? "Chose \"#{payload['choice']}\" in #{session.label}." : "Couldn't send the choice.")
        end

        # Same mechanism as choose_menu_option: types the option number
        # straight into the pane. AskUserQuestion's answer never flows
        # through the hook — it's always been resolved by hand at the
        # terminal, and this just sends the same keystroke a human would.
        def answer_ask_user_question(chat_id, payload)
          session = @registry.refresh.find(payload["session_id"])
          return say(chat_id, "That session is already closed.") unless session

          ok = @registry.backend_for(session).send_text(session.id, payload["choice"].to_s)
          say(chat_id, ok ? "Sent to #{session.label}." : "Couldn't send the choice.")
        end

        def show_transcript(chat_id, payload)
          transcript = Transcript.new(payload["path"])
          return say(chat_id, "No transcript available.") unless transcript.exists?

          say_chunked(chat_id, "📄 #{payload['label']}\n\n", transcript.render)
        end

        def act_on_session(chat_id, payload)
          session = @registry.refresh.find(payload["session_id"])
          return say(chat_id, "That session is already closed.") unless session

          case payload["action"]
          when "focus" then focus_session(chat_id, session)
          when "screen" then show_screen(chat_id, session)
          when "run" then execute(chat_id, session, payload["text"], show_result: !session.agent?)
          when "close_confirm" then say(chat_id, "Close #{session.label}?",
                                        markup: @keyboards.confirm("close", session))
          when "close" then close_session(chat_id, session)
          end
        end

        def focus_session(chat_id, session)
          @registry.backend_for(session).focus(session.id)
          say(chat_id, "Switched to #{session.label}.")
        end

        # The screen is the first choice, not a fallback: it shows what's
        # happening right now (a build, a spinner, a local CLI menu), not
        # just finished lines from the transcript. The transcript stays
        # the fallback for terminalless sessions and for a freshly
        # created tab's blank screen.
        def show_screen(chat_id, session, lines: @config.get("terminal.context_lines", 80))
          text = capture_screen(session, lines: lines)
          if text && !text.empty?
            sent = say_chunked(chat_id, "🖥 #{session_descriptor(session)}\n\n", text, code: true)
            return sent.each { |msg| remember_reply(chat_id, msg, session) }
          end

          return say(chat_id, "The screen is empty.") unless session.agent? || session.terminalless?

          show_agent_context(chat_id, session)
        end

        def capture_screen(session, lines: @config.get("terminal.context_lines", 80))
          @registry.backend_for(session).capture(session.id, lines: lines)
        rescue Terminals::Unsupported
          nil
        end

        # The label alone isn't always enough to tell tabs apart — several
        # can share the same project directory and so the same label. The
        # tty is what actually distinguishes them, and it's the same
        # identifier a terminal's own window/tab chrome would show.
        def session_descriptor(session)
          return session.label if session.terminalless?

          tty = session.tty.to_s.sub(%r{\A/dev/}, "")
          tty.empty? ? session.label : "#{session.label} · #{tty}"
        end

        def show_agent_context(chat_id, session)
          transcript = Transcript.for_cwd(session.cwd, root: transcript_root)

          return say(chat_id, "The screen is empty, and no transcript was found.") unless transcript.exists?

          sent = say_chunked(chat_id, "📄 #{session.label} (transcript)\n\n", transcript.render)
          sent.each { |msg| remember_reply(chat_id, msg, session) }
        end

        def close_session(chat_id, session)
          ok = @registry.backend_for(session).close(session.id)
          say(chat_id, ok ? "Closed #{session.label}." : "Couldn't close it.")
        end

        def with_session(chat_id, number)
          id = @keyboards.session_for(chat_id, number.to_s.strip)
          return say(chat_id, "No such number — pull up the list again.") unless id

          session = @registry.refresh.find(id)
          return say(chat_id, "That session is already closed.") unless session

          yield(session)
        rescue Terminals::Unsupported => e
          say(chat_id, e.message)
        end

        HEADER_HEADROOM = 300

        # A long response goes out as multiple messages (Chunker), never
        # clipped. code: true wraps each chunk in its own code block —
        # otherwise a split between chunks would leave unclosed triple quotes.
        def say_chunked(chat_id, header, body, markup: nil, code: false)
          chunks = Chunker.split(body, limit: MAX_MESSAGE - HEADER_HEADROOM)
          chunks = [""] if chunks.empty?

          chunks.each_with_index.map do |chunk, i|
            content = code ? "```\n#{chunk}\n```" : chunk
            prefix = i.zero? ? header : "↪️ #{i + 1}/#{chunks.size}\n\n"
            say(chat_id, "#{prefix}#{content}", markup: i == chunks.size - 1 ? markup : nil)
          end
        end

        # MarkdownV2 is strict: one incorrectly escaped period and
        # Telegram rejects the whole send, so there's always a fallback
        # to plain text here.
        def say(chat_id, text, markup: nil)
          @api.send_message(chat_id: chat_id, text: Markdown.convert(text),
                            reply_markup: markup, parse_mode: "MarkdownV2")
        rescue Api::Error => e
          raise unless e.message.include?("can't parse entities")

          @api.send_message(chat_id: chat_id, text: text, reply_markup: markup)
        end

        def log(message)
          @logger&.puts("[#{Time.now.strftime('%H:%M:%S')}] #{message}")
        end
      end
    end
  end
end
