# frozen_string_literal: true

module Anfs
  # At most one call per key per window: the first after a quiet spell runs at once, and any that
  # come within the window of the last run wait out the rest of it as one run, however many come.
  # The toolkit-api/06 guard, for what events cause.
  class Coalescer
    def initialize(window:)
      @window = window
      @mutex = Mutex.new
      @last = {}
      @pending = {}
    end

    def call(key, &block)
      run = @mutex.synchronize do
        next false if @pending[key]

        rest = @last.key?(key) ? @last[key] + @window - now : 0
        next @last[key] = now unless rest.positive?

        @pending[key] = Thread.new { later(key, rest, block) }
        false
      end
      block.call if run
    end

    private

    def later(key, rest, block)
      sleep rest
      @mutex.synchronize do
        @pending.delete(key)
        @last[key] = now
      end
      block.call
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
