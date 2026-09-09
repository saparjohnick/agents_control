# frozen_string_literal: true

require "net/http"
require "openssl"
require "timeout"
require "json"
require "uri"

module AgentsControl
  module Channels
    module Telegram
      # A thin Bot API client built on the stdlib.
      #
      # Deliberately gem-free: `net/http` covers everything needed, and
      # an extra dependency in a tool installed with a single command
      # costs more than the lines it would save.
      #
      # The token is part of the URL, so any trace of a request —
      # exception message, log, debug output — must go through redact.
      # Otherwise the secret leaks somewhere nobody meant to put it.
      class Api
        HOST = "api.telegram.org"

        # Telegram requires answering a button press within 10 seconds,
        # or it stays stuck in the interface. Regular calls are kept
        # noticeably shorter than that.
        CALL_TIMEOUT = 8

        # A phone on a train uploading a screen recording is a slow
        # request that's still working, not a stuck one.
        DOWNLOAD_TIMEOUT = 120

        Error = Class.new(AgentsControl::Error)

        # Another process is already reading updates with this same
        # token. This doesn't resolve itself: one instance per token is required.
        Conflict = Class.new(Error)

        # Too many requests. The response carries retry_after — how long to wait.
        class TooManyRequests < Error
          attr_reader :retry_after

          def initialize(message, retry_after)
            super(message)
            @retry_after = retry_after
          end
        end

        # The network dropped. Unlike other errors, this is an expected
        # state for a laptop that got closed and carried off; it's fixed
        # by retrying, not by stopping.
        Unavailable = Class.new(Error)

        def initialize(token, http: nil)
          @token = token
          @http = http || Http.new
        end

        def get_me = call("getMe")

        # timeout here means long polling: the connection stays open
        # until an update shows up. The network timeout has to be
        # noticeably longer, or the client would drop the connection
        # right as the server was about to answer.
        def get_updates(offset: nil, timeout: 30)
          call(
            "getUpdates",
            { offset: offset, timeout: timeout, allowed_updates: %w[message callback_query] },
            read_timeout: timeout + 15
          )
        end

        # Two steps by design on Telegram's side: getFile resolves a
        # file_id to a path that's valid for about an hour, and the
        # bytes come from a different host prefix.
        def file_path_for(file_id)
          call("getFile", { file_id: file_id })["file_path"]
        end

        # Streams to disk rather than through memory: a 20MB video read
        # into a String would sit in the daemon's heap for as long as
        # Ruby felt like keeping it.
        #
        # The download URL carries the token in its path, which is why
        # this method builds it and nothing else ever sees it — no
        # caller, no log line, no message back to the chat.
        def download(file_path, to:, max_bytes: nil)
          @http.get_to_file(file_url_for(file_path), to, read_timeout: DOWNLOAD_TIMEOUT, max_bytes: max_bytes)
        rescue Http::NetworkError => e
          raise Unavailable, redact(e.message)
        end

        def send_message(chat_id:, text:, reply_markup: nil, parse_mode: nil)
          call("sendMessage", {
                 chat_id: chat_id, text: text, parse_mode: parse_mode,
                 reply_markup: reply_markup && JSON.generate(reply_markup)
               })
        end

        def edit_message_text(chat_id:, message_id:, text:, reply_markup: nil)
          call("editMessageText", {
                 chat_id: chat_id, message_id: message_id, text: text,
                 reply_markup: reply_markup && JSON.generate(reply_markup)
               })
        end

        # The command menu in the Telegram UI: a button next to the
        # input field instead of hunting through the chat for a list.
        # Best-effort on purpose: a passphrase typed into a chat is
        # deleted the moment it's read, and a bot that can't delete it
        # (too old, permissions) must still not leave the command it
        # was unlocking half-done.
        def delete_message(chat_id:, message_id:)
          call("deleteMessage", chat_id: chat_id, message_id: message_id)
        rescue Error, Unavailable
          false
        end

        def set_my_commands(commands)
          payload = commands.map { |name, description| { command: name, description: description } }

          call("setMyCommands", { commands: JSON.generate(payload) })
        end

        def answer_callback_query(id, text: nil, show_alert: false)
          call("answerCallbackQuery", { callback_query_id: id, text: text, show_alert: show_alert })
        end

        # Strip the token out of arbitrary text before logging it.
        #
        # Matches both the literal value and its `inspect`-escaped form
        # (control characters like a tab become the two characters
        # `\t`): `URI::InvalidURIError`'s message is built with
        # `inspect`, so a plain literal match alone would miss the token
        # whenever it contains anything `inspect` escapes, and let it
        # straight through into a log.
        #
        # An empty token is guarded separately: `gsub` against an empty
        # pattern matches between every character, turning any message
        # into unreadable noise instead of leaving it untouched.
        def redact(text)
          return text.to_s if @token.to_s.empty?

          text.to_s.gsub(Regexp.union(@token.to_s, escaped_token), "<token>")
        end

        private

        def escaped_token = @token.to_s.inspect[1..-2]

        def call(method, params = {}, read_timeout: CALL_TIMEOUT)
          response = @http.post(url_for(method), compact(params), read_timeout: read_timeout)
          parse(response, method)
        rescue Http::NetworkError => e
          raise Unavailable, redact(e.message)
        rescue URI::InvalidURIError
          # Don't even try to redact this one: the token sits inside a
          # URI, escaped, and a redaction pass that turned out wrong
          # would be worse than a message with none of the URI in it at all.
          raise Error, "#{method}: token is not valid for a URL (unexpected characters)"
        end

        def url_for(method) = URI("https://#{HOST}/bot#{@token}/#{method}")

        # Telegram serves file bytes from /file/bot<token>/<path>.
        # Escaped per path segment: the path comes back from the API
        # and gets to decide part of a URL, so it doesn't get to smuggle
        # a "?" or a "../" into one.
        def file_url_for(file_path)
          segments = file_path.to_s.split("/").reject(&:empty?).map { |part| URI::DEFAULT_PARSER.escape(part) }
          raise Error, "getFile: refusing a path that escapes its directory" if segments.any? { |s| s == ".." }

          URI("https://#{HOST}/file/bot#{@token}/#{segments.join('/')}")
        end

        # Drop nil fields: Telegram treats them as values that were actually passed.
        def compact(params) = params.compact

        def parse(response, method)
          body = JSON.parse(response.body)
          return body["result"] if body["ok"]

          raise_api_error(body, method)
        rescue JSON::ParserError
          raise Error, "#{method}: unrecognized response (HTTP #{response.code})"
        end

        def raise_api_error(body, method)
          description = redact(body["description"].to_s)
          retry_after = body.dig("parameters", "retry_after")

          case body["error_code"]
          when 409 then raise Conflict, "#{method}: another process is already reading updates"
          when 429 then raise TooManyRequests.new("#{method}: too many requests", retry_after.to_i)
          else raise Error, "#{method}: #{description}"
          end
        end
      end

      # Transport is split out separately so tests never hit the network.
      class Http
        NetworkError = Class.new(StandardError)

        # Written straight to the open file as chunks arrive. The caller
        # owns the path; a failure part-way leaves a partial file, which
        # is why callers download to a temporary name and rename.
        # max_bytes is counted as the bytes arrive, not taken from a
        # header or from what the sender said the file weighs: both are
        # claims, and the disk fills either way if they're wrong.
        def get_to_file(uri, path, read_timeout:, max_bytes: nil)
          Net::HTTP.start(uri.host, uri.port,
                          use_ssl: true, open_timeout: 10, read_timeout: read_timeout) do |http|
            http.request(Net::HTTP::Get.new(uri)) do |response|
              raise NetworkError, "download failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)

              written = 0
              File.open(path, "wb") do |file|
                response.read_body do |chunk|
                  written += chunk.bytesize
                  raise NetworkError, "the file is larger than expected" if max_bytes && written > max_bytes

                  file.write(chunk)
                end
              end
            end
          end

          path
        rescue SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError, SocketError => e
          raise NetworkError, e.message
        end

        def post(uri, params, read_timeout:)
          request = Net::HTTP::Post.new(uri)
          request.set_form_data(params)

          Net::HTTP.start(uri.host, uri.port,
                          use_ssl: true, open_timeout: 10, read_timeout: read_timeout) do |http|
            http.request(request)
          end
        rescue *NETWORK_ERRORS => e
          raise NetworkError, e.message
        end

        NETWORK_ERRORS = [
          Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
          Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EPIPE,
          SocketError, Timeout::Error, OpenSSL::SSL::SSLError, IOError
        ].freeze
      end
    end
  end
end
