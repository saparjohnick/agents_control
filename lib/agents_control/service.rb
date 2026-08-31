# frozen_string_literal: true

require "fileutils"
require "rbconfig"

module AgentsControl
  # Autostarting the daemon: launchd on macOS, systemd on Linux.
  #
  # Everything here is built around one rule: **absolute paths**. The
  # service starts not from an interactive shell but from a system
  # manager, where PATH is completely different and can't be relied on.
  class Service
    LABEL = "com.agents-control.daemon"

    def self.for_platform(**args)
      RUBY_PLATFORM.include?("darwin") ? Launchd.new(**args) : Systemd.new(**args)
    end

    # The interpreter isn't looked up on PATH, it's the one running this
    # code right now: a PATH search could find a version manager's
    # broken shim ahead of the working Ruby. RbConfig.ruby by definition
    # points at the live interpreter.
    def initialize(ruby: nil, script: nil, logger: $stdout)
      @ruby = ruby || RbConfig.ruby
      @script = script || default_script
      @logger = logger
    end

    attr_reader :ruby, :script

    def log_path = File.expand_path("~/Library/Logs/agents_control.log")

    private

    # Path to the tool's own executable. The gem might not be installed
    # globally — in that case this is the file straight from the repo.
    def default_script
      File.expand_path("../../exe/agents_control", __dir__)
    end

    def write(path, contents)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
      path
    end

    def log(message) = @logger.puts(message)

    # macOS.
    class Launchd < Service
      def path = File.expand_path("~/Library/LaunchAgents/#{LABEL}.plist")

      def install
        write(path, plist)
        reload
        path
      end

      def uninstall
        system("launchctl", "unload", path, out: File::NULL, err: File::NULL) if File.exist?(path)
        FileUtils.rm_f(path)
      end

      def installed? = File.exist?(path)

      private

      def reload
        system("launchctl", "unload", path, out: File::NULL, err: File::NULL)
        system("launchctl", "load", path, out: File::NULL, err: File::NULL)
      end

      def plist
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>Label</key>
            <string>#{LABEL}</string>

            <!-- Absolute paths are mandatory: launchd's PATH isn't yours. -->
            <key>ProgramArguments</key>
            <array>
              <string>#{ruby}</string>
              <string>#{script}</string>
              <string>daemon</string>
            </array>

            <key>RunAtLoad</key>
            <true/>

            <!-- The daemon crashes, launchd brings it back up. Pending
                 questions are lost in the process, but nobody's left
                 waiting on them anyway: the connection to the agent
                 dropped along with the process, and the agent moved on by itself. -->
            <key>KeepAlive</key>
            <true/>

            <key>StandardOutPath</key>
            <string>#{log_path}</string>
            <key>StandardErrorPath</key>
            <string>#{log_path}</string>

            <key>EnvironmentVariables</key>
            <dict>
              <key>PATH</key>
              <string>#{safe_path}</string>
            </dict>
          </dict>
          </plist>
        XML
      end

      # The same order as in binary lookup: version managers and ARM
      # brew ahead of the system directories.
      def safe_path
        ["#{Dir.home}/.asdf/shims", "/opt/homebrew/bin", "/opt/homebrew/sbin",
         "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(":")
      end
    end

    # Linux.
    class Systemd < Service
      def path = File.expand_path("~/.config/systemd/user/agents-control.service")

      def log_path = "journal"

      def install
        write(path, unit)
        system("systemctl", "--user", "daemon-reload", out: File::NULL, err: File::NULL)
        system("systemctl", "--user", "enable", "--now", "agents-control",
               out: File::NULL, err: File::NULL)
        path
      end

      def uninstall
        system("systemctl", "--user", "disable", "--now", "agents-control",
               out: File::NULL, err: File::NULL)
        FileUtils.rm_f(path)
      end

      def installed? = File.exist?(path)

      private

      def unit
        <<~UNIT
          [Unit]
          Description=agents_control — control AI agents from Telegram
          After=network-online.target

          [Service]
          Type=simple
          ExecStart=#{ruby} #{script} daemon
          Restart=always
          RestartSec=5

          [Install]
          WantedBy=default.target
        UNIT
      end
    end
  end
end
