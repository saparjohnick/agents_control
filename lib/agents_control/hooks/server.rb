# frozen_string_literal: true

require "socket"
require "json"
require "securerandom"
require "open3"

module AgentsControl
  module Hooks
    # Receiver for events from agents.
    #
    # HTTP over bare sockets, not webrick: it left the stdlib in Ruby 3,
    # and pulling in a gem just to accept local POSTs isn't worth it. The
    # subset of the protocol needed — one request line, headers, a body
    # — fits in about fifty lines.
    #
    # Listens strictly on 127.0.0.1. The port must never be exposed
    # externally under any circumstances: anyone who could reach it
    # could grant the agent permission to run commands.
    #
    # The handler holds the connection open until a human answers — this
    # is exactly how a hook blocks the agent. So every connection gets
    # its own thread, and there can be as many as there are sessions
    # waiting at once.
    class Server
      HOST = "127.0.0.1"

      attr_reader :port, :secret

      def initialize(port: 0, secret: nil, logger: nil)
        @requested_port = port
        @secret = secret || SecureRandom.hex(16)
        @logger = logger
        @running = false
      end

      # The port is taken almost always for one reason: another
      # agents_control is already running. Same situation as a 409 from
      # Telegram — it won't resolve itself, and a raw backtrace explains nothing here.
      class PortBusy < AgentsControl::Error; end

      def start(&handler)
        @server = TCPServer.new(HOST, @requested_port)
        @port = @server.addr[1]
        @running = true

        @thread = Thread.new do
          accept_loop(&handler)
        end

        self
      rescue Errno::EADDRINUSE
        raise PortBusy, "port #{@requested_port} is taken#{occupant_hint}"
      end

      # "Something's already running somewhere" with no indication of
      # where is a useless message: finding the process becomes a manual
      # hunt. Name it right away.
      def occupant_hint
        # argv array, not a shell string: the port ultimately comes from
        # the user's own config, but there's no reason to trust a shell
        # to parse it correctly either.
        out, = Open3.capture3("lsof", "-nP", "-iTCP:#{@requested_port.to_i}", "-sTCP:LISTEN", "-t")
        pids = out.split.map(&:strip)
        return "" if pids.empty?

        " by process #{pids.join(', ')}. Stop it: agents_control stop"
      rescue StandardError
        ""
      end

      def url = "http://#{HOST}:#{port}"

      def stop
        @running = false
        @server&.close
        @thread&.kill
      end

      def wait = @thread&.join

      private

      def accept_loop(&handler)
        while @running
          begin
            socket = @server.accept
          rescue IOError, Errno::EBADF
            break # the socket was closed by stop
          end

          Thread.new(socket) { |connection| serve(connection, &handler) }
        end
      end

      def serve(socket, &handler)
        request = read_request(socket)
        return respond(socket, 400, {}) unless request

        return respond(socket, 403, {}) if from_browser?(request) || !authorized?(request)

        result = handler.call(request[:path], request[:body])
        respond(socket, 200, result || {})
      rescue StandardError => e
        log("handling failed: #{e.class}: #{e.message}")
        # An empty response means "no decision" — the agent continues as usual.
        # A failure on our end must not stop it.
        respond(socket, 200, {})
      ensure
        socket.close unless socket.closed?
      end

      def read_request(socket)
        request_line = socket.gets
        return nil if request_line.nil?

        path = request_line.split[1].to_s
        headers = read_headers(socket)
        length = headers["content-length"].to_i
        body = length.positive? ? socket.read(length).to_s : ""

        { path: path, headers: headers, body: parse(body) }
      end

      def read_headers(socket)
        headers = {}

        while (line = socket.gets) && line != "\r\n"
          key, value = line.split(":", 2)
          headers[key.to_s.strip.downcase] = value.to_s.strip
        end

        headers
      end

      def parse(body)
        body.empty? ? {} : JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      # The only thing that could reach the local port from outside the
      # machine is a page open in a browser: nothing stops it from
      # sending requests to 127.0.0.1. It doesn't know the secret, but a
      # cheap extra line of defense is still worth having.
      #
      # The browser sets the Origin header itself and a page can't forge
      # it. No agent ever sends it, so its presence is a reliable sign of
      # an outsider. Host is checked separately: this rules out DNS
      # spoofing, where a page addresses a name that resolves to loopback.
      def from_browser?(request)
        headers = request[:headers]
        return true if headers.key?("origin")

        host = headers["host"].to_s.split(":").first

        !["127.0.0.1", "localhost", "", nil].include?(host)
      end

      # A shared secret filters out stray requests from other local
      # programs. It's not protection against someone already logged in
      # as the same user — the only thing defending against that is the
      # port being local at all.
      def authorized?(request)
        return true if @secret.nil?

        provided = request[:headers]["authorization"].to_s.sub(/\ABearer\s+/i, "")

        # Constant-time comparison: the secret's length is already
        # known, but there's no reason to leak anything through an early
        # byte mismatch either.
        secure_compare(provided, @secret)
      end

      def secure_compare(given, expected)
        return false unless given.bytesize == expected.bytesize

        given.bytes.zip(expected.bytes).reduce(0) { |diff, (a, b)| diff | (a ^ b) }.zero?
      end

      def respond(socket, status, payload)
        body = JSON.generate(payload)

        socket.print(
          "HTTP/1.1 #{status} #{status == 200 ? 'OK' : 'Error'}\r\n" \
          "Content-Type: application/json\r\n" \
          "Content-Length: #{body.bytesize}\r\n" \
          "Connection: close\r\n\r\n#{body}"
        )
      rescue Errno::EPIPE, Errno::ECONNRESET
        # The agent gave up without waiting. Happens — not our concern.
      end

      def log(message) = @logger&.puts("[hooks] #{message}")
    end
  end
end
