# frozen_string_literal: true

require "test_helper"

module AgentsControl
  module Channels
    module Telegram
      class ApiTest < Minitest::Test
        TOKEN = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"

        def test_returns_result_on_success
          http = FakeHttp.new(FakeHttp.ok({ "username" => "my_bot" }))

          assert_equal({ "username" => "my_bot" }, Api.new(TOKEN, http: http).get_me)
        end

        # One token, one update reader. Looping further is pointless, so
        # this gets its own error type.
        def test_conflict_is_its_own_error
          http = FakeHttp.new(FakeHttp.fail(409, "Conflict: terminated by other getUpdates"))

          assert_raises(Api::Conflict) { Api.new(TOKEN, http: http).get_updates }
        end

        def test_rate_limit_carries_the_wait_time
          http = FakeHttp.new(FakeHttp.fail(429, "Too Many Requests",
                                            parameters: { retry_after: 17 }))

          error = assert_raises(Api::TooManyRequests) { Api.new(TOKEN, http: http).get_me }

          assert_equal 17, error.retry_after
        end

        # A closed laptop is a normal state, not a failure: fixed by retrying.
        def test_network_failure_becomes_unavailable
          http = FakeHttp.new(Http::NetworkError.new("connection reset"))

          assert_raises(Api::Unavailable) { Api.new(TOKEN, http: http).get_me }
        end

        def test_unparseable_body_is_reported_with_status
          http = FakeHttp.new(FakeHttp::Response.new("502", "<html>bad gateway</html>"))

          error = assert_raises(Api::Error) { Api.new(TOKEN, http: http).get_me }

          assert_includes error.message, "502"
        end

        # The token is part of the URL, so every trace of it must be
        # scrubbed — otherwise the secret rides along in the log with the
        # error text.
        def test_token_never_leaks_through_error_messages
          http = FakeHttp.new(FakeHttp.fail(400, "Bad Request for bot#{TOKEN}"))

          error = assert_raises(Api::Error) { Api.new(TOKEN, http: http).get_me }

          refute_includes error.message, TOKEN
          assert_includes error.message, "<token>"
        end

        def test_network_error_message_is_redacted_too
          http = FakeHttp.new(Http::NetworkError.new("couldn't reach bot#{TOKEN}"))

          error = assert_raises(Api::Unavailable) { Api.new(TOKEN, http: http).get_me }

          refute_includes error.message, TOKEN
        end

        # A malformed token (whitespace, control characters — bypassing
        # cli.rb's own shape check, e.g. via a hand-edited credentials
        # file) makes URI() embed the raw value in its own exception
        # message. That message is never touched at all, on purpose —
        # see the redact tests below for why a redaction pass isn't
        # trusted to catch every escaped form.
        def test_malformed_token_does_not_leak_through_uri_errors
          broken = "123456789:AA bad token with a space"

          error = assert_raises(Api::Error) { Api.new(broken, http: FakeHttp.new).get_me }

          refute_includes error.message, broken
        end

        # URI::InvalidURIError builds its message with `inspect`, which
        # escapes control characters (a tab becomes the two characters
        # `\t`) — a literal substring match alone would miss the token
        # in that form and let it straight through.
        def test_redact_catches_the_inspect_escaped_form_of_the_token
          token = "123456:ABCDEF\tGHIJ"

          redacted = Api.new(token).redact(token.inspect)

          refute_includes redacted, "ABCDEF"
          assert_includes redacted, "<token>"
        end

        def test_redact_leaves_ordinary_text_alone
          assert_equal "nothing secret here", Api.new(TOKEN).redact("nothing secret here")
        end

        # gsub against an empty pattern matches between every character —
        # an empty token must short-circuit, not turn every message into noise.
        def test_redact_with_an_empty_token_does_not_mangle_the_text
          assert_equal "some ordinary message", Api.new("").redact("some ordinary message")
        end

        # Long polling keeps the connection open; the network timeout
        # must be longer, or the client drops the connection right
        # before the server answers.
        def test_read_timeout_outlives_long_poll_window
          http = FakeHttp.new(FakeHttp.ok([]))

          Api.new(TOKEN, http: http).get_updates(timeout: 30)

          assert_operator http.calls.last[:read_timeout], :>, 30
        end

        def test_nil_parameters_are_not_sent
          http = FakeHttp.new(FakeHttp.ok({}))

          Api.new(TOKEN, http: http).send_message(chat_id: 1, text: "hello")

          refute_includes http.calls.last[:params].keys, :reply_markup
        end

        def test_markup_is_serialised_as_json
          http = FakeHttp.new(FakeHttp.ok({}))
          markup = { inline_keyboard: [[{ text: "yes", callback_data: "k" }]] }

          Api.new(TOKEN, http: http).send_message(chat_id: 1, text: "?", reply_markup: markup)

          assert_equal JSON.generate(markup), http.calls.last[:params][:reply_markup]
        end

        # A menu next to the input field instead of hunting through the chat for a list.
        def test_publishes_the_command_menu
          http = FakeHttp.new(FakeHttp.ok(true))

          Api.new(TOKEN, http: http).set_my_commands([["agents", "sessions"], ["tabs", "tabs"]])

          sent = JSON.parse(http.calls.last[:params][:commands])

          assert_equal [{ "command" => "agents", "description" => "sessions" },
                        { "command" => "tabs", "description" => "tabs" }], sent
        end

        def test_only_relevant_update_types_are_requested
          http = FakeHttp.new(FakeHttp.ok([]))

          Api.new(TOKEN, http: http).get_updates

          assert_equal %w[message callback_query], http.calls.last[:params][:allowed_updates]
        end

        # ── sendDocument ───────────────────────────────────────────────────

        def test_send_document_attaches_the_file_as_a_multipart_field
          Dir.mktmpdir do |dir|
            path = File.join(dir, "notes.txt")
            File.write(path, "hello")
            http = FakeHttp.new(FakeHttp.ok({}))

            Api.new(TOKEN, http: http).send_document(chat_id: 1, path: path)

            call = http.file_calls.last
            assert_equal "document", call[:field]
            assert_equal path, call[:path]
            assert_equal "notes.txt", call[:filename]
            assert_equal 1, call[:fields][:chat_id]
          end
        end

        def test_send_document_omits_a_nil_caption
          Dir.mktmpdir do |dir|
            path = File.join(dir, "notes.txt")
            File.write(path, "hello")
            http = FakeHttp.new(FakeHttp.ok({}))

            Api.new(TOKEN, http: http).send_document(chat_id: 1, path: path)

            refute_includes http.file_calls.last[:fields].keys, :caption
          end
        end

        # Checked before the file is ever read into memory for the
        # request body — Telegram's own cap, not ours to raise. A
        # truncated (sparse) file reaches the right size without
        # actually writing 50MB to disk for this one assertion.
        def test_send_document_refuses_a_file_too_large_to_upload
          Dir.mktmpdir do |dir|
            path = File.join(dir, "huge.bin")
            File.write(path, "")
            File.truncate(path, Api::MAX_UPLOAD_BYTES + 1)
            http = FakeHttp.new
            api = Api.new(TOKEN, http: http)

            error = assert_raises(Api::Error) { api.send_document(chat_id: 1, path: path) }

            assert_includes error.message, "larger than Telegram allows"
            assert_empty http.file_calls
          end
        end

        def test_send_document_network_failure_becomes_unavailable
          Dir.mktmpdir do |dir|
            path = File.join(dir, "notes.txt")
            File.write(path, "hello")
            http = FakeHttp.new(Http::NetworkError.new("connection reset"))

            assert_raises(Api::Unavailable) { Api.new(TOKEN, http: http).send_document(chat_id: 1, path: path) }
          end
        end
      end

      # The one piece of hand-rolled protocol code that never runs
      # through FakeHttp (it stands in for Http everywhere else in this
      # file) — exercised directly here instead.
      class HttpMultipartTest < Minitest::Test
        def test_body_frames_fields_and_the_file_with_the_boundary
          Dir.mktmpdir do |dir|
            path = File.join(dir, "notes.txt")
            File.write(path, "file bytes")

            body = Http.new.send(:multipart_body, "BOUND", { chat_id: 1 }, "document", path, "notes.txt")

            assert_includes body, "--BOUND\r\n"
            assert_includes body, "name=\"chat_id\"\r\n\r\n1\r\n"
            assert_includes body, "name=\"document\"; filename=\"notes.txt\"\r\n"
            assert_includes body, "file bytes"
            assert body.end_with?("--BOUND--\r\n")
          end
        end

        # A caption typed on a phone is ordinary UTF-8, often non-ASCII
        # — concatenating it onto the binary file bytes must not raise
        # Encoding::CompatibilityError.
        def test_body_accepts_a_non_ascii_field_value
          Dir.mktmpdir do |dir|
            path = File.join(dir, "notes.txt")
            File.write(path, "x")

            body = Http.new.send(:multipart_body, "BOUND", { caption: "привет" }, "document", path, "notes.txt")

            assert_includes body, "привет".b
          end
        end

        def test_body_escapes_a_quote_in_the_filename
          Dir.mktmpdir do |dir|
            path = File.join(dir, "notes.txt")
            File.write(path, "x")

            body = Http.new.send(:multipart_body, "BOUND", {}, "document", path, 'evil".txt')

            refute_includes body, 'filename="evil".txt"'
            assert_includes body, "filename=\"evil'.txt\""
          end
        end
      end
    end
  end
end
