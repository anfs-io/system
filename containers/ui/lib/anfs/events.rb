# frozen_string_literal: true

module Anfs
  # What the poller follows to hear that somebody ran a tool: the toolkit API's watch events
  # when there is an API, else the tools' shared log on the host. Both run forever.
  def self.events(rpc = RPC.from_env) = rpc ? Watch.new(rpc) : LogFollower.new(LogFollower::LOG)

  # Yields each event hash of a {"watch":true} connection, and reconnects after a drop, waiting
  # longer each time until an event comes through.
  class Watch
    BACKOFF = [1, 2, 5, 10, 30].freeze

    def initialize(rpc, backoff: BACKOFF)
      @rpc = rpc
      @backoff = backoff
    end

    def each(&)
      failures = 0
      loop do
        @rpc.watch { yield(it).tap { failures = 0 } }
      rescue RPC::Error => e
        warn "anfs-ui: watch: #{e.message}" if failures.zero?
        sleep @backoff.fetch(failures, @backoff.last)
        failures += 1
      end
    end
  end

  # Yields each new line of anfs.log, across rotations and before it exists.
  class LogFollower
    LOG = File.join(ENV.fetch("XDG_STATE_HOME", File.expand_path("~/.local/state")), "anfs/anfs.log")

    def initialize(path)
      @path = path
    end

    def each(&)
      from_end = true
      loop do
        File.open(@path) do |io|
          io.seek(0, IO::SEEK_END) if from_end
          from_end = false
          tail(io, &)
        end
      rescue Errno::ENOENT
        sleep 5
      end
    end

    private

    # Returns once the log has been rotated away from under io.
    def tail(io)
      loop do
        if (line = io.gets)
          yield line
        elsif File.stat(@path).ino != io.stat.ino
          return
        else
          sleep 0.5
        end
      end
    end
  end
end
