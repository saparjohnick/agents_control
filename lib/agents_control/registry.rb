# frozen_string_literal: true

module AgentsControl
  # A unified session list assembled from disparate sources.
  #
  # There are three sources, and they complement each other:
  #
  #   1. terminal backends — iTerm2 tabs and tmux panes;
  #   2. the process tree — who's actually alive in those tabs;
  #   3. terminalless agent processes — VS Code sessions, which have no tab.
  #
  # Source (1) without (2) lies: a tab's title stays up after the agent
  # exits. Source (3) without special handling just gets lost — VS Code
  # sessions aren't a rare edge case, they're often the majority of active
  # sessions.
  class Registry
    def initialize(backends: nil, probe: nil, executor: Executor.new)
      @executor = executor
      @backends = backends || default_backends
      @probe = probe || ProcessProbe.new(executor: executor)
    end

    # Every session: terminal tabs plus terminalless agents.
    def sessions
      @sessions ||= begin
        probe.refresh
        enrich(terminal_sessions) + terminalless_sessions
      end
    end

    # Only sessions with a confirmed live agent.
    # This is the list that goes to Telegram by default.
    def agents = sessions.select(&:agent?)

    def find(id) = sessions.find { |session| session.id == id }

    # The backend that can control this session.
    def backend_for(session)
      backends.find { |backend| backend.name == session.backend } || null_backend
    end

    # Drop the cache — the registry is rebuilt on demand, not held in memory.
    def refresh
      @sessions = nil
      self
    end

    def available_backends = backends.select(&:available?)

    private

    attr_reader :backends, :probe, :executor

    # The probe is shared: the process tree is read once per registry pass,
    # not separately by each backend.
    def default_backends
      [
        Terminals::ITerm2.new(executor: executor, probe: probe),
        Terminals::Tmux.new(executor: executor, probe: probe)
      ]
    end

    def null_backend
      @null_backend ||= Terminals::Null.new(executor: executor)
    end

    def terminal_sessions
      available_backends.flat_map do |backend|
        backend.sessions
      rescue StandardError
        # One backend failing must not take down the whole list: without
        # iTerm2 we can still show tmux panes.
        []
      end
    end

    # The tab title is already available at this point, but it can't be
    # trusted — only the process tree confirms an agent.
    def enrich(list)
      list.map do |session|
        agent = probe.agent_in(session.tty)
        foreground = probe.foreground(session.tty)

        session.with(
          agent: agent&.agent,
          agent_pid: agent&.pid,
          foreground_command: foreground&.name
        )
      end
    end

    # A tabless session has neither a title nor a cwd from the terminal,
    # so the directory comes from the process itself — otherwise the list
    # would show three nameless rows.
    def terminalless_sessions
      found = probe.terminalless_agents
      return [] if found.empty?

      paths = probe.cwds(found.map(&:pid))

      found.map do |process|
        Session.new(
          id: "pid:#{process.pid}",
          backend: nil,
          tty: nil,
          title: nil,
          cwd: paths[process.pid],
          agent: process.agent,
          agent_pid: process.pid,
          foreground_command: process.name
        )
      end
    end
  end
end
