# frozen_string_literal: true

require "test_helper"

module AgentsControl
  # A test that isn't run reports nothing. The suite stays green, the
  # count creeps up by less than it should, and the behaviour it was
  # written to protect is unprotected — which is worse than not having
  # written it, because now everyone believes it is covered.
  #
  # Both ways of getting there have happened in this repository, so
  # both are checked here rather than trusted to review.
  class SuiteTest < Minitest::Test
    # Minitest collects only *public* methods named test_*. Fourteen
    # tests once sat below a `private` in the router's test file and
    # were reported as passing while never executing once.
    def test_no_test_method_is_hidden_below_a_private
      hidden = Minitest::Runnable.runnables.flat_map do |klass|
        next [] unless klass.respond_to?(:private_instance_methods)

        klass.private_instance_methods(false).grep(/\Atest_/).map { |name| "#{klass}##{name}" }
      end

      assert_empty hidden, "these are defined below a `private` and never run"
    end

    # And a test written outside its class — one `end` too early, which
    # looks right in a diff — belongs to no runnable at all, so the
    # check above cannot see it either. Counting what each file declares
    # against what Minitest picked up catches that.
    def test_every_test_file_has_all_of_its_tests_collected
      collected = Minitest::Runnable.runnables.sum { |klass| klass.runnable_methods.size }
      declared = Dir.glob(File.expand_path("**/*_test.rb", __dir__)).sum do |path|
        File.read(path).scan(/^\s*def (test_\w+)/).size
      end

      assert_equal declared, collected,
                   "#{declared - collected} test method(s) are written but not collected — " \
                   "look for one defined outside its class or below a private"
    end
  end
end
