# frozen_string_literal: true

module AgentsControl
  # Questions currently waiting for an answer.
  #
  # The thread serving the hook parks here until a human presses a
  # button in Telegram, or time runs out. This wait is exactly what
  # holds the agent blocked — that's the whole point of it.
  #
  # Held only in memory, and that's deliberate. If the daemon crashes,
  # the HTTP connection to the agent drops too: the agent gets a network
  # error, treats it as "no decision," and continues on its own. There's
  # nothing to restore after a restart — nobody's left waiting.
  class Pending
    Question = Struct.new(:id, :event, :queue, :asked_at, keyword_init: true)

    def initialize
      @questions = {}
      @mutex = Mutex.new
    end

    # Register a question and wait for an answer.
    # Returns Reply.none if nobody answered in time.
    #
    # The block runs between registration and waiting: the message has
    # to be sent once the question's identifier is already known, but
    # before the thread goes to sleep. Otherwise the answer could arrive
    # before we start waiting for it.
    def ask(event, timeout:)
      question = register(event)

      begin
        yield(question.id) if block_given?
        question.queue.pop(timeout: timeout) || Reply.none
      ensure
        forget(question.id)
      end
    end

    def answer(id, reply)
      question = @mutex.synchronize { @questions[id] }
      return false unless question

      question.queue.push(reply)
      true
    end

    def find(id) = @mutex.synchronize { @questions[id] }

    def all = @mutex.synchronize { @questions.values.dup }

    def size = @mutex.synchronize { @questions.size }

    private

    def register(event)
      question = Question.new(
        id: SecureRandom.alphanumeric(8).downcase,
        event: event,
        queue: Thread::Queue.new,
        asked_at: Time.now
      )

      @mutex.synchronize { @questions[question.id] = question }
      question
    end

    def forget(id) = @mutex.synchronize { @questions.delete(id) }
  end
end
