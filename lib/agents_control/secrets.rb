# frozen_string_literal: true

require "fileutils"
require "json"

module AgentsControl
  # Storing tokens outside the repo and outside the config.
  #
  # Providers are tried in order; the first available one that answers
  # wins. Implemented by shelling out to system binaries rather than gems:
  # gems like keyring pull in C extensions and break installation for
  # some users, while `security` and `secret-tool` are always present on
  # their respective platforms.
  #
  # The rule that shaped the implementation: **the secret must never land
  # in argv**. Anything passed as an argument is visible in `ps` to any
  # process the user owns, and it lands in shell history. That's why
  # writing to the Keychain goes through `security -i` with the command
  # on stdin, and the CLI never accepts the token as a flag.
  class Secrets
    SERVICE = "agents_control"

    def initialize(executor: Executor.new, providers: nil)
      @executor = executor
      @providers = providers || default_providers
    end

    def get(key)
      readable.each do |provider|
        value = provider.get(key.to_s)
        return value if value && !value.empty?
      end

      nil
    end

    def set(key, value)
      provider = writable.first
      raise Error, "no secret storage available" unless provider

      provider.set(key.to_s, value)
      provider
    end

    def delete(key)
      writable.each { |provider| provider.delete(key.to_s) }
    end

    # Where a secret lives, and where it will be written — for doctor.
    def source_for(key)
      readable.find { |provider| provider.get(key.to_s) }
    end

    def target = writable.first

    private

    def readable = @providers.select(&:available?)

    def writable = readable.select(&:writable?)

    def default_providers
      [
        Providers::Env.new,
        Providers::Keychain.new(executor: @executor),
        Providers::SecretTool.new(executor: @executor),
        Providers::File.new
      ]
    end

    module Providers
      # Environment variables. Read-only — writing into someone else's
      # process isn't possible. Needed for CI, containers, and headless
      # machines with no keyring daemon.
      class Env
        def name = "environment variable"
        def available? = true
        def writable? = false

        def get(key) = ENV.fetch(variable_for(key), nil)

        def set(_key, _value) = raise(Error, "cannot write an environment variable")

        def delete(_key) = nil

        def variable_for(key) = "AGENTS_CONTROL_#{key.upcase}"
      end

      # macOS Keychain.
      class Keychain
        def initialize(executor: Executor.new)
          @executor = executor
        end

        def name = "Keychain (macOS)"

        def available? = !binary.nil?

        def writable? = true

        def get(key)
          result = @executor.run(binary, "find-generic-password", "-s", SERVICE, "-a", key, "-w")
          return nil unless result.success?

          decode(result.stdout.strip)
        end

        # The command goes over stdin in interactive mode, not argv:
        # `security add-generic-password -w SECRET` would expose the
        # token in `ps`, and the man page calls passing a password as an
        # argument insecure outright.
        #
        # The cost of this is that interactive mode splits the line on
        # whitespace, so a value containing a space or newline would be
        # silently mangled. Better to refuse loudly than to save a
        # truncated token and chase a confusing auth error later.
        def set(key, value)
          unless value.to_s.match?(/\A[\x21-\x7E]+\z/)
            raise Error, "Keychain only accepts printable ASCII with no whitespace"
          end

          command = "add-generic-password -s #{SERVICE} -a #{key} -w #{value} -U\n"

          @executor.run(binary, "-i", stdin: command).success?
        end

        def delete(key)
          @executor.run(binary, "delete-generic-password", "-s", SERVICE, "-a", key).success?
        end

        private

        # `security -w` prints the value as-is while it's ASCII, but
        # switches to hex the moment other bytes show up inside it.
        # Telegram tokens are always ASCII, but the store is shared —
        # decode that case too, carefully: only when the result actually
        # looks like packed text, not like a secret made of pure hex digits.
        def decode(value)
          return value unless value.match?(/\A(?:\h\h)+\z/) && value.length.even?

          bytes = [value].pack("H*").force_encoding(Encoding::UTF_8)
          bytes.valid_encoding? && !bytes.ascii_only? ? bytes : value
        end

        def binary
          @binary = Which.find("security") || false if @binary.nil?
          @binary || nil
        end
      end

      # Linux: libsecret on top of gnome-keyring or KWallet.
      class SecretTool
        def initialize(executor: Executor.new)
          @executor = executor
        end

        def name = "libsecret (Linux)"

        def available? = !binary.nil?

        def writable? = true

        def get(key)
          result = @executor.run(binary, "lookup", "service", SERVICE, "account", key)
          result.success? ? result.stdout.chomp : nil
        end

        # secret-tool reads the secret from stdin on its own — argv stays clean.
        def set(key, value)
          result = @executor.run(
            binary, "store", "--label=#{SERVICE} #{key}",
            "service", SERVICE, "account", key,
            stdin: value
          )
          result.success?
        end

        def delete(key)
          @executor.run(binary, "clear", "service", SERVICE, "account", key).success?
        end

        private

        def binary
          @binary = Which.find("secret-tool") || false if @binary.nil?
          @binary || nil
        end
      end

      # Last resort: a file with 0600 permissions.
      #
      # Needed where there's no keyring daemon at all — a headless server
      # or a container. Worse than the other options, so we warn about it.
      class File
        def self.path
          base = ENV["XDG_STATE_HOME"] || ::File.expand_path("~/.local/state")
          ::File.join(base, "agents_control", "credentials.json")
        end

        def initialize(path: self.class.path)
          @path = path
        end

        def name = "file #{@path} (0600)"

        def available? = true

        def writable? = true

        def insecure? = true

        def get(key) = read[key]

        def set(key, value)
          data = read.merge(key => value)
          FileUtils.mkdir_p(::File.dirname(@path))

          # Permissions are set before writing: otherwise there's a window
          # between file creation and chmod where the secret is
          # world-readable.
          ::File.open(@path, ::File::WRONLY | ::File::CREAT | ::File::TRUNC, 0o600) do |file|
            file.write(JSON.generate(data))
          end

          true
        end

        def delete(key)
          data = read
          return false unless data.key?(key)

          set_all(data.except(key))
        end

        private

        def read
          return {} unless ::File.exist?(@path)

          parsed = JSON.parse(::File.read(@path))
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end

        def set_all(data)
          ::File.open(@path, ::File::WRONLY | ::File::CREAT | ::File::TRUNC, 0o600) do |file|
            file.write(JSON.generate(data))
          end

          true
        end
      end
    end
  end
end
