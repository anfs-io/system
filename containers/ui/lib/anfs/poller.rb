# frozen_string_literal: true

module Anfs
  # Keeps the store current. Every kind is listed at start and then every `every` seconds (a slow
  # reconcile), and again when a command run from here ends. In between the bus's events update
  # the kind they name, and only it: container.* from the event's data (no command), the others
  # with one read of their kind. No event re-reads another kind, or everything.
  #
  # Both coalesce (COALESCE): a kind's read runs at once on the first nudge after a quiet spell,
  # then at most once per window however many follow, and so does the re-render an event causes.
  # Nothing an event does can spin the poller (toolkit-api/06).
  class Poller
    COALESCE = 2
    # Which kind an event re-reads, when its data does not say the row's new state.
    READS = { "podman.connected" => "containers", "podman.disconnected" => "containers",
              "source.updated" => "sources" }.freeze

    # What the bus delivered lately, for the events page.
    attr_reader :events

    # bus: an Anfs::Bus (its run yields events), or nil for none.
    def initialize(store:, hub:, cli: CLI.new, kinds: KINDS.values, bus: nil)
      @store = store
      @hub = hub
      @cli = cli
      @kinds = kinds
      @bus = bus
      @events = EventLog.new
      @wake = kinds.to_h { [it.key, Queue.new] }
      @containers = ContainerRows.new(store:)
      @renders = Coalescer.new(window: COALESCE)
    end

    # Each kind is listed at once, then its reconciles are spread over the interval (the first
    # after its share of it), so the API sees one list every ~33 s, not nine at a time.
    def start
      @kinds.each_with_index { |kind, i| Thread.new { poll(kind, kind.every * (i + 1) / @kinds.size) } }
      Thread.new { @bus.run { apply(it) } } if @bus
      self
    end

    def refresh(kind)
      since = @containers.now
      changed = @store.put(kind.key, @cli.run(kind.tool, *kind.args))
      changed = @containers.listed(since).positive? || changed if kind.key == ContainerRows::KEY
      @hub.publish(kind.key) if changed
    end

    # A command run from here has ended: re-read the kinds its tool lists.
    def nudge(tool)
      @kinds.each { |kind| wake(kind.key) if kind.tool == tool }
    end

    # One event from the bus.
    def apply(event)
      @events.add(event)
      publish("events")
      type = event["type"].to_s.delete_prefix("io.anfs.")
      noun, verb = type.split(".", 2)
      if noun == "container"
        publish(ContainerRows::KEY) if @containers.apply(verb, event)
      elsif (key = READS[type])
        wake(key)
      end
    end

    private

    def wake(key) = @wake[key]&.<<(true)

    def publish(key) = @renders.call(key) { @hub.publish(key) }

    # A nudge within COALESCE of the last refresh waits out the rest of it, and every nudge that
    # comes meanwhile rides along.
    def poll(kind, first)
      timeout = first
      loop do
        last = now
        refresh(kind)
        wait(kind, last, timeout)
        timeout = kind.every
      rescue StandardError => e
        warn "anfs-ui: #{kind.key}: #{e.class}: #{e.message}"
        sleep kind.every
      end
    end

    def wait(kind, last, timeout)
      return unless @wake[kind.key].pop(timeout:)

      rest = last + COALESCE - now
      sleep rest if rest.positive?
      @wake[kind.key].clear
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
