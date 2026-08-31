# frozen_string_literal: true

module AgentsControl
  module Terminals
    # tmux.
    #
    # The only backend that works on both macOS and Linux, and also the
    # fastest one: a full pane list comes back in 0.008s versus 0.9s for
    # iTerm2 — a hundred-plus-fold difference. It's also the only one with
    # scrollback and the only one that survives an ssh disconnect.
    #
    # Inside iTerm2 it runs as `tmux -CC`: tmux windows become native
    # tabs, and both backends operate on the same machine at once.
    class Tmux < Base
      # %w doesn't interpolate — the literal tmux substitutions stay intact inside.
      FORMAT_FIELDS = %w[
        #{pane_id}
        #{pane_tty}
        #{pane_current_command}
        #{pane_current_path}
        #{session_name}
        #{window_name}
      ].freeze

      FIELDS = %i[id tty command cwd session window].freeze

      # Shells under which a pane counts as "at a prompt" rather than busy.
      SHELLS = %w[zsh bash sh fish dash ksh tcsh].freeze

      def name = :tmux

      # Just having the binary is enough: the server might not be
      # running yet, but we can still create a window in it.
      def available? = !binary.nil?

      def sessions
        return [] unless available?

        result = run("list-panes", "-a", "-F", format_string)
        # No server isn't an error, it just means there are no panes yet.
        return [] unless result.success?

        parse_records(result.stdout, FIELDS).map do |record|
          Session.new(
            id: record[:id],
            backend: name,
            tty: record[:tty],
            title: [record[:session], record[:window]].compact.join(":"),
            cwd: record[:cwd],
            # tmux has no equivalent of `is processing`, so this is nil —
            # "unknown", not "no". ProcessProbe determines busy-ness.
            processing: nil,
            at_shell_prompt: SHELLS.include?(record[:command].to_s),
            # tmux already knows what's running in the pane — this same
            # list-panes call hands back the process name for free, with
            # no trip through ProcessProbe needed.
            foreground_command: record[:command]
          )
        end
      end

      def create_tab(cwd: nil, command: nil)
        args = ["new-window", "-P", "-F", "#{'#'}{pane_id}"]
        args += ["-c", cwd] if cwd && !cwd.empty?
        args << command if command && !command.empty?

        result = run(*args)
        result.success? ? result.stdout.strip : nil
      end

      def send_text(id, text, newline: true)
        args = ["send-keys", "-t", id, "--", text]
        args << "Enter" if newline
        run(*args).success?
      end

      # This is exactly what tmux is for: history, not just the visible screen.
      def capture(id, lines: 200)
        result = run("capture-pane", "-p", "-t", id, "-S", "-#{lines}")
        result.success? ? result.stdout.rstrip : ""
      end

      def focus(id)
        run("select-window", "-t", id).success? && run("select-pane", "-t", id).success?
      end

      def close(id) = run("kill-pane", "-t", id).success?

      private

      def format_string = FORMAT_FIELDS.join(FIELD) + RECORD

      def run(*args)
        return Executor::Result.new(stdout: "", stderr: "tmux not found", status: 127) unless binary

        executor.run(binary, *args)
      end

      def binary
        # false means "looked and didn't find it", so we don't search again on every call.
        @binary = Which.find("tmux") || false if @binary.nil?
        @binary || nil
      end
    end
  end
end
