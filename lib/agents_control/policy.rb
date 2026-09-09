# frozen_string_literal: true

module AgentsControl
  # Recognises a command from Telegram that must not go into a pane
  # blind — the handful that destroy a disk or the machine outright.
  #
  # This is a seatbelt, not a security system. It answers one question:
  # did the phone in someone's pocket just send something there is no
  # coming back from? A wrong tab number in a list, a command pasted
  # into the wrong chat, a thumb on the wrong line — those are the
  # cases, and they're the reason the list stays small enough to hold
  # in your head.
  #
  # The outcome is never a refusal. The person on the other end owns
  # the machine; a check they can't get past doesn't prevent anything,
  # it just makes them walk to the laptop and type it there.
  class Policy
    Verdict = Struct.new(:action, :reason, keyword_init: true) do
      def allow? = action == :allow
      def confirm? = action == :confirm
    end

    ALLOWED = Verdict.new(action: :allow).freeze

    # Targets that make a recursive force delete unrecoverable rather
    # than merely annoying. `rm -rf /tmp/build` is someone's ordinary
    # Tuesday; `rm -rf ~` is the end of the machine.
    FATAL_TARGETS = ["/", "/*", "~", "~/", "~/*", "$HOME", "$HOME/*", "${HOME}", "${HOME}/*",
                     "/usr", "/etc", "/var", "/System", "/Library", "/Applications",
                     "/Users", "/home", "/opt", "/bin", "/sbin"].freeze

    # The bar for an entry: catastrophic, irreversible, and nobody
    # types it from a phone on purpose. Not "sensitive", not "usually a
    # mistake" — `cat .env` and `git push --force` are somebody's
    # ordinary afternoon, and a list that stops those trains people to
    # tap past it without reading, which costs more than it saves.
    #
    # Each carries its own plain-language reason. "Matches a pattern"
    # tells someone glancing at a phone nothing they can act on; "this
    # erases your home directory" does.
    CATASTROPHIC = [
      [/:\(\)\s*\{[^}]*\|[^}]*&[^}]*\}\s*;\s*:/,
       "that's a fork bomb — it locks the machine up until it's power-cycled"],
      [/\bmkfs(\.\w+)?\b/,
       "mkfs formats a filesystem — everything on that device is gone"],
      [/\bdd\b[^|;]*\bof=\/dev\//,
       "dd writing to a raw device destroys whatever filesystem is on it"]
    ].freeze

    # An `rm` carrying both a recursive and a force flag — bundled
    # (-rf, -fr, -Rf) or apart (-r -f, --recursive --force) — aimed at
    # something there's no coming back from. Matched on the parsed
    # operands rather than as a substring: "rm -rf /" and
    # "rm -rf /tmp/build" differ by one character as text, and by
    # everything else in what they do.
    def self.reckless_delete(command)
      words = command.to_s.split
      # Matched on the command's basename, and case-insensitively:
      # `/bin/rm` is the same program, and macOS's case-insensitive
      # filesystem happily runs `RM` as well.
      at = words.index { |word| File.basename(word).casecmp?("rm") }
      return unless at

      flags, operands = words.drop(at + 1).partition { |word| word.start_with?("-") }
      joined = flags.join(" ")
      return unless joined.match?(/--recursive|-[a-zA-Z]*[rR]/) && joined.match?(/--force|-[a-zA-Z]*f/)

      target = operands.find { |operand| fatal_target?(operand) }
      "this recursively deletes #{target} — there is no undo" if target
    end

    # Quotes come off before comparing: `rm -rf "$HOME"` is an entirely
    # ordinary way to type the thing this exists to catch, and it isn't
    # the same string as `rm -rf $HOME`.
    def self.fatal_target?(operand)
      bare = operand.to_s.gsub(/\A['"]|['"]\z/, "")

      FATAL_TARGETS.include?(bare) || FATAL_TARGETS.include?(bare.chomp("/"))
    end

    def self.catastrophic(command)
      reckless = reckless_delete(command)
      return reckless if reckless

      CATASTROPHIC.find { |pattern, _| command.to_s.match?(pattern) }&.last
    end

    def self.check(command)
      fatal = catastrophic(command)

      fatal ? Verdict.new(action: :confirm, reason: fatal) : ALLOWED
    end
  end
end
