# frozen_string_literal: true

module Anfs
  # Fan-out of "this kind changed" to every open event stream.
  class Hub
    def initialize
      @mutex = Mutex.new
      @queues = []
    end

    def subscribe = Queue.new.tap { |queue| @mutex.synchronize { @queues << queue } }

    def unsubscribe(queue) = @mutex.synchronize { @queues.delete(queue) }

    def publish(key) = @mutex.synchronize { @queues.each { it << key } }

    def size = @mutex.synchronize { @queues.size }
  end
end
