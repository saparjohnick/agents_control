# frozen_string_literal: true

require "io/console"

module AgentsControl
  # Reading keystrokes from the terminal in raw mode.
  #
  # Split out on its own because two things need the keyboard: the input
  # line with its command palette, and the settings menu. Parsing escape
  # sequences and multi-byte characters is a place it's easy to get wrong twice.
  module Keyboard
    UP = "\e[A"
    DOWN = "\e[B"
    RIGHT = "\e[C"
    LEFT = "\e[D"

    ENTER = ["\r", "\n"].freeze
    BACKSPACE = ["\x7F", "\b"].freeze
    CTRL_C = "\x03"
    CTRL_D = "\x04"
    CTRL_A = "\x01"
    CTRL_E = "\x05"
    CTRL_U = "\x15"
    TAB = "\t"
    ESC = "\e"

    private

    # Returns a key as a string: a printable character, a control byte,
    # or a whole escape sequence. nil means end of input.
    def read_key
      byte = @in.getbyte
      return nil if byte.nil?

      return read_escape if byte == 0x1B

      read_utf8(byte)
    end

    # A lone Esc and an arrow key start the same way. Told apart by
    # waiting: a sequence's continuation arrives immediately, a lone Esc arrives alone.
    #
    # The end of a sequence is determined by its structure, not by a
    # pause. Otherwise on fast input — and in tests, where there are no
    # pauses at all — an arrow key would swallow the next keystrokes, and they'd be lost.
    def read_escape
      return ESC unless pending?(0.05)

      second = @in.getbyte
      return ESC if second.nil?

      sequence = +"#{ESC}#{second.chr}"
      return sequence unless ["[", "O"].include?(second.chr)

      # A CSI sequence ends on a byte in the 0x40..0x7E range — that's the stop condition.
      while sequence.length < 12
        byte = @in.getbyte
        break if byte.nil?

        sequence << byte.chr
        break if (0x40..0x7E).cover?(byte)
      end

      sequence
    end

    def pending?(timeout)
      return !@in.wait_readable(timeout).nil? if @in.respond_to?(:wait_readable)

      !IO.select([@in], nil, nil, timeout).nil?
    rescue TypeError, IOError
      true
    end

    # Non-ASCII characters arrive as several bytes — assembled into a
    # whole character, or the string would come apart into fragments.
    def read_utf8(first)
      length = case first
               when 0x00..0x7F then 1
               when 0xC0..0xDF then 2
               when 0xE0..0xEF then 3
               else 4
               end

      bytes = [first]
      (length - 1).times { bytes << @in.getbyte.to_i }
      bytes.pack("C*").force_encoding(Encoding::UTF_8).scrub
    end
  end
end
