# frozen_string_literal: true

require "yaml"
require "fileutils"

module AgentsControl
  # YAML settings at the XDG path.
  #
  # Only non-secret data lives here. The bot token lives in the Keychain
  # or libsecret and never lands in this file — the tool is meant to be
  # published openly, and the config has to be safe to show anyone.
  class Config
    DEFAULTS = {
      "telegram" => {
        # While the list is empty, the bot answers nobody. Filled in by
        # the setup wizard. Without this filter, anyone who found the bot
        # could approve command execution on this machine.
        "allowed_chat_ids" => [],
        "poll_timeout" => 30
      },
      "answers" => {
        # Answering "continue" on the user's behalf is safe.
        "auto_continue" => true,
        # Granting the agent a tool on the user's behalf is not.
        # Deliberately two separate settings: merged into one, they'd
        # produce an agent that approves itself everything while nobody
        # is watching.
        "auto_approve_permissions" => false,
        # Whether to intercept agent questions at all. While a human is
        # at the keyboard this only gets in the way: they'll answer in
        # the terminal faster, and a busy hook keeps the dialog from
        # ever reaching the screen. Turned on with the /away command.
        "away" => false,
        # Whether to also mirror questions to Telegram when interception
        # is off.
        "notify_when_present" => true,
        # How long to wait for a Telegram reply before declining. Claude
        # Code holds the hook open longer than the documented 600
        # seconds, so this upper bound is ours, not its.
        "reply_timeout" => 900,
        # Automatically type a continuation once a session has hit a
        # rate limit and the limit has reset. Exactly as safe as
        # auto_continue — grants the agent no new permissions, just
        # clears idle time nobody got around to clearing by hand.
        "auto_resume_after_limit" => true,
        "resume_message" => "Continue where you left off — the previous attempt was rate limited.",
        # Never auto-approved, no matter what the settings above say.
        "never_auto_approve" => [
          "rm -rf",
          "git push --force",
          "curl | sh",
          "curl | bash",
          ".env"
        ]
      },
      "anchors" => {
        "enabled" => false,
        "mode" => "headless",
        # The five-hour window is shared across the account, but weekly
        # limits are tracked per model family — so anchoring with a
        # cheap model is the better deal.
        "model" => "haiku",
        "schedule" => ["07:00", "12:00", "17:00"],
        "days" => %w[mon tue wed thu fri],
        "skip_if_window_active" => true
      },
      "terminal" => {
        # Empty means auto-detect. Otherwise iterm2 / tmux / none.
        "backend" => nil,
        "context_lines" => 80,
        # Watch for a session's local CLI menus (model switch, folder
        # trust) on screen and forward them to Telegram. Hooks can't see
        # these — they're the CLI's own response to a human command, not
        # a decision made by the agent.
        "watch_menus" => true,
        "menu_poll_interval" => 20,
        "rate_limit_poll_interval" => 60
      }
    }.freeze

    def self.path
      base = ENV["XDG_CONFIG_HOME"] || File.expand_path("~/.config")
      File.join(base, "agents_control", "config.yml")
    end

    def self.load(path = self.path)
      new(read(path), path: path)
    end

    def self.read(path)
      return {} unless File.exist?(path)

      YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
    rescue Psych::SyntaxError
      # A broken config must not keep the daemon from starting: fall
      # back to defaults and flag it in doctor.
      {}
    end

    attr_reader :path

    def initialize(data = {}, path: self.class.path)
      @data = deep_merge(DEFAULTS, stringify(data))
      @path = path
    end

    # Reads via a dotted path: config.get("anchors.model").
    def get(key, default = nil)
      key.to_s.split(".").reduce(@data) do |node, part|
        return default unless node.is_a?(Hash) && node.key?(part)

        node[part]
      end
    end

    def set(key, value)
      parts = key.to_s.split(".")
      leaf = parts[0..-2].reduce(@data) { |node, part| node[part] ||= {} }
      leaf[parts.last] = value
      self
    end

    # Written through a temp file, chmod'd before the rename: the file
    # may contain the allowed-chats list, and it must never be
    # world-readable even for the brief moment between creation and the
    # permission change landing on the final path.
    def save
      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.#{Process.pid}.tmp"

      File.write(temporary, YAML.dump(@data))
      File.chmod(0o600, temporary)
      File.rename(temporary, path)
      self
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    def to_h = @data

    private

    # Hash#merge only copies the top level: nested hashes stay the same
    # objects as in DEFAULTS. Without a deep copy, the first `set` would
    # edit the defaults for every other instance at once — in the daemon
    # that would mean the allowed-chats list leaking between config reloads.
    def deep_merge(base, other)
      result = deep_dup(base)

      other.each do |key, value|
        result[key] = if result[key].is_a?(Hash) && value.is_a?(Hash)
                        deep_merge(result[key], value)
                      else
                        deep_dup(value)
                      end
      end

      result
    end

    def deep_dup(object)
      case object
      when Hash then object.to_h { |key, value| [key, deep_dup(value)] }
      when Array then object.map { |item| deep_dup(item) }
      when String then object.dup
      else object
      end
    end

    def stringify(object)
      case object
      when Hash then object.to_h { |key, value| [key.to_s, stringify(value)] }
      when Array then object.map { |item| stringify(item) }
      else object
      end
    end
  end
end
