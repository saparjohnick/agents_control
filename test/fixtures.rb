# frozen_string_literal: true

module AgentsControl
  # Recorded output from real commands on a working machine.
  #
  # Not made up: captured from a session where fifteen iTerm2 tabs, two
  # terminal agents, and three sessions from the VS Code extension were
  # all alive at once. This is where the two cases the whole thing was
  # written for are pinned down: stale tab titles and terminalless agents.
  module Fixtures
    FS = "\x1F"
    RS = "\x1E"

    # ps -A -o tty=,pid=,stat=,comm=
    #
    # Key spots:
    #   ttys002 — the tab title promises an agent, there's no agent process;
    #   ttys017 — an agent is there, but caffeinate is in the foreground;
    #   ??      — three VS Code agents, no tab at all.
    PS = <<~OUTPUT
      ttys000   1731 Ss   /usr/bin/login
      ttys000   1732 S    -zsh
      ttys000   6378 S+   ssh
      ttys002   1746 Ss   /usr/bin/login
      ttys002   1747 S+   -zsh
      ttys017   1900 Ss   /usr/bin/login
      ttys017   1975 S    -zsh
      ttys017   6221 S+   claude
      ttys017  21858 S+   caffeinate
      ttys018   1904 Ss   /usr/bin/login
      ttys018  16252 S+   claude
      ??        1752 S    /Users/devbox/.vscode/extensions/anthropic.claude-code-2.1.226-darwin-arm64/resources/native-binary/claude
      ??        6399 S    /Users/devbox/.vscode/extensions/anthropic.claude-code-2.1.226-darwin-arm64/resources/native-binary/claude
      ??       16141 S    /Users/devbox/.vscode/extensions/anthropic.claude-code-2.1.226-darwin-arm64/resources/native-binary/claude
      ??        1283 Ss   /usr/libexec/secinitd
      ??        1690 S    /Applications/iTerm.app/Contents/MacOS/iTerm2
      ??        1691 S    /Users/devbox/Library/Application Support/iTerm2/iTermServer-3.6.10
    OUTPUT

    # Same tree, but the terminal app is closed.
    PS_WITHOUT_ITERM = PS.lines.grep_v(/iTerm/).join

    # lsof -a -d cwd -p ... -Fn
    LSOF = <<~OUTPUT
      p1752
      fcwd
      n/Users/devbox/projects/flightlog
      p6399
      fcwd
      n/Users/devbox/projects/flightlog
      p16141
      fcwd
      n/Users/devbox/projects/flightlog
    OUTPUT

    # osascript: id, tty, is processing, is at shell prompt, path, name
    #
    # ttys002 — the stale tab: the agent icon in the title is left over
    # from a long-closed session. What must be checked is the process
    # tree, not this line.
    ITERM_ROWS = [
      ["D63D6009-F477-44EE-B890-54C1B30E8B69", "/dev/ttys000", "false", "false",
       "/Users/devbox", "dev@relay:~ (ssh)"],
      ["AD9E50DB-91C0-4966-994C-62091639B101", "/dev/ttys002", "false", "true",
       "/Users/devbox/projects/mobile-app", "✳ Audit unnecessary backend requests (-zsh)"],
      ["C0172CE5-4114-4B74-8E49-D45A3EB6187A", "/dev/ttys017", "false", "false",
       "/Users/devbox/projects/backend_api", "✳ Claude Code (claude)"],
      ["B4760369-F196-4D97-B410-7FDDF5AD67D5", "/dev/ttys018", "true", "false",
       "/Users/devbox/projects/agents_control",
       "⠐ Claude Code session monitor (caffeinate)"]
    ].freeze

    ITERM = ITERM_ROWS.map { |row| row.join(FS) + RS }.join

    # tmux list-panes -a -F: pane_id, tty, command, path, session, window
    TMUX_ROWS = [
      ["%0", "/dev/ttys011", "zsh", "/Users/devbox/projects/agents_control", "work", "editor"],
      ["%3", "/dev/ttys014", "claude", "/Users/devbox/projects/flightlog", "work", "agent"]
    ].freeze

    TMUX = TMUX_ROWS.map { |row| row.join(FS) + RS }.join

    # ── Claude Code hook payloads ───────────────────────────────────────
    #
    # Captured from a live session by a probe, not transcribed from the
    # docs — they've drifted: the reference promises a `toolResult` field
    # in PostToolUse, reality sends `tool_response`.

    # Session identifier for backend_api from ITERM_ROWS — needed by
    # tests that must target a response at its capture call specifically,
    # not at every osascript request at once.
    BACKEND_API_ID = "C0172CE5-4114-4B74-8E49-D45A3EB6187A"

    SESSION = "b5d47815-19d1-4987-8822-20dc80cc1315"
    TRANSCRIPT = "/Users/devbox/.claude/projects/-tmp-probe/#{SESSION}.jsonl"
    CWD = "/Users/devbox/projects/flightlog"

    def self.hook(name, **extra)
      {
        "session_id" => SESSION,
        "transcript_path" => TRANSCRIPT,
        "cwd" => CWD,
        "prompt_id" => "a7ea0a0f-7abc-4fd7-a624-4c477ed005e2",
        "permission_mode" => "default",
        "hook_event_name" => name
      }.merge(extra)
    end

    # End of turn. last_assistant_message carries the full question text —
    # exactly what goes to Telegram, with no screen-reading involved.
    HOOK_STOP = hook("Stop",
                     "stop_hook_active" => false,
                     "last_assistant_message" => "Should I continue the refactor, or show the plan first?",
                     "background_tasks" => [],
                     "session_crons" => [])

    # This turn is already blocked waiting. Answering with another block
    # would produce an infinite loop.
    HOOK_STOP_ACTIVE = HOOK_STOP.merge("stop_hook_active" => true)

    # A question with no subject: answerable without reading any context.
    HOOK_STOP_CONTINUE = HOOK_STOP.merge(
      "last_assistant_message" => "Tests passed. Continue?"
    )

    HOOK_PERMISSION = hook("PermissionRequest",
                           "tool_name" => "Bash",
                           "tool_input" => { "command" => "npm run build" },
                           "tool_use_id" => "toolu_019UQR6nzKGa1ZfbLtN2sGiJ")

    HOOK_PERMISSION_DANGEROUS = hook("PermissionRequest",
                                     "tool_name" => "Bash",
                                     "tool_input" => { "command" => "rm -rf build/" },
                                     "tool_use_id" => "toolu_02")

    HOOK_SESSION_START = hook("SessionStart", "source" => "startup")

    HOOK_SESSION_END = hook("SessionEnd", "reason" => "prompt_input_exit")

    HOOK_RATE_LIMIT = hook("StopFailure",
                           "error" => "usage limit reached",
                           "errorType" => "rate_limit")

    HOOK_NOTIFICATION = hook("Notification",
                             "notificationType" => "agent_completed",
                             "message" => "Task complete")

    # A transcript in the JSONL format Claude Code writes.
    TRANSCRIPT_LINES = [
      { "type" => "user", "message" => { "role" => "user", "content" => "fix the build" } },
      { "type" => "assistant",
        "message" => { "role" => "assistant",
                       "content" => [{ "type" => "text", "text" => "Looking at the logs." },
                                     { "type" => "tool_use", "name" => "Bash", "input" => {} }] } },
      { "type" => "assistant",
        "message" => { "role" => "assistant",
                       "content" => [{ "type" => "text",
                                       "text" => "Should I continue, or show the plan?" }] } }
    ].map { |entry| JSON.generate(entry) }.join("\n")
  end
end
