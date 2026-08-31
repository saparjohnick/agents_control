# frozen_string_literal: true

module AgentsControl
  module Terminals
    # iTerm2 via AppleScript.
    #
    # Scripts are passed to osascript over stdin, and parameters via
    # `on run argv`. Values are never interpolated into the script text:
    # identifiers, and especially arbitrary user commands, would
    # otherwise turn into an AppleScript injection.
    #
    # A full scan of sessions via AppleScript is expensive, so the list
    # is built on demand rather than polled on a timer. Agent state
    # comes from hooks, not from here.
    class ITerm2 < Base
      # The session identifier matches the ITERM_SESSION_ID variable that
      # iTerm2 puts in a tab's environment. A hook uses it to tie an
      # agent session to a specific tab.
      LIST = <<~APPLESCRIPT
        on run argv
          set fs to (character id 31)
          set rs to (character id 30)
          set out to ""
          tell application "iTerm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  set out to out & (id of s) & fs & (tty of s) & fs ¬
                    & ((is processing of s) as text) & fs ¬
                    & ((is at shell prompt of s) as text) & fs ¬
                    & (variable s named "path") & fs ¬
                    & (name of s) & rs
                end repeat
              end repeat
            end repeat
          end tell
          return out
        end run
      APPLESCRIPT

      # Shared wrapper: find a session by id and do something with it.
      # %s is substituted right here in the code, never from user input.
      FIND_AND = <<~APPLESCRIPT
        on run argv
          set target_id to item 1 of argv
          tell application "iTerm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if (id of s) is target_id then
                    %s
                    return "ok"
                  end if
                end repeat
              end repeat
            end repeat
          end tell
          return "missing"
        end run
      APPLESCRIPT

      CREATE_TAB = <<~APPLESCRIPT
        on run argv
          set target_dir to item 1 of argv
          set target_cmd to item 2 of argv
          tell application "iTerm2"
            if (count of windows) is 0 then
              set w to (create window with default profile)
            else
              set w to current window
              tell w to create tab with default profile
            end if
            set s to current session of current tab of w
            if target_dir is not "" then
              tell s to write text ("cd " & quoted form of target_dir)
            end if
            if target_cmd is not "" then
              tell s to write text target_cmd
            end if
            return (id of s)
          end tell
        end run
      APPLESCRIPT

      FIELDS = %i[id tty processing at_shell_prompt cwd title].freeze

      def name = :iterm2

      # Checked against the process tree, not via AppleScript: talking to
      # the app over AppleScript launches it if it's closed, and an
      # availability check has no business opening a terminal on the user.
      #
      # pgrep won't do here: on macOS `-x` matches against the full path,
      # and in a restricted environment it misses processes that ps sees fine.
      def available? = probe.running?("iTerm2")

      def sessions
        result = osascript(LIST)
        return [] unless result.success?

        parse_records(result.stdout, FIELDS).map do |record|
          Session.new(
            id: record[:id],
            backend: name,
            tty: record[:tty],
            title: record[:title].to_s.strip,
            cwd: record[:cwd].to_s.strip,
            processing: record[:processing] == "true",
            at_shell_prompt: record[:at_shell_prompt] == "true"
          )
        end
      end

      def create_tab(cwd: nil, command: nil)
        result = osascript(CREATE_TAB, cwd.to_s, command.to_s)
        result.success? ? result.stdout.strip : nil
      end

      def send_text(id, text, newline: true)
        # The text goes in as argv's second argument, not into the script body.
        script = format(FIND_AND, %(tell s to write text (item 2 of argv) newline #{newline}))
        act(script, id, text)
      end

      def capture(id, lines: 200)
        script = format(FIND_AND, "return contents of s")
        result = osascript(script, id)
        return "" unless result.success?

        # AppleScript only hands back the visible area — there's no
        # scrollback here; for history, go to tmux or the agent's transcript.
        #
        # `contents of s` is the whole visible screen, including blank
        # filler lines below the text when it doesn't reach the bottom of
        # the pane. rstrip removes that tail before the .last(lines) cut —
        # otherwise, on a pane taller than its content, the cut would
        # grab only blank lines.
        text = result.stdout.rstrip
        text.empty? ? "" : text.lines.last(lines).join.rstrip
      end

      def focus(id)
        act(format(FIND_AND, "tell t to select\n                    tell w to select"), id)
      end

      def close(id)
        act(format(FIND_AND, "tell s to close"), id)
      end

      private

      def act(script, *args)
        result = osascript(script, *args)
        result.success? && !result.stdout.include?("missing")
      end

      def osascript(script, *args)
        binary = Which.find("osascript")
        return Executor::Result.new(stdout: "", stderr: "osascript not found", status: 127) unless binary

        # Scanning fifteen sessions takes ~0.9s; give it headroom for a
        # slow AppleEvent, but not forever — iTerm2 itself can hang.
        executor.run(binary, "-", *args, stdin: script, timeout: 20)
      end
    end
  end
end
