# frozen_string_literal: true

module Anfs
  # The containers kind kept current from 02c's container.* events, with no command run: an
  # event names a container (its subject) of a pcm service (data.pcm, the io.pcm.name label),
  # and the service's row in `pcm list` gets the status pcm itself would give it: running when
  # one of its containers runs, stopped when some exist and none runs, nil (not created) when none
  # is left.
  #
  # A service's containers are known from the events since the last list. A service with several
  # containers, one of which stops on its own, reads stopped until the next list (pcm down and
  # up move them all, so those read right).
  class ContainerRows
    KEY = "containers"
    STATES = { "started" => :running, "unpaused" => :running, "created" => :stopped, "died" => :stopped,
               "stopped" => :stopped, "paused" => :stopped, "removed" => nil }.freeze

    def initialize(store:)
      @store = store
      @mutex = Mutex.new
      @known = Hash.new { |hash, name| hash[name] = {} } # name => {container => [state, at]}
    end

    # verb: the type's last word. True when a row changed.
    def apply(verb, event)
      return false unless STATES.key?(verb)

      name = event.dig("data", "pcm").to_s
      container = event["subject"].to_s
      return false if name.empty? || container.empty?

      @mutex.synchronize { @known[name][container] = [STATES[verb], now] }
      update(name)
    end

    # After a list that began at `since`: what came before it is in the list, and what came
    # while it ran is applied again over it. How many rows that changed.
    def listed(since)
      names = @mutex.synchronize do
        @known.each_value { |containers| containers.reject! { |_, (_, at)| at < since } }
        @known.reject! { |_, containers| containers.empty? }
        @known.keys
      end
      names.count { update(it) }
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    private

    def update(name)
      status = status(name)
      @store.update(KEY) do |result|
        index = result&.ok? && result.rows.index { |row| row_for?(row, name) }
        next unless index

        rows = result.rows.dup
        rows[index] = rows[index].merge("status" => status)
        result.with(rows:)
      end
    end

    # The definition that wins the name (pcm marks the others shadowed).
    def row_for?(row, name)
      row["container"].to_s.split("/", 2).last == name && !row["status"].to_s.include?("shadowed")
    end

    def status(name)
      states = @mutex.synchronize { @known[name].values.map(&:first) }
      if states.include?(:running) then "running"
      elsif states.include?(:stopped) then "stopped"
      end
    end
  end
end
