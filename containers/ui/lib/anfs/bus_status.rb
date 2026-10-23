# frozen_string_literal: true

module Anfs
  # The bus's state for the pages: connecting, connected, or unreachable (why, and when the next
  # try is). It logs one line per change of state and tells the hub ("bus").
  class BusStatus
    State = Data.define(:state, :since, :detail, :retry_at) do
      def connected? = state == :connected
    end

    def initialize(hub: nil, log: ->(line) { warn line })
      @hub = hub
      @log = log
      @mutex = Mutex.new
      @current = State.new(state: :connecting, since: Time.now, detail: nil, retry_at: nil)
    end

    def current = @mutex.synchronize { @current }

    # Only the first time: a retry while unreachable stays unreachable (no flicker, no log line).
    def connecting(url)
      change(:connecting, url, nil) if current.state == :connecting
    end

    def connected(url) = change(:connected, url, nil)

    def unreachable(detail, retry_in) = change(:unreachable, detail, Time.now + retry_in)

    private

    # Logged only when the state itself changes: a bus down for an hour is one line, not one per try.
    def change(state, detail, retry_at)
      previous = nil
      @mutex.synchronize do
        previous = @current
        same = previous.state == state
        @current = State.new(state:, since: same ? previous.since : Time.now, detail:, retry_at:)
      end
      @log.call("anfs-ui: bus #{state}: #{detail}") unless previous.state == state || state == :connecting
      @hub&.publish("bus")
    end
  end
end
