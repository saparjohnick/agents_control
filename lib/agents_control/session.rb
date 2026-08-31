# frozen_string_literal: true

module AgentsControl
  # One session — a terminal tab, or an agent with no terminal at all.
  #
  # Deliberately knows nothing about Claude or iTerm2: this is the common
  # denominator the core and Telegram operate on. Anything backend-specific
  # lives in the adapters.
  class Session
    attr_reader :id, :backend, :tty, :title, :cwd, :agent, :agent_pid, :foreground_command

    def initialize(id:, backend: nil, tty: nil, title: nil, cwd: nil,
                   processing: nil, at_shell_prompt: nil,
                   agent: nil, agent_pid: nil, foreground_command: nil)
      @id = id
      @backend = backend
      @tty = tty
      @title = title
      @cwd = cwd
      @processing = processing
      @at_shell_prompt = at_shell_prompt
      @agent = agent
      @agent_pid = agent_pid
      @foreground_command = foreground_command
    end

    # Terminal is busy working. iTerm2 has `is processing`; tmux has no
    # direct equivalent, so the value can be nil — "unknown", not "no".
    def processing? = @processing == true

    def at_shell_prompt? = @at_shell_prompt == true

    # Agent presence is confirmed by the process tree, not the tab title.
    def agent? = !@agent.nil?

    # A session without a tab: launched from VS Code or another GUI
    # client. Can't be controlled through a terminal, only reached via hooks.
    def terminalless? = @backend.nil? || @tty.nil?

    # Short name for the Telegram list: the directory name is more
    # informative than a full path or a title that may be stale.
    def label
      return File.basename(cwd) if cwd && !cwd.empty?
      return title if title && !title.empty?

      id.to_s
    end

    def with(**attrs)
      Session.new(**to_h.merge(attrs))
    end

    def to_h
      {
        id: id, backend: backend, tty: tty, title: title, cwd: cwd,
        processing: @processing, at_shell_prompt: @at_shell_prompt,
        agent: agent, agent_pid: agent_pid, foreground_command: foreground_command
      }
    end

    def ==(other) = other.is_a?(Session) && other.to_h == to_h
    alias eql? ==

    def hash = to_h.hash
  end
end
