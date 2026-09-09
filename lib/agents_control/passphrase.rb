# frozen_string_literal: true

require "openssl"
require "securerandom"

module AgentsControl
  # The passphrase that unlocks a catastrophic command from Telegram.
  #
  # Stored the same place as the bot token — Keychain or libsecret,
  # never the config file, never argv — and stored derived rather than
  # plain: a token grants access, so it has to be readable back, but a
  # passphrase only ever has to be *checked*, and there's no reason to
  # keep something readable when a comparison would do.
  #
  # PBKDF2-HMAC-SHA256 through OpenSSL, which is stdlib. bcrypt or
  # argon2 would be better at resisting an offline attack, and both are
  # native extensions — the gem promises a pure-Ruby install with
  # nothing to compile, and that promise is worth more here than the
  # margin: anyone who can read this hash out of the Keychain can
  # already read the bot token sitting next to it, which is the whole
  # machine anyway.
  class Passphrase
    KEY = "run_passphrase"
    ITERATIONS = 210_000
    LENGTH = 32

    # The wizard's two prompts are minutes apart at most, but what
    # bridges them is written to the store on disk (0600, with a TTL) —
    # so it gets the same cost as the record it will become. Cheaper
    # here would mean the throwaway derivation is the easier of the two
    # to attack offline, which is a strange place to save 200ms.
    SEAL_ITERATIONS = ITERATIONS
    PREFIX = "pbkdf2-sha256"

    # A passphrase short enough to guess isn't protecting anything from
    # someone holding an unlocked phone, which is the case this exists
    # for in the first place.
    MINIMUM = 8

    class TooShort < StandardError; end

    # The write went nowhere. Secrets#set reports which provider it
    # picked, not whether that provider succeeded, and a Keychain that
    # refused (locked, no authorization from a background daemon) would
    # otherwise be indistinguishable from one that saved — leaving
    # someone told their passphrase is set while destructive commands
    # go on asking for a tap.
    class NotSaved < StandardError; end

    def initialize(secrets: Secrets.new)
      @secrets = secrets
    end

    # "There's a record this version can actually check against", not
    # "the entry isn't empty". The two diverge exactly when something
    # unusable is stored — a plain string put in the environment
    # variable, a truncated write, a format from a version this one was
    # downgraded from — and every one of those would otherwise ask for
    # a passphrase that can never match. Unusable is treated as absent,
    # which falls back to the confirmation button rather than locking
    # the command away. `doctor` reports the difference, so it isn't
    # silent.
    def configured? = !parse(stored).nil?

    # Whether something is stored that isn't usable — for doctor, which
    # is the one place that should say so out loud.
    def unusable? = !stored.to_s.empty? && parse(stored).nil?

    def set(plain)
      value = plain.to_s
      raise TooShort, "the passphrase needs at least #{MINIMUM} characters" if value.length < MINIMUM

      salt = SecureRandom.hex(16)
      @secrets.set(KEY, [PREFIX, ITERATIONS, salt, derive(value, salt, ITERATIONS)].join("$"))

      raise NotSaved, "the secret store didn't keep it" unless matches?(value)

      true
    end

    def clear = @secrets.delete(KEY)

    # False whenever anything is off — no passphrase set, a record this
    # version doesn't understand, an empty candidate. A check that
    # can't be made is a check that didn't pass.
    def matches?(candidate)
      record = parse(stored)
      return false unless record
      return false if candidate.to_s.empty?

      secure_compare(derive(candidate.to_s, record[:salt], record[:iterations]), record[:hash])
    end

    # Derives against a throwaway salt so two entries can be compared
    # without either being kept. The wizard asks twice, and the first
    # answer waits for the second in the store — as a derivation, never
    # as the passphrase itself.
    def self.sealed(value)
      salt = SecureRandom.hex(16)
      [salt, OpenSSL::KDF.pbkdf2_hmac(value.to_s, salt: salt, iterations: SEAL_ITERATIONS,
                                                  length: LENGTH, hash: "SHA256").unpack1("H*")]
    end

    def self.sealed_matches?(sealed, candidate)
      salt, expected = sealed
      return false if salt.to_s.empty? || candidate.to_s.empty?

      OpenSSL.secure_compare(
        OpenSSL::KDF.pbkdf2_hmac(candidate.to_s, salt: salt, iterations: SEAL_ITERATIONS,
                                                 length: LENGTH, hash: "SHA256").unpack1("H*"),
        expected.to_s
      )
    end

    private

    # Read past the environment-variable provider on purpose. A
    # passphrase is only ever checked, never read back, so there's no
    # reason to accept one from the environment — and a plain one put
    # in AGENTS_CONTROL_RUN_PASSPHRASE would take precedence over the
    # Keychain, match nothing, and lock the command away for good:
    # `passphrase clear` only writes to writable providers, and the
    # environment isn't one.
    def stored
      @secrets.get(KEY, skip: Secrets::Providers::Env)
    end

    # A record is four fields with our prefix, a salt, a positive
    # iteration count, and a hash. Anything else is not a passphrase
    # this version can check.
    def parse(record)
      prefix, iterations, salt, hash = record.to_s.split("$", 4)
      return unless prefix == PREFIX
      return unless salt.to_s.length.positive? && hash.to_s.length.positive?
      return unless iterations.to_s.match?(/\A[1-9][0-9]*\z/)

      { iterations: iterations.to_i, salt: salt, hash: hash }
    end

    def derive(value, salt, iterations)
      OpenSSL::KDF.pbkdf2_hmac(value, salt: salt.to_s, iterations: iterations,
                                      length: LENGTH, hash: "SHA256").unpack1("H*")
    end

    # Fixed-time comparison. The attacker here is someone typing into a
    # Telegram chat rather than measuring microseconds, so this is
    # closer to hygiene than to a threat being answered — but a
    # comparison that leaks its answer through timing is never the
    # right one to write.
    def secure_compare(one, two)
      OpenSSL.secure_compare(one.to_s, two.to_s)
    end
  end
end
