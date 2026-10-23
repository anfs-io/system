# frozen_string_literal: true

module Anfs
  # The latest Result per kind, and when it last differed from the one before.
  class Store
    Snapshot = Data.define(:result, :changed_at)

    def initialize
      @mutex = Mutex.new
      @snapshots = {}
    end

    # True when the result differs from what was held.
    def put(key, result)
      @mutex.synchronize do
        return false if @snapshots[key]&.result == result

        @snapshots[key] = Snapshot.new(result:, changed_at: Time.now)
        true
      end
    end

    # Replaces a kind's result with what the block makes of it, in one step: a list put meanwhile
    # is never overwritten with rows older than it. True when the result changed; the block gets
    # nil before the first result, and returning nil leaves it.
    def update(key)
      @mutex.synchronize do
        old = @snapshots[key]&.result
        result = yield old
        return false if result.nil? || result == old

        @snapshots[key] = Snapshot.new(result:, changed_at: Time.now)
        true
      end
    end

    def [](key) = @mutex.synchronize { @snapshots[key] }

    def rows(key) = self[key]&.result&.rows || []
  end
end
