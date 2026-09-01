# frozen_string_literal: true

module AgentsControl
  module Channels
    module Telegram
      # Building inline keyboards and rendering lists.
      #
      # The key Bot API constraint: a button's `callback_data` can't
      # exceed **64 bytes**. An iTerm2 session UUID alone (36 characters,
      # plus an action, plus separators) already cuts it close, let alone
      # a path or a command.
      #
      # So a button carries only a short key from Store, and the actual
      # action lives on the daemon's side. Side benefit: the key is
      # one-shot, and pressing the same button twice does nothing the
      # second time.
      class Keyboards
        # How long a button lives. It has to survive a quick trip out,
        # but not hang around forever: a stale message shouldn't stay a
        # working remote control.
        ACTION_TTL = 3600

        # Numbers, unlike buttons, are typed by hand into later messages
        # — /run N doesn't stay tied to the message the list came in on,
        # so it has to survive much longer than a single quick trip out.
        # A closed session is still handled gracefully regardless of how
        # long the mapping lives (find just returns nil), so the only
        # cost of a longer TTL is a number eventually pointing at a tab
        # that's since closed — a clear, expected error either way.
        LIST_TTL = 86_400

        def initialize(store:)
          @store = store
        end

        # Buttons under a single session's card.
        def session_actions(session)
          rows = [[
            button("🎯 focus", action: "focus", session: session),
            button("👁 screen", action: "screen", session: session)
          ]]

          # Closing a tab goes through confirmation: a mistap on a phone is too easy.
          rows << [button("✖️ close", action: "close_confirm", session: session)] unless session.terminalless?

          { inline_keyboard: rows }
        end

        def confirm(action, session, label: "Yes, close it")
          {
            inline_keyboard: [[
              button("⚠️ #{label}", action: action, session: session),
              button("cancel", action: "cancel", session: session)
            ]]
          }
        end

        def list_actions
          { inline_keyboard: [[
            { text: "🤖 agents", callback_data: put(action: "list_agents") },
            { text: "📋 all tabs", callback_data: put(action: "list_tabs") }
          ]] }
        end

        # Buttons under /start and /help — the full command list isn't
        # always visible in the Telegram UI (the menu button is easy to
        # miss among everything else), so this keeps it available at any
        # moment right in the message.
        def main_menu
          { inline_keyboard: [
            [{ text: "🤖 agents", callback_data: put(action: "list_agents") },
             { text: "📋 all tabs", callback_data: put(action: "list_tabs") }],
            [{ text: "📊 status", callback_data: put(action: "status") },
             { text: "⚙️ settings", callback_data: put(action: "show_settings") }]
          ] }
        end

        # A list with short numbers: commands like `/run 2 ls` address
        # sessions by them later.
        #
        # Numbers are assigned against the full session list (universe),
        # not the displayed subset — "All tabs" and "Agents" both number
        # against the same universe, so a session keeps the same number
        # in either view as long as the set of tabs hasn't changed. An
        # /run with a remembered number must always hit the session the
        # human actually saw, never a different one that happened to
        # land on the same row in a shorter, filtered list.
        def render_list(sessions, chat_id:, title:, universe: sessions)
          numbers = numbered(universe)
          @store.put(numbers.invert, ttl: LIST_TTL, key: index_key(chat_id))

          lines = sessions.map do |session|
            "#{numbers[session.id].to_s.rjust(2)}. #{marker(session)} #{describe(session)}"
          end

          ([title, ""] + lines).join("\n")
        end

        def session_for(chat_id, number)
          map = @store.get(index_key(chat_id)) || {}

          map[number.to_s]
        end

        private

        def index_key(chat_id) = "index:#{chat_id}"

        # session.id => "1".."N", in the order of the full session list.
        def numbered(universe)
          universe.each_with_index.to_h { |session, position| [session.id, (position + 1).to_s] }
        end

        def button(text, action:, session:)
          { text: text, callback_data: put(action: action, session_id: session.id) }
        end

        def put(payload) = @store.put(payload, ttl: ACTION_TTL)

        def marker(session)
          return "⏳" if session.processing?
          return "🖥" if session.terminalless?
          return "▸" if session.at_shell_prompt?

          "·"
        end

        def describe(session)
          parts = [session.agent ? session.agent.to_s : (session.foreground_command || "—")]
          parts << session.label
          parts << (session.terminalless? ? "vscode" : session.tty.to_s.sub(%r{\A/dev/}, ""))

          parts.join(" · ")
        end
      end
    end
  end
end
