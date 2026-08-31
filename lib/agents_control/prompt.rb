# frozen_string_literal: true

module AgentsControl
  # A line input with arrow-key command selection.
  #
  # Written by hand because reline can't do this: its own list moves
  # with Tab and Ctrl-N, arrows are already claimed by history, and
  # there's no way to remap them just while the list is open. And
  # picking with arrows is exactly what you'd expect from a line that starts with a slash.
  class Prompt
    include Keyboard

    # How many list rows to show at once.
    WINDOW = 8

    def initialize(input: $stdin, output: $stdout, completer: nil, describer: nil)
      @in = input
      @out = output
      @completer = completer || ->(_word) { [] }
      @describer = describer || ->(_item) { nil }
      @history = []
    end

    # Returns the entered line, or nil if input closed (Ctrl-D).
    def read(prompt_text)
      @prompt = prompt_text
      @buffer = +""
      @cursor = 0
      @selected = 0
      @dismissed = false
      @drawn = 0
      @history_at = @history.size
      @result = nil

      render
      @in.raw { loop { break if handle(read_key) == :done } }

      @result
    ensure
      finish
    end

    private

    # ── the loop ──────────────────────────────────────────────────────────

    # Returns a string once input is done, and nil to keep going.
    def handle(key)
      # Input was closed: that's the end, not an empty line.
      return finish_line(nil) if key.nil?

      case key
      when CTRL_C then raise Interrupt
      when CTRL_D then @buffer.empty? ? finish_line(nil) : nil
      when *ENTER then accept
      when UP then move(-1)
      when DOWN then move(+1)
      when LEFT then step(-1)
      when RIGHT then step(+1)
      when TAB then take_selection
      when ESC then dismiss
      when *BACKSPACE then erase
      when CTRL_A then jump(0)
      when CTRL_E then jump(@buffer.length)
      when CTRL_U then clear_line
      else insert(key)
      end
    end

    def accept
      return take_selection if menu?

      @history.push(@buffer) unless @buffer.strip.empty? || @history.last == @buffer
      finish_line(@buffer)
    end

    # Enter on a selected item fills in the command but doesn't run it:
    # half the commands take an argument, and running without one would be a surprise.
    def take_selection
      return render unless menu?

      @buffer = +"#{candidates[@selected]} "
      @cursor = @buffer.length
      @dismissed = true
      render
      nil
    end

    def finish_line(value = @buffer)
      @result = value
      :done
    end

    # ── editing the line ─────────────────────────────────────────────────────

    # Unrecognized control sequences are silently dropped: inserted into
    # the line, they'd turn into garbage.
    def insert(key)
      return nil if key.length > 1 || key.ord < 0x20

      @buffer.insert(@cursor, key)
      @cursor += key.length
      @dismissed = false
      @selected = 0
      render
      nil
    end

    def erase
      return render if @cursor.zero?

      @buffer.slice!(@cursor - 1)
      @cursor -= 1
      @selected = 0
      render
      nil
    end

    def clear_line
      @buffer = +""
      @cursor = 0
      render
      nil
    end

    def step(delta)
      @cursor = (@cursor + delta).clamp(0, @buffer.length)
      render
      nil
    end

    def jump(position)
      @cursor = position
      render
      nil
    end

    # ── list and history ──────────────────────────────────────────────────

    def move(delta)
      return history(delta) unless menu?

      @selected = (@selected + delta) % candidates.size
      render
      nil
    end

    def history(delta)
      @history_at = (@history_at + delta).clamp(0, @history.size)
      @buffer = +(@history[@history_at] || "")
      @cursor = @buffer.length
      render
      nil
    end

    def dismiss
      @dismissed = true
      render
      nil
    end

    # The list only shows for a line starting with a slash and no space
    # yet: after that come arguments, and a hint there would just get in the way.
    def menu?
      return false if @dismissed || !@buffer.start_with?("/") || @buffer.include?(" ")

      !candidates.empty?
    end

    # A copy, not the buffer itself: the line is edited in place, and a
    # reference to it would always equal itself — the cache would never invalidate.
    def candidates
      if @candidates_source != @buffer
        @candidates_source = @buffer.dup
        @candidates_for = Array(@completer.call(@buffer))
      end

      @candidates_for
    end

    # ── drawing ─────────────────────────────────────────────────────────────

    def render
      erase_drawn
      @out.print("\r#{@prompt}#{@buffer}")

      rows = menu? ? draw_menu : 0
      @out.print("\e[#{rows}A") if rows.positive?
      @out.print("\r\e[#{visible_width(@prompt) + @cursor}C") if visible_width(@prompt) + @cursor > 0

      @drawn = rows
      nil
    end

    def erase_drawn
      @out.print("\r\e[J")
    end

    def draw_menu
      window.each_with_index do |item, index|
        line = " #{item.ljust(12)} #{@describer.call(item)}".rstrip
        @out.print("\r\n")
        @out.print(item == candidates[@selected] ? "\e[7m#{line}\e[0m" : line)
      end

      window.size
    end

    # The scroll window: the selected item is always visible, even if
    # there are more commands than fit.
    def window
      return candidates if candidates.size <= WINDOW

      top = (@selected - WINDOW / 2).clamp(0, candidates.size - WINDOW)
      candidates[top, WINDOW]
    end

    def visible_width(text) = text.gsub(/\e\[[0-9;]*[A-Za-z]/, "").length

    def finish
      erase_drawn
      @out.print("\r#{@prompt}#{@buffer}\r\n")
      @out.flush
    end

  end
end
