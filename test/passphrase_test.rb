# frozen_string_literal: true

require "test_helper"

module AgentsControl
  class PassphraseTest < Minitest::Test
    def setup
      @secrets = FakeSecrets.new
      @passphrase = Passphrase.new(secrets: @secrets)
    end

    def test_none_is_set_to_begin_with
      refute_predicate @passphrase, :configured?
    end

    def test_setting_one_makes_it_configured
      @passphrase.set("correct horse battery")

      assert_predicate @passphrase, :configured?
    end

    def test_the_right_passphrase_matches
      @passphrase.set("correct horse battery")

      assert @passphrase.matches?("correct horse battery")
    end

    def test_a_wrong_passphrase_does_not
      @passphrase.set("correct horse battery")

      refute @passphrase.matches?("correct horse staple")
    end

    # The whole point of storing it derived: someone reading the
    # Keychain entry doesn't thereby learn what to type.
    def test_the_passphrase_itself_is_never_stored
      @passphrase.set("correct horse battery")

      refute_includes @secrets.stored.values.join, "correct horse battery"
    end

    def test_each_setting_gets_its_own_salt
      @passphrase.set("correct horse battery")
      first = @secrets.stored.values.first
      @passphrase.set("correct horse battery")

      refute_equal first, @secrets.stored.values.first
    end

    def test_a_short_passphrase_is_refused
      assert_raises(Passphrase::TooShort) { @passphrase.set("short") }
    end

    def test_a_refused_passphrase_is_not_stored
      assert_raises(Passphrase::TooShort) { @passphrase.set("short") }

      refute_predicate @passphrase, :configured?
    end

    # A check that can't be made is a check that didn't pass — never a
    # free pass because nothing was configured.
    def test_nothing_matches_when_none_is_set
      refute @passphrase.matches?("anything")
      refute @passphrase.matches?("")
    end

    def test_an_empty_attempt_never_matches
      @passphrase.set("correct horse battery")

      refute @passphrase.matches?("")
    end

    # ── an unusable record reads as "none", not as "locked out" ──────

    # Otherwise the command asks for a passphrase that can never match
    # and there's no way through from the phone at all.
    def test_a_record_this_version_cannot_read_counts_as_no_passphrase
      @secrets.set(Passphrase::KEY, "some-older-format$whatever")

      refute_predicate @passphrase, :configured?
      refute @passphrase.matches?("whatever")
    end

    def test_a_truncated_record_counts_as_no_passphrase
      @secrets.set(Passphrase::KEY, "pbkdf2-sha256$210000$")

      refute_predicate @passphrase, :configured?
    end

    def test_a_record_with_a_nonsense_iteration_count_counts_as_no_passphrase
      @secrets.set(Passphrase::KEY, "pbkdf2-sha256$lots$salt$hash")

      refute_predicate @passphrase, :configured?
    end

    # Silently ignoring it would leave someone believing they're
    # protected, so doctor gets to tell them apart.
    def test_an_unusable_record_is_distinguishable_from_an_absent_one
      assert_empty [@passphrase.unusable?].select(&:itself)

      @secrets.set(Passphrase::KEY, "nonsense")

      assert_predicate @passphrase, :unusable?
    end

    def test_a_real_record_is_not_reported_as_unusable
      @passphrase.set("correct horse battery")

      refute_predicate @passphrase, :unusable?
    end

    # ── comparing two entries without keeping either ─────────────────

    def test_two_matching_entries_agree
      sealed = Passphrase.sealed("correct horse battery")

      assert Passphrase.sealed_matches?(sealed, "correct horse battery")
    end

    def test_two_different_entries_do_not
      sealed = Passphrase.sealed("correct horse battery")

      refute Passphrase.sealed_matches?(sealed, "correct horse staple")
    end

    # The wizard asks twice; the first answer waits for the second, and
    # it must not wait as plain text.
    def test_the_first_entry_is_not_recoverable_from_what_is_held
      sealed = Passphrase.sealed("correct horse battery")

      refute_includes sealed.join, "correct horse battery"
    end

    def test_an_empty_second_entry_never_agrees
      refute Passphrase.sealed_matches?(Passphrase.sealed("correct horse battery"), "")
    end

    # Secrets#set names the provider it chose, not whether that provider
    # kept anything. A Keychain that refused would otherwise look
    # exactly like one that saved.
    def test_a_write_that_goes_nowhere_is_an_error_not_a_success
      passphrase = Passphrase.new(secrets: DeafSecrets.new)

      assert_raises(Passphrase::NotSaved) { passphrase.set("correct horse battery") }
    end

    def test_clearing_removes_it
      @passphrase.set("correct horse battery")
      @passphrase.clear

      refute_predicate @passphrase, :configured?
    end

    # Accepts every write and keeps none — a locked Keychain, or one a
    # background daemon has no authorization for.
    class DeafSecrets
      def get(_key, skip: nil) = nil
      def set(_key, _value) = self
      def delete(_key) = nil
    end

    class FakeSecrets
      attr_reader :stored

      def initialize = @stored = {}
      def get(key, skip: nil) = @stored[key]
      def set(key, value) = @stored[key] = value
      def delete(key) = @stored.delete(key)
    end
  end
end
