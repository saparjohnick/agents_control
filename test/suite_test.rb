# frozen_string_literal: true

require "test_helper"

module AgentsControl
  # Minitest only collects *public* methods named test_*. A test written
  # below a `private` in a long test file is silently never run, and it
  # reports nothing: the suite stays green, the count creeps up by less
  # than it should, and nobody notices. This happened — seven passphrase
  # tests and seven file tests sat below one for a while, all "passing".
  class SuiteTest < Minitest::Test
    def test_no_test_method_is_hidden_below_a_private
      hidden = Minitest::Runnable.runnables.flat_map do |klass|
        next [] unless klass.respond_to?(:private_instance_methods)

        klass.private_instance_methods(false).grep(/\Atest_/).map { |name| "#{klass}##{name}" }
      end

      assert_empty hidden, "these are defined below a `private` and never run"
    end
  end
end
