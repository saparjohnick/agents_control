# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  class DoctorTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @config = Config.new({ "telegram" => { "allowed_chat_ids" => [42] } },
                           path: File.join(@dir, "config.yml"))
    end

    def teardown = FileUtils.remove_entry(@dir)

    def test_reports_every_area
      names = run_checks.map(&:name)

      assert_includes names, "Ruby"
      assert_includes names, "Token"
      assert_includes names, "Allowed chats"
      assert_includes names, "Daemon"
    end

    # An empty list means "the bot answers nobody" — that's a failure,
    # not a warning.
    def test_empty_chat_list_is_a_failure
      check = run_checks(config: Config.new).find { |c| c.name == "Allowed chats" }

      assert_predicate check, :failed?
      assert_includes check.fix, "setup"
    end

    def test_missing_token_is_a_failure
      check = run_checks(secrets: secrets_without_token).find { |c| c.name == "Token" }

      assert_predicate check, :failed?
    end

    # A 0600 file works, but it's worse than the Keychain — worth saying so.
    def test_file_storage_earns_a_warning
      check = run_checks(secrets: file_secrets).find { |c| c.name == "Token" }

      assert_equal :warn, check.status
    end

    # A diagnostic tool has no business crashing: an unexpected error is
    # just another check result, not the end of the run.
    def test_a_broken_check_does_not_abort_the_rest
      broken = Object.new
      def broken.get(_key) = raise("storage fell over")
      def broken.source_for(_key) = raise("storage fell over")
      def broken.available? = true

      checks = run_checks(secrets: Secrets.new(providers: [broken]))

      assert_operator checks.size, :>, 3
      assert(checks.any?(&:failed?))
    end

    # A malformed token must not go out over the network: unprintable
    # characters would land straight in the URL and fail the request
    # with a cryptic address-parsing error.
    def test_malformed_token_is_caught_before_any_network_call
      secrets = file_secrets(token: "this is not a token")

      check = run_checks(secrets: secrets).find { |c| c.name == "Bot" }

      assert_predicate check, :failed?
      assert_includes check.detail, "doesn't look like"
    end

    # The daemon connects hooks itself and removes them on stop — their
    # absence while the daemon is off is normal.
    def test_missing_hooks_are_not_a_failure
      check = run_checks.find { |c| c.name == "Hooks" }

      refute_predicate check, :failed?
    end

    def test_anchors_report_the_next_run_when_enabled
      config = Config.new({
                            "telegram" => { "allowed_chat_ids" => [42] },
                            "anchors" => { "enabled" => true, "schedule" => ["07:00"] }
                          })

      check = run_checks(config: config).find { |c| c.name == "Rate-limit anchors" }

      assert_predicate check, :ok?
      assert_includes check.detail, "haiku"
    end

    # A 7am anchor won't fire if the Mac is asleep.
    def test_sleeping_mac_is_flagged_when_anchors_are_on
      skip "the wake check is macOS-only" unless RUBY_PLATFORM.include?("darwin")

      config = Config.new({
                            "telegram" => { "allowed_chat_ids" => [42] },
                            "anchors" => { "enabled" => true, "schedule" => ["07:00"] }
                          })
      executor = FakeExecutor.new("sched" => "No scheduled events.")

      check = run_checks(config: config, executor: executor).find { |c| c.name == "Wake schedule" }

      assert_equal :warn, check.status
      assert_includes check.fix, "pmset"
    end

    private

    # The network is never touched in tests: a stub client is used instead.
    def run_checks(config: @config, secrets: nil, executor: nil, api: nil)
      Doctor.new(config: config,
                 secrets: secrets || secrets_without_token,
                 executor: executor || FakeExecutor.new,
                 api: api || offline_api).run
    end

    def offline_api
      api = Object.new
      def api.get_me = raise(Channels::Telegram::Api::Unavailable, "no network")
      api
    end

    def secrets_without_token
      Secrets.new(providers: [Secrets::Providers::File.new(path: File.join(@dir, "empty.json"))])
    end

    def file_secrets(token: "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw")
      provider = Secrets::Providers::File.new(path: File.join(@dir, "creds.json"))
      provider.set("telegram_token", token)

      Secrets.new(providers: [provider])
    end
  end

  class ServiceTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir
      @service = Service::Launchd.new(ruby: "/opt/homebrew/bin/ruby",
                                      script: "/tmp/exe/agents_control",
                                      logger: StringIO.new)
    end

    def teardown = FileUtils.remove_entry(@dir)

    # The service doesn't start from your zsh: relying on PATH isn't an
    # option. On this machine, two broken shims sit ahead of a working
    # Ruby on PATH.
    def test_plist_uses_absolute_paths
      plist = @service.send(:plist)

      assert_includes plist, "<string>/opt/homebrew/bin/ruby</string>"
      assert_includes plist, "<string>/tmp/exe/agents_control</string>"
    end

    def test_interpreter_defaults_to_the_running_one
      assert_equal RbConfig.ruby, Service::Launchd.new(logger: StringIO.new).ruby
    end

    def test_plist_restarts_the_daemon_after_a_crash
      assert_includes @service.send(:plist), "<key>KeepAlive</key>"
    end

    def test_plist_pins_a_sane_path
      path = @service.send(:safe_path)

      assert_operator path.index("/opt/homebrew/bin"), :<, path.index("/usr/bin"),
                      "ARM brew should come before the system directories"
    end

    def test_systemd_unit_restarts_too
      unit = Service::Systemd.new(ruby: "/usr/bin/ruby", script: "/opt/ac",
                                  logger: StringIO.new).send(:unit)

      assert_includes unit, "Restart=always"
      assert_includes unit, "ExecStart=/usr/bin/ruby /opt/ac daemon"
    end
  end
end
