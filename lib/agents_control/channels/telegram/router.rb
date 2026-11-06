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

        # Long enough to walk somewhere quieter and type carefully,
        # short enough that a challenge left unanswered doesn't sit
        # around waiting to be replied to by accident tomorrow.
        CHALLENGE_TTL = 300

        # Commands in these tabs go to a remote server, not the laptop —
        # they get a separate confirmation.
        REMOTE_COMMANDS = %w[ssh mosh].freeze

        # Programs that read keystrokes as their own input, not as a
        # line to submit to a shell. Sending a command into one of
        # these wouldn't run it — it'd feed the letters to whatever's
        # already there instead: pager navigation, an editor's insert
        # mode, a REPL evaluating each character-by-character. Confirmed
        # against a real incident: `git log`'s pager was still open,
        # "git status" went in as keystrokes, and nothing about it ran
        # as a command at all.
        INTERACTIVE_COMMANDS = %w[less more most vim vi nvim emacs nano pico
                                   man top htop irb pry python python3 node
                                   mysql psql sqlite3].freeze

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
          ["getfile", "send a file — a tab number lists recent ones", "[N|path]"],
          ["screen", "show a tab's screen", "N"],
          ["focus", "switch to a tab", "N"],
          ["run", "run a command in a tab", "N command"],
          ["new", "new tab", "[directory]"],
          ["reload", "restart the daemon into updated code"],
          ["help", "this help text"]
        ].freeze

        HELP = (["Commands:", ""] +
                COMMANDS.map { |name, text, hint| "/#{name}#{hint ? " #{hint}" : ''} — #{text}" }).join("\n")

        # A single worker, not a thread per job: an album's later parts
        # depend on a Store write its first part makes (see
        # deliver_file's album_session), so jobs stay FIFO instead of
        # racing each other the way Channel's resend_later would.
        class AttachmentQueue
          STOP = :stop

          # setup runs once, on the worker thread itself, before its
          # first job — Router uses it to tag the thread with its own
          # Registry (see Router#registry), without this generic queue
          # needing to know what a Registry is.
          def initialize(&setup)
            @jobs = Thread::Queue.new
            @worker = Thread.new do
              setup&.call
              run
            end
          end

          def call(&job) = @jobs << job

          # Lets a queue's owner shut its worker down cleanly — tests
          # build a real queue to prove ordering and must not leak the
          # thread once they're done with it.
          def stop
            @jobs << STOP
            @worker.join
          end

          private

          def run
            while (job = @jobs.pop) != STOP
              job.call
            end
          end
        end

        # reload_trigger: Daemon#trap_reload is what actually acts on
        # it; overridden in tests, since the real HUP's default action
        # is to kill whatever process gets sent it.
        #
        # attachment_registry defaults to the same Registry as the rest
        # of Router: a caller that wants the two threads (poll loop,
        # attachment queue worker) to stop sharing a cache — which is
        # the whole point in production — passes a second, independent
        # one. See Daemon#start_bot and Router#registry.
        def initialize(api:, registry:, store:, config:, keyboards: nil, pending: nil, logger: nil,
                       passphrase: nil, inbox: nil, reload_trigger: -> { Process.kill("HUP", Process.pid) },
                       attachment_registry: registry, attachment_queue: nil)
          @api = api
          @registry = registry
          @attachment_registry = attachment_registry
          @store = store
          @config = config
          @keyboards = keyboards || Keyboards.new(store: store)
          @pending = pending
          @logger = logger
          @passphrase = passphrase || Passphrase.new
          @reload_trigger = reload_trigger
          @inbox = inbox
          @attachment_queue = attachment_queue || AttachmentQueue.new { Thread.current[:registry] = @attachment_registry }
        end

        # Not called by the daemon today — process exit takes the
        # worker thread with it either way — but a Router built
        # directly (every test that doesn't go through build_router's
        # synchronous stub) owns a real thread and needs a way to let
        # go of it.
        def stop = @attachment_queue.stop

        # Called once by the daemon on start; everything else here is
        # driven by an incoming update.
        def announce(chat_ids)
          chat_ids.each { |chat_id| announce_passphrase(chat_id) }
        rescue StandardError => e
          # A notice that couldn't be sent is not a reason for the
          # daemon to fail to come up.
          log("couldn't send the passphrase notice: #{e.class}")
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

        # Thread-tagged, not a plain @registry read: AttachmentQueue's
        # worker tags itself with @attachment_registry once at startup
        # (see its setup block in #initialize), so its scans use that
        # instead — independently of, and never racing, the poll
        # thread's own cache.
        def registry = Thread.current[:registry] || @registry

        def allowed?(chat_id)
          allowed = @config.get("telegram.allowed_chat_ids", [])

          allowed.map(&:to_s).include?(chat_id.to_s)
        end

        def handle_message(message)
          chat_id = message.dig("chat", "id")
          return unless allowed?(chat_id)

          attachment = Inbox.attachment(message)
          return receive(chat_id, message, attachment) if attachment

          text = message["text"].to_s.strip

          replied = message["reply_to_message"]
          if replied && !text.empty?
            # Checked before answer_by_reply, which would otherwise take
            # the passphrase for something to type into a pane — and a
            # passphrase typed into a terminal is a passphrase in the
            # shell history.
            challenge = @store.take(challenge_key(chat_id, replied["message_id"]))
            return unlock(chat_id, challenge, text, message["message_id"]) if challenge

            # Scoped to a reply on the wizard's own message rather than
            # "whatever comes next": otherwise a half-finished wizard
            # swallows the next thing typed, which could be a /run or an
            # answer an agent is waiting on.
            step = @store.take(wizard_key(chat_id, replied["message_id"]))
            return wizard_entry(chat_id, step, text, message["message_id"]) if step

            return answer_by_reply(chat_id, replied, text)
          end

          return compose_answer(chat_id, text) if composing?(chat_id) && !text.start_with?("/")

          if !text.empty? && !text.start_with?("/") && (target = @store.get(last_target_key(chat_id)))
            return answer_target(chat_id, target, text)
          end

          command, argument = text.split(/\s+/, 2)

          dispatch(chat_id, command.to_s.sub(/@.*\z/, ""), argument.to_s)
        end

        # If the agent is still waiting, the reply goes straight into the
        # open hook — this works even for terminalless sessions.
        # Otherwise the text is typed into the tab, found via target.
        def answer_by_reply(chat_id, replied, text)
          target = @store.get("reply:#{chat_id}:#{replied['message_id']}")
          return say(chat_id, "I don't remember which session that message was about.") unless target

          answer_target(chat_id, target, text)
        end

        def answer_target(chat_id, target, text)
          question = target["question_id"]
          return deliver(chat_id, question, Reply.text(text)) if question && @pending&.find(question)

          type_into_session(chat_id, target, text)
        end

        # Returns the session it typed into, or nil once it has either
        # said why not or offered disambiguation buttons.
        def type_into_session(chat_id, target, text)
          session = resolve_session(chat_id, target) { |candidates| offer_disambiguation(chat_id, target, candidates, text) }
          execute(chat_id, session, text, show_result: !session.agent?) if session
          session
        end

        # Same resolution, but with no text to hand over once it's
        # picked — a plain "several tabs" message is the best this can do.
        def session_for(chat_id, target)
          resolve_session(chat_id, target) { |candidates| ask_to_pick_a_number(chat_id, candidates) }
        end

        # Exact match first (learned_session_id picks up a mapping even
        # if it was learned after this target was stored), then cwd as a
        # fallback for a closed tab, preferring an agent match if one exists.
        def resolve_session(chat_id, target)
          exact = registry.refresh.find(learned_session_id(target))
          return exact if exact && !exact.terminalless?

          matching = tabs_for(target["cwd"], agents_only: target["from_agent"])
          return matching.first if matching.size == 1

          if matching.empty?
            say(chat_id, "#{target['label']} isn't waiting anymore, and I couldn't find the tab.")
            return nil
          end

          tiebreak_by_last_interaction(chat_id, matching) || yield(matching)
        end

        def learned_session_id(target) = @store.get(agent_session_key(target["session_id"])) || target["session_id"]

        def agent_session_key(hook_session_id) = "agent_session:#{hook_session_id}"

        # Two real tabs sharing a cwd can't be told apart by directory
        # alone — whichever one the chat was already talking to wins.
        def tiebreak_by_last_interaction(chat_id, matching)
          last = @store.get(last_target_key(chat_id))
          last && matching.find { |session| session.id == last["session_id"] }
        end

        def ask_to_pick_a_number(chat_id, candidates)
          say(chat_id, "#{candidates.first.label} has several tabs — use /run NUMBER to pick one.")
          nil
        end

        # A tap both delivers the held-up text and teaches the mapping
        # for next time: once a human points at the right tab for this
        # agent's hook session, every later message it sends resolves on
        # its own — see learned_session_id.
        def offer_disambiguation(chat_id, target, candidates, text)
          rows = candidates.map { |session| [disambiguation_button(session, target, text)] }
          say(chat_id, "#{candidates.first.label} has several tabs — which one?", markup: { inline_keyboard: rows })
          nil
        end

        def disambiguation_button(session, target, text)
          payload = { "action" => "disambiguate", "hook_session_id" => target["session_id"],
                      "session_id" => session.id, "text" => text }
          { text: session.tty.to_s.sub(%r{\A/dev/}, ""), callback_data: @store.put(payload, ttl: 600) }
        end

        def resolve_disambiguation(chat_id, payload)
          session = registry.refresh.find(payload["session_id"])
          return say(chat_id, "That tab closed before you picked.") unless session

          @store.put(session.id, ttl: REPLY_TARGET_TTL, key: agent_session_key(payload["hook_session_id"]))
          sent = execute(chat_id, session, payload["text"], show_result: !session.agent?)
          remember_reply(chat_id, sent, session)
        end

        # A hook reports the directory the agent is in now, while the
        # tab and the process only know the one it was started in — so
        # an agent that cd'd into a subfolder matches no tab exactly.
        # The agent in the nearest directory above is that same agent;
        # a plain shell up there is just a neighbour.
        #
        # A message that came from an agent is answered only to an agent:
        # once that agent is gone, a shell left in the same folder is not
        # its successor, and the reply would be run there as a command.
        def tabs_for(cwd, agents_only: false)
          tabs = registry.sessions.reject(&:terminalless?)

          same = tabs.select { |s| s.cwd == cwd }
          unless same.empty?
            agents = same.select(&:agent?)
            return agents.empty? && !agents_only ? same : agents
          end

          above = tabs.select { |s| s.agent? && !s.cwd.to_s.empty? && cwd.to_s.start_with?(File.join(s.cwd, "")) }
          nearest = above.map { |s| s.cwd.length }.max
          above.select { |s| s.cwd.length == nearest }
        end

        # A file from the phone becomes a file on disk, and the agent is
        # handed its path — fetched via AttachmentQueue, not here directly.
        #
        # A path and not a link: Telegram serves file bytes from a URL
        # with the bot token in it, so pasting that into a pane would
        # put the token in the terminal, in the agent's context, and in
        # the shell history — and a leaked token is remote code
        # execution on this machine.
        def receive(chat_id, message, attachment)
          @attachment_queue.call { deliver_attachment(chat_id, message, attachment) }
        end

        def deliver_attachment(chat_id, message, attachment)
          path = inbox.fetch(attachment)
          log("received #{attachment.kind}: #{File.basename(path)}")

          deliver_file(chat_id, message, path)
        rescue Inbox::TooLarge => e
          say(chat_id, "That file is #{e.message}.")
        rescue Api::Unavailable, Api::TooManyRequests, SystemCallError => e
          # All three are transient — outlasted Inbox's own retries,
          # or Telegram rate-limiting for a moment — so the file_id is
          # still good and a second try is worth offering. A non-network
          # Api::Error below is not: whatever Telegram objected to will
          # still be true next time.
          offer_retry(chat_id, message, "Couldn't save that file: #{@api.redact(e.message)}")
        rescue Api::Error => e
          say(chat_id, "Couldn't save that file: #{@api.redact(e.message)}")
        rescue StandardError => e
          # Runs on the queue's worker thread, away from Bot#handle's
          # own backstop — without this, an escaped exception here
          # would vanish silently instead of getting logged.
          log("failed to handle #{attachment.kind}: #{e.class}: #{@api.redact(e.message)}")
        end

        RETRY_BUTTON_TTL = 1800

        def offer_retry(chat_id, message, text)
          payload = { "action" => "retry_attachment", "message" => message }
          markup = { inline_keyboard: [[{ text: "🔄 Try again",
                                          callback_data: @store.put(payload, ttl: RETRY_BUTTON_TTL) }]] }
          say(chat_id, text, markup: markup)
        end

        # Stores the whole message, not just the file_id: deliver_file
        # also reads its caption, reply, and album id.
        def retry_attachment(chat_id, payload)
          message = payload["message"]
          attachment = Inbox.attachment(message)
          return say(chat_id, "That file's gone now — send it again.") unless attachment

          receive(chat_id, message, attachment)
        end

        # Ways to say where it goes, in order of how explicit they are: a
        # caption naming a tab, a reply to something already tied to a
        # session, the rest of an album, or the session that spoke last —
        # for an agent only, since a bare path typed into a shell is a
        # command, not a file handed over. With none of those the path is
        # just handed back: guessing further is how a file ends up pasted
        # into the wrong project.
        def deliver_file(chat_id, message, path)
          caption = message["caption"].to_s.strip
          album = album_key(chat_id, message)

          if (target = caption[%r{\A/run\s+(\d+)}i, 1])
            return with_session(chat_id, target) do |session|
              execute(chat_id, session, with_path(caption.sub(%r{\A/run\s+\d+\s*}i, ""), path),
                      show_result: !session.agent?)
              remember_album(album, session)
            end
          end

          replied = message["reply_to_message"]
          remembered = replied && @store.get("reply:#{chat_id}:#{replied['message_id']}")
          return remember_album(album, type_into_session(chat_id, remembered, with_path(caption, path))) if remembered

          if (session = album_session(album))
            return execute(chat_id, session, with_path("", path))
          end

          if (last = @store.get(last_target_key(chat_id)))
            session = session_for(chat_id, last)
            return unless session

            if session.agent?
              execute(chat_id, session, with_path(caption, path))
              return remember_album(album, session)
            end
          end

          say(chat_id, "Saved:\n\n`#{path}`\n\nReply to a session's message with a file to hand it " \
                       "straight over, or caption it `/run N`.")
        end

        # Telegram splits an album into one message per file and puts the
        # caption — and the reply — on only one of them, so the rest
        # arrive saying nothing about where they go. They go where the
        # album's caption sent it: sending files together means that.
        def album_key(chat_id, message)
          group = message["media_group_id"]
          group && "album:#{chat_id}:#{group}"
        end

        # Only an agent gets the rest of the album: a bare path typed
        # into a shell is a command, not a file handed over.
        def remember_album(key, session)
          @store.put(session.id, ttl: 600, key: key) if key && session&.agent?
          session
        end

        def album_session(key)
          id = key && @store.get(key)
          session = id && registry.refresh.find(id)
          session if session&.agent? && !session.terminalless?
        end

        # Escaped, because a name like "quarterly report.csv" is
        # entirely ordinary and an unescaped one arrives at the shell as
        # two arguments. Shellwords leaves a path that needs nothing
        # alone, so the common case stays readable.
        def with_path(text, path)
          [text, Shellwords.escape(path)].reject { |part| part.to_s.empty? }.join(" ")
        end

        def inbox
          @inbox ||= Inbox.new(api: @api, keep_days: @config.get("telegram.inbox_keep_days", 14))
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
          when "/getfile" then getfile(chat_id, argument)
          when "/reload" then reload_daemon(chat_id)
          when "/status" then status(chat_id)
          else say(chat_id, "I don't know that command.\n\n#{HELP}")
          end
        end

        # A shared refresh for both lists — otherwise the same session's
        # number could differ between "All tabs" and "Agents".
        def agents_list(chat_id)
          universe = registry.refresh.sessions
          list(chat_id, universe.select(&:agent?), "🤖 Agent sessions", universe: universe)
        end

        def tabs_list(chat_id)
          universe = registry.refresh.sessions
          list(chat_id, universe, "🖥 All tabs", universe: universe, with_focus_buttons: true)
        end

        def list(chat_id, sessions, title, universe: sessions, with_focus_buttons: false)
          if sessions.empty?
            return say(chat_id, "#{title}\n\nEmpty.", markup: @keyboards.list_actions)
          end

          markup = with_focus_buttons ? @keyboards.tabs_markup(sessions, universe: universe) : @keyboards.list_actions
          say(chat_id, @keyboards.render_list(sessions, universe: universe, chat_id: chat_id, title: title),
              markup: markup)
        end

        def screen(chat_id, argument)
          with_session(chat_id, argument) { |session| show_screen(chat_id, session) }
        end

        def focus(chat_id, argument)
          with_session(chat_id, argument) do |session|
            ok = registry.backend_for(session).focus(session.id)
            sent = say(chat_id, ok ? "Switched to #{session.label}." : "Couldn't switch.")
            remember_reply(chat_id, sent, session) if ok
          end
        end

        def run(chat_id, argument)
          number, command = argument.split(/\s+/, 2)

          return say(chat_id, "Usage: /run NUMBER command") if command.to_s.empty?

          with_session(chat_id, number) do |session|
            next say(chat_id, "This session has no terminal — nothing to run there.") if session.terminalless?
            next confirm_remote(chat_id, session, command) if remote?(session)

            # An agent isn't a shell command that finishes in a couple
            # of seconds — it's a real task, and hooks already own
            # telling Telegram when it's actually done or needs
            # something. Capturing a "result" a moment after typing
            # would just catch it mid-thought and fall back to dumping
            # its whole transcript, which isn't a result at all — same
            # reasoning as replying to an agent's own question
            # (type_into_session).
            next execute(chat_id, session, command, show_result: false) if session.agent?

            next confirm_interactive(chat_id, session, command) if interactive?(session)

            # One capture serves two purposes: it's checked for a
            # pager's bare `:` prompt right here, and reused as
            # execute()'s own "before" snapshot if it turns out clean —
            # capturing twice would desync anything that reads the
            # screen expecting to see it change between calls.
            before = capture_screen(session, lines: run_result_lines)
            if paused_for_input?(before)
              confirm_interactive(chat_id, session, command)
            else
              execute(chat_id, session, command, show_result: true, before: before)
            end
          end
        end

        # A tab's title isn't trustworthy — the foreground process is
        # read from the process tree, same as when looking for an agent.
        def remote?(session)
          REMOTE_COMMANDS.include?(session.foreground_command.to_s)
        end

        def interactive?(session)
          INTERACTIVE_COMMANDS.include?(session.foreground_command.to_s)
        end

        # Backstop for interactive? missing a pager by name — a custom
        # $PAGER, or anything else not on that list. A bare `:` as the
        # entire last line is the one thing practically every pager in
        # the less/more lineage agrees on for "waiting on you"; a real
        # shell prompt always has more on that line than a single
        # colon. Takes the screen rather than the session so the
        # caller's own capture can be reused instead of taking another.
        def paused_for_input?(screen)
          screen.to_s.rstrip.lines.last.to_s.strip == ":"
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

        # A tap answers "did you mean this?", which covers the thumb on
        # the wrong line. A passphrase answers "are you you?", which is
        # the other half — an unlocked phone in someone else's hand
        # taps just as well as its owner does. When one is set it
        # replaces the button for these commands rather than joining
        # it: typing a passphrase is already a deliberate act, and two
        # steps for one decision is how people learn to hurry through
        # both.
        #
        # No passphrase set and it's the button, exactly as before.
        def confirm_policy(chat_id, session, command, reason)
          return challenge(chat_id, session, command, reason) if passphrase.configured?
          return confirm_tap(chat_id, session, command, reason) unless offer_passphrase?

          offer(chat_id, session, command, reason)
        end

        def offer_passphrase? = @config.get("telegram.offer_passphrase", true)

        # Shown instead of a bare button the first times a destructive
        # command turns up with no passphrase set. It still runs on one
        # tap — refusing to would break the tool — but the offer sits
        # next to it, at the one moment the reason for it is on screen.
        #
        # "Don't ask again" makes the refusal stick. Without that this
        # is a wizard that greets someone at every `rm -rf ~` forever,
        # which is precisely the nagging it's supposed to avoid.
        def offer(chat_id, session, command, reason)
          run_key = @store.put({ "action" => "run", "session_id" => session.id, "text" => command,
                                 "vetted" => true }, ttl: 300)
          set_key = @store.put({ "action" => "passphrase_wizard" }, ttl: 300)
          hush_key = @store.put({ "action" => "passphrase_never" }, ttl: 300)

          markup = { inline_keyboard: [
            [{ text: "⚠️ Run anyway", callback_data: run_key }],
            [{ text: "🔐 Set a passphrase", callback_data: set_key }],
            [{ text: "Don't ask again", callback_data: hush_key }]
          ] }

          say(chat_id, "#{reason}\n\n`#{command}`\n\nNothing was sent. Commands like this ask for a " \
                       "passphrase when one is set — right now there isn't one, so they ask for a tap " \
                       "instead, and a tap is something anyone holding this phone can do.",
              markup: markup)
        end

        def confirm_tap(chat_id, session, command, reason)
          key = @store.put({ "action" => "run", "session_id" => session.id, "text" => command,
                             "vetted" => true }, ttl: 300)

          markup = { inline_keyboard: [[
            { text: "⚠️ Run anyway", callback_data: key },
            { text: "cancel", callback_data: @store.put({ "action" => "cancel" }, ttl: 300) }
          ]] }

          say(chat_id, "#{reason} — it won't go to #{session.label} without a confirmation:\n\n`#{command}`",
              markup: markup)
        end

        def challenge(chat_id, session, command, reason)
          sent = say(chat_id, "#{reason}\n\n`#{command}`\n\nReply to this message with the passphrase to " \
                              "send it to #{session.label}. Anything else cancels.")
          return unless sent

          @store.put({ "session_id" => session.id, "text" => command },
                     ttl: CHALLENGE_TTL, key: challenge_key(chat_id, sent["message_id"]))
        end

        def challenge_key(chat_id, message_id) = "unlock:#{chat_id}:#{message_id}"

        def wizard_key(chat_id, message_id) = "setpass:#{chat_id}:#{message_id}"

        def start_wizard(chat_id)
          return say(chat_id, "A passphrase is already set.") if passphrase.configured?

          ask_entry(chat_id, "Reply to this message with a passphrase — at least " \
                             "#{Passphrase::MINIMUM} characters. It's deleted from the chat the moment " \
                             "it's read, and you'll be asked to type it once more.")
        end

        def ask_entry(chat_id, prompt, sealed: nil)
          sent = say(chat_id, prompt)
          return unless sent

          @store.put({ "sealed" => sealed }, ttl: CHALLENGE_TTL,
                                             key: wizard_key(chat_id, sent["message_id"]))
        end

        # Both entries are deleted, and the first never waits as plain
        # text: what's held between the two prompts is a derivation of
        # it, which is enough to tell whether the second matches and no
        # use for anything else.
        def wizard_entry(chat_id, step, entry, message_id)
          @api.delete_message(chat_id: chat_id, message_id: message_id)

          return wizard_confirm(chat_id, step["sealed"], entry) if step["sealed"]
          return ask_entry(chat_id, "That's under #{Passphrase::MINIMUM} characters. Reply with a longer one.") \
            if entry.length < Passphrase::MINIMUM

          ask_entry(chat_id, "Once more, to be sure.", sealed: Passphrase.sealed(entry))
        end

        def wizard_confirm(chat_id, sealed, entry)
          unless Passphrase.sealed_matches?(sealed, entry)
            return ask_entry(chat_id, "Those two didn't match. Reply with a passphrase to start over.")
          end

          save_passphrase(chat_id, entry)
        end

        # Writing to the Keychain from a background daemon isn't the
        # same as writing from a terminal: a locked keychain can put the
        # `security` call in front of an authorization dialog nobody is
        # looking at, and it fails on Executor's timeout rather than
        # succeeding. Saying so beats a silent nothing.
        def save_passphrase(chat_id, entry)
          passphrase.set(entry)
          say(chat_id, "Passphrase set. Destructive commands will ask for it from now on — " \
                       "send that command again if you still want it.\n\nSet from this chat, so it " \
                       "guards against whoever gets to it later, not whoever has it now. " \
                       "`agents_control passphrase set` at the machine if that matters.")
        rescue Passphrase::TooShort => e
          ask_entry(chat_id, "#{e.message.capitalize}. Reply with a longer one.")
        rescue StandardError => e
          log("couldn't save passphrase: #{e.class}")
          say(chat_id, "Couldn't save it: #{@api.redact(e.message)}\n\n" \
                       "Set it at the machine instead: `agents_control passphrase set`")
        end

        # The passphrase is deleted from the chat either way, and before
        # anything else happens: whether it was right has no bearing on
        # it not belonging in a message history that syncs to every
        # device the account is signed in on.
        def unlock(chat_id, challenge, attempt, message_id)
          @api.delete_message(chat_id: chat_id, message_id: message_id)

          unless passphrase.matches?(attempt)
            log("unlock refused: session=#{challenge['session_id']}")
            return say(chat_id, "That isn't the passphrase — nothing was sent. Send the command " \
                                "again to retry, or run `agents_control passphrase clear` at the " \
                                "machine if it's lost.")
          end

          session = registry.refresh.find(challenge["session_id"])
          return say(chat_id, "That session is already closed.") unless session

          execute(chat_id, session, challenge["text"], show_result: !session.agent?, vetted: true)
        end

        def passphrase = @passphrase

        def confirm_interactive(chat_id, session, command)
          key = @store.put({ "action" => "run", "session_id" => session.id, "text" => command },
                           ttl: 300)

          markup = { inline_keyboard: [[
            { text: "⚠️ Send anyway", callback_data: key },
            { text: "cancel", callback_data: @store.put({ "action" => "cancel" }, ttl: 300) }
          ]] }

          say(chat_id, "#{session.label} is inside #{session.foreground_command} right now, " \
                       "not at a shell prompt — the text would go to that, not run as a command:\n\n" \
                       "`#{command}`",
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

        # Every way text reaches a pane comes through here — /run, a
        # reply, a file's caption, a confirmation that was taken — so
        # this is where the guard belongs. It used to sit in `run`
        # alone, which made it worth exactly as much as the least
        # guarded of the other five callers: a caption reading
        # "/run 3 rm -rf ~ #" went straight through.
        #
        # `vetted` is set only by the confirmations that already asked
        # about *this* command. A tab running ssh gets its own
        # confirmation first, and that answered a different question —
        # "this goes to another machine", not "this destroys one" — so
        # it doesn't count, and the guard still applies after it.
        #
        # Against an agent the text is a prompt rather than a command
        # line: "look at how .env is loaded" is an ordinary thing to
        # ask, and what the agent then tries to run is the hook path's
        # business (Dispatcher#forbidden?).
        def execute(chat_id, session, command, show_result: false, before: nil, vetted: false)
          unless vetted || session.agent?
            verdict = Policy.check(command)
            return confirm_policy(chat_id, session, command, verdict.reason) if verdict.confirm?
          end

          backend = registry.backend_for(session)
          before ||= capture_screen(session, lines: run_result_lines) if show_result

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
          backend = registry.available_backends.first
          return say(chat_id, "No terminal available.") unless backend

          id = backend.create_tab(cwd: directory.empty? ? nil : directory)
          say(chat_id, id ? "Created tab #{id}." : "Couldn't create a tab.")
        end

        def reload_daemon(chat_id)
          say(chat_id, "🔄 Restarting…")
          @reload_trigger.call
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
          @settings_menu ||= SettingsMenu.new(store: @store, config: @config, passphrase: passphrase)
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

        RECENT_FILES_OFFERED = 2
        TAB_NUMBER = /\A\d+\z/

        def getfile(chat_id, argument)
          argument = argument.to_s.strip
          return send_file(chat_id, argument) unless argument.empty? || argument.match?(TAB_NUMBER)
          return with_session(chat_id, argument) { |session| offer_recent_files(chat_id, session) } unless argument.empty?

          target = @store.get(last_target_key(chat_id))
          return say(chat_id, "No active conversation yet — try /getfile NUMBER or /getfile PATH.") unless target

          session = session_for(chat_id, target)
          offer_recent_files(chat_id, session) if session
        end

        def offer_recent_files(chat_id, session)
          transcript = Transcript.for_cwd(session.cwd, root: transcript_root)
          paths = transcript.recent_files(RECENT_FILES_OFFERED)

          return say(chat_id, "No recently touched files found for #{session.label}.") if paths.empty?

          markup = { inline_keyboard: paths.map { |path| [file_button(path)] } }
          say(chat_id, "📄 Recent files in #{session.label}:", markup: markup)
        end

        def file_button(path)
          { text: File.basename(path)[0, 60],
            callback_data: @store.put({ "action" => "getfile", "path" => path }, ttl: 600) }
        end

        # No path restricted here, same as /run: anyone who can reach
        # this chat can already `cat` anything via a shell.
        def send_file(chat_id, path)
          expanded = File.expand_path(path)
          return say(chat_id, "No such file:\n\n`#{path}`") unless File.file?(expanded)

          @api.send_document(chat_id: chat_id, path: expanded)
        rescue Api::Error, SystemCallError, ArgumentError => e
          say(chat_id, "Couldn't send that file: #{@api.redact(e.message)}")
        end

        # Not necessarily an immediate reply, but whenever convenient — TTL 30 days, not a day.
        REPLY_TARGET_TTL = 30 * 86_400

        def remember_reply(chat_id, sent, session)
          id = sent.is_a?(Hash) ? sent["message_id"] : nil
          return unless id

          target = { "session_id" => session.id, "cwd" => session.cwd, "label" => session.label }
          @store.put(target, ttl: REPLY_TARGET_TTL, key: "reply:#{chat_id}:#{id}")
          @store.put(target, ttl: REPLY_TARGET_TTL, key: last_target_key(chat_id))
        end

        # Text sent without a reply goes to the session of the last message
        # the bot sent, so a back-and-forth with one agent needs no replies.
        def last_target_key(chat_id) = "last:#{chat_id}"

        def status(chat_id)
          sessions = registry.refresh.sessions
          backends = registry.available_backends.map(&:name).join(", ")

          say(chat_id, "Tabs: #{sessions.size}\nAgents: #{sessions.count(&:agent?)}\n" \
                       "Backends: #{backends.empty? ? 'none' : backends}\n" \
                       "Mode: #{@config.get('answers.away', false) ? '🚶 away' : '🪑 present'}\n" \
                       "Waiting for a reply: #{@pending ? @pending.size : 0}\n" \
                       "Destructive commands: #{passphrase.configured? ? '🔐 passphrase' : 'a tap'}")
        end

        # One message, once, and only where there's something to say.
        # Sent from the daemon on start rather than pushed at a moment
        # someone is deciding something else — this bot carries real
        # interruptions (an agent stopped, a permission is needed), and
        # spending that attention on a setting nobody has chosen yet is
        # how people learn to dismiss the ones that matter.
        def announce_passphrase(chat_id)
          return if passphrase.configured? || !offer_passphrase?
          return if @config.get("telegram.passphrase_notice_sent", false)

          key = @store.put({ "action" => "passphrase_wizard" }, ttl: 86_400)
          hush = @store.put({ "action" => "passphrase_never" }, ttl: 86_400)

          say(chat_id, "🔐 No passphrase set\n\nDestructive commands from this chat — `rm -rf ~`, " \
                       "`mkfs`, `dd` to a device, a fork bomb — ask for a tap on a button. A tap is " \
                       "something anyone holding this phone can do.",
              markup: { inline_keyboard: [[{ text: "🔐 Set a passphrase", callback_data: key },
                                            { text: "Not now", callback_data: hush }]] })

          @config.set("telegram.passphrase_notice_sent", true).save
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
          when "getfile" then send_file(chat_id, payload["path"])
          when "setting" then change_setting(chat_id, payload)
          when "menu_choice" then choose_menu_option(chat_id, payload)
          when "passphrase_wizard" then start_wizard(chat_id)
          when "passphrase_never" then stop_offering(chat_id)
          when "ask_question_choice" then answer_ask_user_question(chat_id, payload)
          when "disambiguate" then resolve_disambiguation(chat_id, payload)
          when "retry_attachment" then retry_attachment(chat_id, payload)
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

        def stop_offering(chat_id)
          @config.set("telegram.offer_passphrase", false).save
          say(chat_id, "Won't bring it up again. Destructive commands will keep asking for a tap, and " \
                       "`/settings` can still turn a passphrase on later.")
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
          session = registry.refresh.find(payload["session_id"])
          return say(chat_id, "That session is already closed.") unless session

          ok = registry.backend_for(session).send_text(session.id, payload["choice"].to_s)
          say(chat_id, ok ? "Chose \"#{payload['choice']}\" in #{session.label}." : "Couldn't send the choice.")
        end

        # Same mechanism as choose_menu_option: types the option number
        # straight into the pane. AskUserQuestion's answer never flows
        # through the hook — it's always been resolved by hand at the
        # terminal, and this just sends the same keystroke a human would.
        def answer_ask_user_question(chat_id, payload)
          session = registry.refresh.find(payload["session_id"])
          return say(chat_id, "That session is already closed.") unless session

          ok = registry.backend_for(session).send_text(session.id, payload["choice"].to_s)
          say(chat_id, ok ? "Sent to #{session.label}." : "Couldn't send the choice.")
        end

        def show_transcript(chat_id, payload)
          transcript = Transcript.new(payload["path"])
          return say(chat_id, "No transcript available.") unless transcript.exists?

          say_chunked(chat_id, "📄 #{payload['label']}\n\n", transcript.render)
        end

        def act_on_session(chat_id, payload)
          session = registry.refresh.find(payload["session_id"])
          return say(chat_id, "That session is already closed.") unless session

          case payload["action"]
          when "focus" then focus_session(chat_id, session)
          when "screen" then show_screen(chat_id, session)
          when "run" then execute(chat_id, session, payload["text"], show_result: !session.agent?,
                                  vetted: payload["vetted"] ? true : false)
          when "close_confirm" then say(chat_id, "Close #{session.label}?",
                                        markup: @keyboards.confirm("close", session))
          when "close" then close_session(chat_id, session)
          end
        end

        def focus_session(chat_id, session)
          registry.backend_for(session).focus(session.id)
          sent = say(chat_id, "Switched to #{session.label}.")
          remember_reply(chat_id, sent, session)
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
          registry.backend_for(session).capture(session.id, lines: lines)
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
          ok = registry.backend_for(session).close(session.id)
          say(chat_id, ok ? "Closed #{session.label}." : "Couldn't close it.")
        end

        def with_session(chat_id, number)
          id = @keyboards.session_for(chat_id, number.to_s.strip)
          return say(chat_id, "No such number — pull up the list again.") unless id

          session = registry.refresh.find(id)
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
