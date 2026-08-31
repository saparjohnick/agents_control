# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module AgentsControl
  class SecretsTest < Minitest::Test
    Providers = Secrets::Providers

    def test_environment_wins_over_everything
      with_env("AGENTS_CONTROL_TELEGRAM_TOKEN" => "from-env") do
        secrets = Secrets.new(providers: [Providers::Env.new, stub_provider("from-storage")])

        assert_equal "from-env", secrets.get(:telegram_token)
      end
    end

    def test_falls_through_to_next_provider
      secrets = Secrets.new(providers: [stub_provider(nil), stub_provider("found")])

      assert_equal "found", secrets.get(:telegram_token)
    end

    def test_empty_value_is_treated_as_missing
      secrets = Secrets.new(providers: [stub_provider(""), stub_provider("real")])

      assert_equal "real", secrets.get(:telegram_token)
    end

    def test_writes_to_first_writable_provider
      target = stub_provider(nil, writable: true)
      secrets = Secrets.new(providers: [Providers::Env.new, target])

      secrets.set(:telegram_token, "new")

      assert_equal "new", target.written[:telegram_token.to_s]
    end

    # Environment variables can't be written to — read-only.
    def test_environment_provider_is_read_only
      refute_predicate Providers::Env.new, :writable?
    end

    def test_raises_when_nowhere_to_write
      secrets = Secrets.new(providers: [Providers::Env.new])

      assert_raises(Error) { secrets.set(:telegram_token, "x") }
    end

    class KeychainTest < Minitest::Test
      # The core property: the secret must never land in argv, because
      # arguments are visible in `ps` to any process the user owns.
      def test_secret_never_appears_in_arguments
        executor = FakeExecutor.new("security" => "")
        token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
        Secrets::Providers::Keychain.new(executor: executor).set("telegram_token", token)

        call = executor.calls.last

        refute_includes call[:argv].join(" "), token
        assert_includes call[:stdin], token
        assert_includes call[:argv], "-i"
      end

      # Interactive mode splits the line on whitespace, so a value with a
      # space would be silently mangled. Better to refuse loudly.
      def test_rejects_values_it_cannot_pass_safely
        keychain = Secrets::Providers::Keychain.new(executor: FakeExecutor.new("security" => ""))

        assert_raises(Error) { keychain.set("k", "with space") }
        assert_raises(Error) { keychain.set("k", "with\nnewline") }
      end

      def test_accepts_a_real_telegram_token_shape
        executor = FakeExecutor.new("security" => "")
        keychain = Secrets::Providers::Keychain.new(executor: executor)

        assert keychain.set("telegram_token", "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw")
      end

      def test_reads_plain_ascii_as_is
        executor = FakeExecutor.new("security" => "123456:ABCdef\n")

        assert_equal "123456:ABCdef",
                     Secrets::Providers::Keychain.new(executor: executor).get("telegram_token")
      end

      # security switches to hex the moment the value contains non-ASCII bytes.
      def test_decodes_hex_encoded_non_ascii
        hex = "d0a2d095d0a1d0a2"
        executor = FakeExecutor.new("security" => "#{hex}\n")

        assert_equal "ТЕСТ", Secrets::Providers::Keychain.new(executor: executor).get("k")
      end

      # But a secret that happens to be made of hex characters must not be mangled.
      def test_leaves_hex_looking_ascii_secret_alone
        executor = FakeExecutor.new("security" => "deadbeef\n")

        assert_equal "deadbeef", Secrets::Providers::Keychain.new(executor: executor).get("k")
      end

      def test_missing_item_returns_nil
        assert_nil Secrets::Providers::Keychain.new(executor: FakeExecutor.new).get("k")
      end
    end

    class FileProviderTest < Minitest::Test
      def test_round_trip
        Dir.mktmpdir do |dir|
          provider = Secrets::Providers::File.new(path: File.join(dir, "creds.json"))
          provider.set("telegram_token", "value")

          assert_equal "value", provider.get("telegram_token")
        end
      end

      # Permissions are set at creation, not after the write: otherwise
      # there's a window where the secret file is world-readable.
      def test_file_is_created_with_owner_only_permissions
        Dir.mktmpdir do |dir|
          path = File.join(dir, "creds.json")
          Secrets::Providers::File.new(path: path).set("telegram_token", "value")

          assert_equal "600", format("%o", File.stat(path).mode & 0o777)
        end
      end

      def test_keeps_other_keys_on_write
        Dir.mktmpdir do |dir|
          provider = Secrets::Providers::File.new(path: File.join(dir, "creds.json"))
          provider.set("a", "1")
          provider.set("b", "2")

          assert_equal "1", provider.get("a")
        end
      end

      def test_broken_file_reads_as_empty
        Dir.mktmpdir do |dir|
          path = File.join(dir, "creds.json")
          File.write(path, "not json")

          assert_nil Secrets::Providers::File.new(path: path).get("a")
        end
      end

      def test_announces_itself_as_the_weaker_option
        assert_predicate Secrets::Providers::File.new(path: "/tmp/x"), :insecure?
      end
    end

    private

    def stub_provider(value, writable: false)
      Class.new do
        attr_reader :written

        def initialize(value, writable)
          @value = value
          @writable = writable
          @written = {}
        end

        def name = "stub"
        def available? = true
        def writable? = @writable
        def get(_key) = @value
        def set(key, value) = @written[key] = value
        def delete(key) = @written.delete(key)
      end.new(value, writable)
    end

    def with_env(values)
      original = values.transform_values { |_| nil }.merge(ENV.slice(*values.keys))
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end
  end
end
