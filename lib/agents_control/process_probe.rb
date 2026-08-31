# frozen_string_literal: true

module AgentsControl
  # Who's actually running in each tab.
  #
  # A tab's title can't be trusted: Claude Code sets it via an OSC
  # sequence, and the title stays up after the process exits.
  #
  # One `ps -A` call for the whole process tree instead of a separate
  # `ps -t` per tab.
  class ProcessProbe
    # Processes with no controlling terminal. This is what an agent
    # session launched from the VS Code extension looks like: it has no
    # tab at all.
    NO_TTY = "??"

    # An agent is identified by the basename of its executable: in a
    # terminal that's `claude`; in VS Code it's a long path into the
    # extension's directory.
    AGENT_BINARIES = {
      "claude" => :claude_code,
      "codex" => :codex
    }.freeze

    Process = Struct.new(:tty, :pid, :stat, :command, keyword_init: true) do
      # `+` in the stat column marks a process in the foreground group —
      # i.e. what the user is currently interacting with.
      def foreground? = stat.to_s.include?("+")
      def name = File.basename(command.to_s)
      def agent = AGENT_BINARIES[name]
      def agent? = !agent.nil?
      def terminal? = tty != NO_TTY
    end

    def initialize(executor: Executor.new)
      @executor = executor
    end

    # Re-reads the process tree. The result is cached on the object — one
    # probe per registry pass.
    def refresh
      result = @executor.run(Which.find!("ps"), "-A", "-o", "tty=,pid=,stat=,comm=")
      @processes = result.success? ? parse(result.stdout) : []
      self
    end

    def processes
      @processes || refresh.processes
    end

    # A tab's processes, in launch order.
    def for_tty(tty)
      by_tty.fetch(normalize(tty), [])
    end

    # What's currently in the foreground of a tab. This is what the user sees.
    def foreground(tty)
      candidates = for_tty(tty)
      candidates.reverse.find(&:foreground?) || candidates.last
    end

    # The live agent in a tab — or nil, whatever the title claims.
    def agent_in(tty)
      for_tty(tty).find(&:agent?)
    end

    # Whether an app with this name is running.
    #
    # Deliberately not via pgrep: on macOS `pgrep -x` matches against the
    # full path rather than the name, and in a restricted environment
    # pgrep can miss processes that ps sees fine. We already have the
    # list — this is a filter over existing data, not another call.
    def running?(name)
      processes.any? { |process| process.name == name }
    end

    # Agents with no tab: VS Code sessions and anything else terminalless.
    def terminalless_agents
      processes.select { |process| process.agent? && !process.terminal? }
    end

    # Working directories of processes: { pid => path }.
    #
    # For a tabless session this is the only way to give it a human name —
    # there's no title and no cwd from a terminal. One lsof call for all
    # pids at once (0.027s), not one call per pid.
    def cwds(pids)
      pids = Array(pids).compact.uniq
      return {} if pids.empty?

      lsof = Which.find("lsof")
      return {} unless lsof

      result = @executor.run(lsof, "-a", "-d", "cwd", "-p", pids.join(","), "-Fn")
      # We may lack permission for someone else's processes — that's fine, return what we have.
      result.success? ? parse_lsof(result.stdout) : {}
    end

    private

    # -F format: lines with a single-letter prefix. `p` is pid, `n` is
    # filename. An `n` value belongs to the most recently seen `p`.
    def parse_lsof(output)
      current = nil

      output.each_line.with_object({}) do |line, found|
        line = line.chomp
        case line[0]
        when "p" then current = line[1..].to_i
        when "n" then found[current] = line[1..] if current && !found.key?(current)
        end
      end
    end

    def by_tty
      @by_tty ||= processes.group_by(&:tty)
    end

    # macOS prints `ttys017`, but elsewhere the same tty is called
    # `/dev/ttys017` or `s017` — normalize to one form.
    def normalize(tty)
      return NO_TTY if tty.nil? || tty.empty?

      tty.sub(%r{\A/dev/}, "")
    end

    def parse(output)
      output.each_line.filter_map do |line|
        tty, pid, stat, command = line.strip.split(/\s+/, 4)
        next if command.nil?

        Process.new(tty: normalize(tty), pid: pid.to_i, stat: stat, command: command)
      end
    end
  end
end
