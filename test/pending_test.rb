# frozen_string_literal: true

require "test_helper"

module AgentsControl
  class PendingTest < Minitest::Test
    def setup
      @pending = Pending.new
      @event = Agents::ClaudeCode.new.to_event(Fixtures::HOOK_PERMISSION)
    end

    def test_answer_reaches_the_waiting_thread
      waiter = Thread.new { @pending.ask(@event, timeout: 5) { |id| @id = id } }

      wait_until { @id }
      assert @pending.answer(@id, Reply.allow)

      assert_predicate waiter.value, :allow?
    end

    # Silence is also a decision, but distinguishable from an explicit refusal.
    def test_timeout_yields_an_empty_reply
      reply = @pending.ask(@event, timeout: 0.2)

      assert_predicate reply, :none?
    end

    # The message is sent between registration and waiting: otherwise
    # the answer could arrive before the thread starts waiting for it.
    def test_question_is_registered_before_the_block_runs
      seen = nil
      Thread.new { @pending.ask(@event, timeout: 2) { |id| seen = @pending.find(id) } }

      wait_until { seen }

      assert_equal @event, seen.event
    end

    def test_question_disappears_after_the_answer
      Thread.new { @pending.ask(@event, timeout: 5) { |id| @id = id } }
      wait_until { @id }
      @pending.answer(@id, Reply.allow)

      wait_until { @pending.size.zero? }

      assert_equal 0, @pending.size
    end

    def test_question_disappears_after_a_timeout
      @pending.ask(@event, timeout: 0.2)

      assert_equal 0, @pending.size
    end

    # A button from an old message must not crash the bot.
    def test_answering_an_unknown_question_is_harmless
      refute @pending.answer("no-such-question", Reply.allow)
    end

    def test_several_questions_wait_independently
      ids = []
      waiters = 3.times.map do
        Thread.new { @pending.ask(@event, timeout: 5) { |id| ids << id } }
      end

      wait_until { ids.size == 3 }
      @pending.answer(ids[1], Reply.deny)

      assert_predicate waiters[1].value, :deny?
      assert_equal 2, @pending.size
      waiters.each(&:kill)
    end

    private

    def wait_until(seconds = 3)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      sleep(0.01) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    end
  end
end
