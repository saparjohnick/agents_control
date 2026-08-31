# frozen_string_literal: true

require "test_helper"
require "net/http"

module AgentsControl
  module Hooks
    class ServerTest < Minitest::Test
      def setup
        @server = Server.new(port: 0, secret: "s3cret")
      end

      def teardown = @server.stop

      def test_serves_a_decision_back_to_the_agent
        start { |_path, payload| { "echo" => payload["hook_event_name"] } }

        assert_equal({ "echo" => "Stop" }, post("/Stop", Fixtures::HOOK_STOP))
      end

      def test_path_identifies_the_event
        seen = nil
        start { |path, _payload| seen = path; {} }

        post("/PermissionRequest", Fixtures::HOOK_PERMISSION)

        assert_equal "/PermissionRequest", seen
      end

      # The port is local, but local doesn't mean unreachable: a page
      # open in a browser can knock on it too.
      def test_rejects_requests_without_the_secret
        start { |_path, _payload| { "should" => "never arrive" } }

        assert_equal 403, raw_post("/Stop", Fixtures::HOOK_STOP, secret: nil).code.to_i
      end

      def test_rejects_a_wrong_secret
        start { |_path, _payload| {} }

        assert_equal 403, raw_post("/Stop", Fixtures::HOOK_STOP, secret: "wrong").code.to_i
      end

      # The only thing that can reach the local port from outside the
      # machine is a page open in a browser. The browser sets Origin
      # itself, and a page can't forge it; no agent ever sends this header.
      def test_rejects_anything_carrying_an_origin
        start { |_path, _payload| { "should" => "never arrive" } }

        response = raw_post("/Stop", Fixtures::HOOK_STOP,
                            headers: { "Origin" => "https://evil.example" })

        assert_equal 403, response.code.to_i
      end

      # DNS spoofing: a page addresses a name that resolves to loopback.
      def test_rejects_a_foreign_host_header
        start { |_path, _payload| {} }

        response = raw_post("/Stop", Fixtures::HOOK_STOP,
                            headers: { "Host" => "evil.example" })

        assert_equal 403, response.code.to_i
      end

      def test_accepts_localhost_by_name
        start { |_path, _payload| { "ok" => true } }

        response = raw_post("/Stop", Fixtures::HOOK_STOP,
                            headers: { "Host" => "localhost:#{@server.port}" })

        assert_equal 200, response.code.to_i
      end

      # A failure on our end must not stop the agent: it gets an empty
      # decision back and continues on as though we weren't there.
      def test_handler_failure_still_answers_with_an_empty_decision
        start { |_path, _payload| raise "handler fell over" }

        assert_empty post("/Stop", Fixtures::HOOK_STOP)
      end

      def test_broken_json_does_not_kill_the_connection
        start { |_path, payload| { "received" => payload } }

        response = raw_post_body("/Stop", "{this is not json")

        assert_equal 200, response.code.to_i
      end

      # This is exactly how a hook holds the agent: the connection
      # doesn't close until a human answers.
      def test_connection_stays_open_while_the_handler_waits
        start do |_path, _payload|
          sleep(0.4)
          { "decision" => "block", "reason" => "waited it out" }
        end

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = post("/Stop", Fixtures::HOOK_STOP)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_equal "waited it out", result["reason"]
        assert_operator elapsed, :>=, 0.4
      end

      # Several sessions can wait for an answer at the same time.
      def test_serves_several_waiting_agents_at_once
        start do |_path, payload|
          sleep(0.3)
          { "session" => payload["session_id"] }
        end

        results = 4.times.map do |i|
          Thread.new { post("/Stop", Fixtures::HOOK_STOP.merge("session_id" => "s#{i}")) }
        end.map(&:value)

        assert_equal %w[s0 s1 s2 s3], results.map { |r| r["session"] }.sort
      end

      def test_binds_only_to_loopback
        start { |_path, _payload| {} }

        assert_match(%r{\Ahttp://127\.0\.0\.1:\d+\z}, @server.url)
      end

      private

      def start(&handler) = @server.start(&handler)

      def post(path, payload)
        JSON.parse(raw_post(path, payload).body)
      end

      def raw_post(path, payload, secret: "s3cret", headers: {})
        raw_post_body(path, JSON.generate(payload), secret: secret, headers: headers)
      end

      def raw_post_body(path, body, secret: "s3cret", headers: {})
        uri = URI("#{@server.url}#{path}")
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = "application/json"
        request["Authorization"] = "Bearer #{secret}" if secret
        headers.each { |key, value| request[key] = value }
        request.body = body

        Net::HTTP.start(uri.host, uri.port, read_timeout: 10) { |http| http.request(request) }
      end
    end
  end
end
