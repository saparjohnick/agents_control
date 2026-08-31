# frozen_string_literal: true

module AgentsControl
  # A list navigated with arrow keys.
  #
  # Needed wherever picking is more natural than typing: settings are
  # shown with human-readable names, and requiring the internal name
  # instead would be a trap. See a row, hit Enter, it changes in place.
  class Menu
    include Keyboard

    HINT = "↑↓ — select · Enter — toggle · Esc — exit"

    def initialize(input: $stdin, output: $stdout)
      @in = input
      @out = output
    end

    # rows — something callable: the row list is re-read after every
    # change, or the screen would keep showing the old value.
    #
    # The block receives the index of the selected row.
    def run(title:, rows:)
      @rows = rows
      @items = nil
      @selected = 0
      @drawn = 0

      @in.raw do
        loop do
          draw(title)
          break unless step(read_key) { |index| yield(index) }
        end
      end

      nil
    ensure
      finish
    end

    private

    # Returns false when it's time to close the menu.
    def step(key)
      case key
      # "й" is the same physical key as "q" on a ЙЦУКЕН layout — quits
      # without forcing a layout switch just to press q.
      when nil, ESC, CTRL_C, CTRL_D, "q", "й" then return false
      when UP then move(-1)
      when DOWN then move(+1)
      when *ENTER then activate { |index| yield(index) }
      end

      true
    end

    def move(delta)
      return if items.empty?

      @selected = (@selected + delta) % items.size
    end

    def activate
      return if items.empty?

      yield(@selected)
      # Values changed — re-read the list, or the screen would keep showing the old one.
      @items = nil
    end

    def items
      @items ||= Array(@rows.call)
    end

    def draw(title)
      rewind
      lines = [title, ""] + rendered_items + ["", HINT]
      @out.print(lines.join("\r\n"))
      @drawn = lines.size - 1
    end

    def rendered_items
      items.each_with_index.map do |line, index|
        index == @selected ? "\e[7m #{line} \e[0m" : " #{line} "
      end
    end

    # Rewind to the start of what was drawn and clear it: redrawn in
    # full, so there's no need to track each line's length separately.
    def rewind
      @out.print("\e[#{@drawn}A") if @drawn.positive?
      @out.print("\r\e[J")
    end

    def finish
      rewind
      @out.flush
    end
  end
end
