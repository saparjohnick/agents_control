# frozen_string_literal: true

module AgentsControl
  module Channels
    module Telegram
      # Telegram as a notification and reply channel.
      #
      # Deliberately split from Router: Router parses incoming traffic,
      # Channel produces outgoing traffic. Both share the same Store,
      # because a button physically can't carry more than 64 bytes, and
      # the whole content of an action lives on our side anyway.
      class Channel < Channels::Base
        def initialize(api:, store:, config:, registry: nil)
          @api = api
          @store = store
          @config = config
          @registry = registry
        end

        def ready? = !chats.empty?

        # Notify, expecting nothing back.
        def notify(event)
          return notify_ask_user_question(event) if event.ask_user_question?

          broadcast(headline(event), event: event)
        end

        # Ask and wait. Blocks the calling thread — and through it, the
        # agent itself, which is holding the hook's HTTP request open.
        #
        # Never called with an AskUserQuestion event: Dispatcher routes
        # those through notify instead, since their answer never flows
        # through a hook response in the first place.
        def ask(event, pending:, timeout:)
          pending.ask(event, timeout: timeout) do |question_id|
            broadcast(question_text(event), markup: buttons_for(event, question_id),
                                            event: event, question_id: question_id)
          end
        end

        private

        def registry = @registry ||= Registry.new

        def chats = Array(@config.get("telegram.allowed_chat_ids", []))

        # Headroom for the continuation marker ("↪️ 2/3\n\n"), which is
        # appended to a chunk after Chunker has already measured its length.
        MARKER_HEADROOM = 20

        # Buttons and the "message → session" link are attached to every
        # chunk: a reply can target any of them, not just the last one.
        def broadcast(text, markup: nil, event: nil, question_id: nil)
          chunks = Chunker.split(text, limit: Chunker::MAX_MESSAGE - MARKER_HEADROOM)
          chunks = [""] if chunks.empty?

          chats.each do |chat_id|
            chunks.each_with_index do |chunk, i|
              body = "#{continuation_marker(i, chunks.size)}#{chunk}"
              sent = send_formatted(chat_id, body, i == chunks.size - 1 ? markup : nil)
              remember(chat_id, sent, event, question_id) if event
            end
          rescue Api::Error
            # One unreachable chat must not affect the rest, and
            # definitely must not take down the thread holding the agent.
            next
          end
        end

        def continuation_marker(index, total) = index.zero? ? "" : "↪️ #{index + 1}/#{total}\n\n"

        # MarkdownV2 is strict: one incorrectly escaped period and
        # Telegram rejects the whole send, so there's a fallback to plain
        # text. Losing a message to a formatting error isn't an option:
        # on the other end is a thread holding the hook's HTTP request open.
        def send_formatted(chat_id, text, markup)
          @api.send_message(chat_id: chat_id, text: Markdown.convert(text),
                            reply_markup: markup, parse_mode: "MarkdownV2")
        rescue Api::Error => e
          raise unless e.message.include?("can't parse entities")

          @api.send_message(chat_id: chat_id, text: text, reply_markup: markup)
        end

        # The link between a chat message and the session it's about.
        #
        # Needed so an agent's message can just be replied to, without
        # figuring out tab numbers. It outlives the question itself:
        # replying to an old message still makes sense even after the
        # agent has stopped waiting.
        #
        # TTL is 30 days, not a day: the whole point is answering not
        # right away but whenever convenient, and an old message has to stay addressable.
        REPLY_TARGET_TTL = 30 * 86_400

        def remember(chat_id, sent, event, question_id)
          id = sent.is_a?(Hash) ? sent["message_id"] : nil
          return unless id

          @store.put({ "session_id" => event.session_id, "question_id" => question_id,
                       "cwd" => event.cwd, "label" => event.label },
                     ttl: REPLY_TARGET_TTL, key: "reply:#{chat_id}:#{id}")
        end

        # A short session tag in the header. Needed so that in a chat
        # with several agents it's clear which one a message belongs to
        # — especially when they work in the same directory and the
        # label is identical.
        def tag(event) = "##{event.session_id.to_s.delete('-')[0, 4]}"

        def headline(event)
          case event.kind
          when :error then "🔴 #{event.label} #{tag(event)}\n#{event.text}"
          when :finished then "✅ #{event.label} #{tag(event)} — done"
          else "🔔 #{event.label} #{tag(event)}\n#{event.summary}"
          end
        end

        # The reply hint lives right in the message: nobody's going to
        # look it up in the help text.
        def question_text(event)
          head = case event.kind
                 when :needs_permission
                   "🔐 #{event.label} #{tag(event)} needs permission\n\n`#{event.summary}`"
                 else
                   "❓ #{event.label} #{tag(event)} is waiting for a reply\n\n#{event.text.to_s}"
                 end

          "#{head}\n\n↩️ reply to this message to write to the agent"
        end

        def buttons_for(event, question_id)
          rows = action_rows(event, question_id)
          rows << [context_button(event, question_id)]

          { inline_keyboard: rows }
        end

        def action_rows(event, question_id)
          event.kind == :needs_permission ? permission_rows(question_id) : input_rows(question_id)
        end

        def permission_rows(question_id)
          [
            [answer_button("✅ Allow", question_id, kind: :allow),
             answer_button("❌ Deny", question_id, kind: :deny)],
            [answer_button("✅ Allow and don't ask again", question_id,
                           kind: :allow, remember: true)]
          ]
        end

        def input_rows(question_id)
          [
            [answer_button("▶️ Continue", question_id, kind: :text, text: "Continue."),
             answer_button("⏹ Stop", question_id, kind: :text, text: "Stop and wait for me.")],
            [{ text: "✍️ Answer in my own words",
               callback_data: @store.put({ "action" => "compose", "question_id" => question_id },
                                         ttl: ttl) }]
          ]
        end

        # Show the tail of the conversation — for when a single line
        # doesn't make it clear what's going on. Context shouldn't be
        # dumped by default: it's a tool for when in doubt, not a
        # mandatory part of every notification.
        def context_button(event, _question_id)
          {
            text: "📄 context",
            callback_data: @store.put({ "action" => "transcript",
                                        "path" => event.transcript_path,
                                        "label" => event.label }, ttl: ttl)
          }
        end

        def answer_button(text, question_id, kind:, remember: false, text_value: nil, **extra)
          payload = {
            "action" => "answer",
            "question_id" => question_id,
            "reply" => { "kind" => kind.to_s, "remember" => remember,
                         "text" => extra[:text] || text_value }
          }

          { text: text, callback_data: @store.put(payload, ttl: ttl) }
        end

        def ttl = @config.get("answers.reply_timeout", 600) + 300

        # ── AskUserQuestion ────────────────────────────────────────────

        # This never blocks the hook and never carries a question_id:
        # the answer doesn't come back as a hook decision, it gets typed
        # straight into the terminal — by a button tap (ask_question_choice,
        # handled in Router) or by replying with free text (already
        # routed there by Router#type_into_session, since there's no
        # pending question tied to this message for it to be mistaken for).
        def notify_ask_user_question(event)
          text = "❓ #{event.label} #{tag(event)}\n\n```\n#{event.summary}\n```\n\n" \
                 "↩️ reply to this message to answer in your own words"

          rows = option_rows(event)
          rows << [context_button(event, nil)]

          broadcast(text, markup: { inline_keyboard: rows }, event: event)
        end

        # Only offered when there's exactly one question and exactly one
        # matching terminal session for its cwd. With more than one
        # question we don't know whether the terminal expects them
        # answered one at a time or needs a final submit; with an
        # ambiguous cwd we don't know which pane to type into. Both
        # cases fall back to no option buttons — replying still works either way.
        def option_rows(event)
          questions = Array(event.tool_input.is_a?(Hash) ? event.tool_input["questions"] : nil)
          return [] unless questions.size == 1

          session = resolve_session(event)
          return [] unless session

          option_buttons(session, questions.first)
        end

        def resolve_session(event)
          matches = registry.refresh.agents.select { |s| s.cwd == event.cwd && !s.terminalless? }
          matches.size == 1 ? matches.first : nil
        end

        # Options that read as an open-ended "type your own answer"
        # invitation rather than a concrete choice get skipped here —
        # tapping a button for one would be meaningless, since there's
        # nothing to type into the terminal on the user's behalf.
        # Replying with free text already covers this case regardless.
        OPEN_ENDED_OPTION = /\b(other|something else|none of (?:these|the above)|custom|
                              explain|describe|my own|not (?:listed|here))\b/xi

        def option_buttons(session, question)
          Array(question["options"]).each_with_index.filter_map do |option, index|
            next if open_ended?(option)

            [{ text: "#{index + 1}. #{option['label']}"[0, 60],
               callback_data: @store.put({ "action" => "ask_question_choice",
                                           "session_id" => session.id, "choice" => index + 1 },
                                         ttl: ttl) }]
          end
        end

        def open_ended?(option) = "#{option['label']} #{option['description']}".match?(OPEN_ENDED_OPTION)
      end
    end
  end
end
