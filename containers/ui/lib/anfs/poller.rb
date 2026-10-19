# frozen_string_literal: true

module Anfs
  # Keeps the store current. Each kind is re-read on its own interval, and
  # sooner when somebody runs that tool: the toolkit API's watch events, or on
  # the host the shared anfs log.
  class Poller
    # 2026-10-11T16:58:17-0400 pmm[52089] start: up debian-13
    START_LINE = /\s(?<tool>\w+)\[(?<pid>\d+)\] start: (?<command>.*)$/
    READ_ONLY = /\b(list|ls|show|path|ps|builds|docs|status|validate|deps|help|completion|log|callbacks)\b/
    MAX_RUN = 600

    # events: Anfs.events, a Watch or a LogFollower; nil for none.
    def initialize(store:, hub:, cli: CLI.new, kinds: KINDS.values, events: Anfs.events)
      @store = store
      @hub = hub
      @cli = cli
      @kinds = kinds
      @events = events
      @wake = kinds.to_h { [it.key, Queue.new] }
      @writes = Set.new
    end

    def start
      @kinds.each { |kind| Thread.new { poll(kind) } }
      Thread.new { @events.each { it.is_a?(Hash) ? event(it) : log_line(it) } } if @events
      self
    end

    def refresh(kind)
      @hub.publish(kind.key) if @store.put(kind.key, @cli.run(kind.tool, *kind.args))
    end

    # anfs itself changes sources, which every tool reads.
    def nudge(tool)
      @kinds.each { |kind| @wake[kind.key] << true if tool == "anfs" || kind.tool == tool }
    end

    # A start line only says a command began. Refresh now, and again once its
    # process is gone, which is when the change it made is complete.
    def log_line(line)
      match = START_LINE.match(line)
      return if match.nil? || READ_ONLY.match?(match[:command])

      nudge(match[:tool])
      Thread.new do
        wait_for_exit(Integer(match[:pid]))
        nudge(match[:tool])
      end
    end

    # A watch event: refresh when a command that changes something starts, and again when it ends.
    def event(event)
      tool = event["tool"]
      case event["event"]
      when "start"
        return if READ_ONLY.match?(event["args"].to_s)

        @writes << event["id"]
        nudge(tool)
      when "end"
        nudge(tool) if @writes.delete?(event["id"])
      end
    end

    private

    def poll(kind)
      loop do
        refresh(kind)
        @wake[kind.key].pop(timeout: kind.every)
        @wake[kind.key].clear
      rescue StandardError => e
        warn "anfs-ui: #{kind.key}: #{e.class}: #{e.message}"
        sleep kind.every
      end
    end

    def wait_for_exit(pid)
      deadline = Time.now + MAX_RUN
      while Time.now < deadline
        Process.kill(0, pid)
        sleep 0.25
      end
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
