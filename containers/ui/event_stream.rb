# frozen_string_literal: true

# A Rack streaming body: one server-sent-events connection, held open for as
# long as the page is. It sends one component as a Turbo Stream on connect
# and again whenever something it depends on changes.
class EventStream
  HEADERS = { "content-type" => "text/event-stream", "cache-control" => "no-cache" }.freeze

  # target is the DOM id to replace; keys are the hub keys to follow (nil for
  # all of them); the block builds the component afresh each time.
  def initialize(hub:, target:, keys:, keepalive: 15, &content)
    @hub = hub
    @target = target
    @keys = keys
    @keepalive = keepalive
    @content = content
  end

  def call(stream)
    queue = @hub.subscribe
    stream.write(event)
    loop { stream.write(relevant?(changes(queue)) ? event : ": keepalive\n\n") }
  rescue IOError, SystemCallError
    nil # the browser went away
  ensure
    @hub.unsubscribe(queue)
    stream.close
  end

  private

  # Waits for a change and takes any others already queued, so a burst is
  # one render. [nil] when nothing came.
  def changes(queue)
    keys = [queue.pop(timeout: @keepalive)]
    keys << queue.pop until queue.empty?
    keys
  end

  def relevant?(keys) = keys.any? { |key| key && (@keys.nil? || @keys.include?(key)) }

  def event
    html = Views::Stream.new(target: @target, content: @content.call).call
    "#{html.each_line.map { "data: #{it.chomp}\n" }.join}\n"
  end
end
