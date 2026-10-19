# frozen_string_literal: true

require "json"
require "socket"
require "tmpdir"

# The toolkit API's side of a connection, in the spec: a TCPServer or a UNIXServer on a temp path.
# Each connection reads an optional token line and one request, then the block answers it with
# `answer.call(hash)` per line. What it received is kept per connection: [[line, ...], ...].
class FakeAPI
  attr_reader :url, :received

  def initialize(transport = :tcp, &handler)
    @handler = handler
    @received = Queue.new
    @server, @url = transport == :tcp ? tcp : unix
    @thread = Thread.new { loop { serve(@server.accept) } }
  end

  def connections(count, timeout: 5) = Array.new(count) { @received.pop(timeout:) }

  def close
    @thread.kill
    @server.close
    FileUtils.rm_rf(@dir) if @dir
  end

  private

  def tcp
    server = TCPServer.new("127.0.0.1", 0)
    [server, "tcp://127.0.0.1:#{server.addr[1]}"]
  end

  def unix
    @dir = Dir.mktmpdir("fake-api")
    path = File.join(@dir, "rpc.sock")
    [UNIXServer.new(path), "unix://#{path}"]
  end

  def serve(io)
    lines = [JSON.parse(io.gets)]
    lines << JSON.parse(io.gets) if lines.first.key?("token")
    @received << lines
    @handler.call(lines.last, ->(answer) { io.write("#{JSON.generate(answer)}\n") })
  rescue IOError, SystemCallError
    nil
  ensure
    io.close
  end
end
