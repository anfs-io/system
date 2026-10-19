# frozen_string_literal: true

require "json"
require "socket"
require "uri"

module Anfs
  # A client of the toolkit API (`anfs rpc` behind the listener): JSON lines over tcp:// or
  # unix://. One connection per request, as the listener starts one `anfs rpc` per connection.
  # The token line goes first when there is a token; without one (a unix socket) none is sent.
  class RPC
    class Error < StandardError; end

    # The one switch between the two modes: nil when ANFS_RPC_URL is not set, and the tools are
    # then run from ANFS_BIN (on the host, while developing).
    def self.from_env(env = ENV)
      url = env["ANFS_RPC_URL"].to_s
      new(url, token: env["ANFS_RPC_TOKEN"]) unless url.empty?
    end

    attr_reader :url

    def initialize(url, token: nil, timeout: 90)
      @url = url
      @token = token.to_s.empty? ? nil : token
      @timeout = timeout
      @target = parse(url)
    end

    # One request and its answer. With a block, each {"out":...} line is yielded until the last
    # answer, which is returned (a stream has no timeout).
    def call(request, &)
      connect do |io|
        send_lines(io, request)
        io.timeout = @timeout unless block_given?
        read_answer(io, &)
      end
    end

    # Yields each event until the connection drops, which raises.
    def watch
      connect do |io|
        send_lines(io, { watch: true })
        each_answer(io) do |answer|
          raise Error, answer["error"] if answer["error"]

          yield answer if answer["event"]
        end
        raise Error, "the toolkit API closed the connection"
      end
    end

    private

    def parse(url)
      uri = URI(url)
      case uri.scheme
      when "tcp" then [:tcp, uri.host, uri.port]
      when "unix" then [:unix, uri.path]
      else raise ArgumentError, "ANFS_RPC_URL is tcp://host:port or unix:///path, not #{url}"
      end
    end

    def connect
      io = @target.first == :tcp ? Socket.tcp(*@target.drop(1), connect_timeout: 5) : UNIXSocket.new(@target.last)
      yield io
    rescue SystemCallError, IOError, SocketError => e
      raise Error, "the toolkit API at #{@url}: #{e.message}"
    ensure
      io&.close
    end

    def send_lines(io, request)
      io.write("#{JSON.generate(token: @token)}\n") if @token
      io.write("#{JSON.generate(request)}\n")
    end

    def read_answer(io)
      each_answer(io) do |answer|
        next yield(answer["out"]) if block_given? && answer.key?("out") && !answer.key?("exit")

        return answer
      end
      raise Error, "the toolkit API closed the connection without an answer"
    end

    def each_answer(io)
      io.each_line do |line|
        yield JSON.parse(line)
      rescue JSON::ParserError
        raise Error, "the toolkit API answered something that is not JSON"
      end
    rescue IO::TimeoutError
      raise Error, "the toolkit API gave no answer after #{@timeout}s"
    end
  end
end
