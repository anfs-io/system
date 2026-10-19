# frozen_string_literal: true

module Anfs
  # Keeps the store current. Each kind is re-read on its own interval, and
  # sooner when the shared anfs log shows somebody running that tool.
  class Poller
    LOG = File.join(ENV.fetch("XDG_STATE_HOME", File.expand_path("~/.local/state")), "anfs/anfs.log")

    # 2026-10-11T16:58:17-0400 pmm[52089] start: up debian-13
    START_LINE = /\s(?<tool>\w+)\[(?<pid>\d+)\] start: (?<command>.*)$/
    READ_ONLY = /\b(list|ls|show|path|ps|builds|docs|status|validate|deps|help|completion|log|callbacks)\b/
    MAX_RUN = 600

    def initialize(store:, hub:, cli: CLI.new, kinds: KINDS.values, log: LOG)
      @store = store
      @hub = hub
      @cli = cli
      @kinds = kinds
      @log = log
      @wake = kinds.to_h { [it.key, Queue.new] }
    end

    def start
      @kinds.each { |kind| Thread.new { poll(kind) } }
      Thread.new { follow_log } if @log
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

    def follow_log
      from_end = true
      loop do
        File.open(@log) do |io|
          io.seek(0, IO::SEEK_END) if from_end
          from_end = false
          tail(io)
        end
      rescue Errno::ENOENT
        sleep 5
      end
    end

    # Returns once the log has been rotated away from under io.
    def tail(io)
      loop do
        if (line = io.gets)
          log_line(line)
        elsif File.stat(@log).ino != io.stat.ino
          return
        else
          sleep 0.5
        end
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
