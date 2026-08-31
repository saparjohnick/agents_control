# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"

module AgentsControl
  # State that survives a daemon restart.
  #
  # Needed for two reasons at once:
  #
  #   1. Telegram limits button `callback_data` to 64 bytes. A session
  #      identifier won't fit there, let alone an action's text — a button
  #      carries only a short key, and the action itself lives here.
  #   2. While the owner is out, the daemon can crash and come back up.
  #      Pending questions have to survive that, or the agent is left
  #      waiting forever.
  #
  # There are dozens of records here, not millions, and only one process
  # writes them — so an atomically-replaced file and a mutex, not a database.
  class Store
    DEFAULT_TTL = 3600

    def self.path
      base = ENV["XDG_STATE_HOME"] || File.expand_path("~/.local/state")
      File.join(base, "agents_control", "store.json")
    end

    attr_reader :path

    def initialize(path: self.class.path, clock: -> { Time.now.to_i })
      @path = path
      @clock = clock
      @mutex = Mutex.new
    end

    # Short random key for a button. Eight base36 characters is ~41 bits,
    # which is plenty: keys live minutes and are checked one at a time.
    def put(value, ttl: DEFAULT_TTL, key: nil)
      key ||= SecureRandom.alphanumeric(8).downcase

      write do |data|
        data[key] = { "value" => value, "expires_at" => now + ttl }
      end

      key
    end

    def get(key)
      entry = read[key]
      return nil if entry.nil? || expired?(entry)

      entry["value"]
    end

    # Take the value and delete it in the same step.
    #
    # This is exactly how a button press is handled: Telegram redelivers
    # the callback if the connection drops, and a finger can tap twice.
    # The first call gets the value, every call after gets nil, and the
    # action never runs a second time. The check and the delete happen
    # under one mutex, or two simultaneous presses could both see the value.
    # The value has to come back as the block's result, not via `return`:
    # an early return would unwind past the file write, the delete would
    # never reach disk, and the button would fire again after a restart.
    def take(key)
      write do |data|
        entry = data.delete(key)

        entry.nil? || expired?(entry) ? nil : entry["value"]
      end
    end

    def delete(key)
      write { |data| data.delete(key) }
    end

    # All live records — for recovering state after a restart.
    def all
      read.reject { |_key, entry| expired?(entry) }
           .transform_values { |entry| entry["value"] }
    end

    def prune
      write { |data| data.reject! { |_key, entry| expired?(entry) } }
    end

    private

    def now = @clock.call

    def expired?(entry) = entry["expires_at"].to_i <= now

    def read
      @mutex.owned? ? load_file : @mutex.synchronize { load_file }
    end

    def write
      @mutex.synchronize do
        data = load_file
        result = yield(data)
        save_file(data)
        result
      end
    end

    def load_file
      return {} unless File.exist?(path)

      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError, Errno::ENOENT
      # A corrupt file must not keep the daemon from starting. Losing
      # pending questions is unfortunate, but failing to start at all is
      # worse — the agent would be left blocked with no way to answer.
      {}
    end

    # Replace via rename: a process reading the file at that moment sees
    # either the whole old version or the whole new one, never half of either.
    def save_file(data)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Process.pid}.tmp"

      File.write(temporary, JSON.generate(data))
      File.chmod(0o600, temporary)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end
  end
end
