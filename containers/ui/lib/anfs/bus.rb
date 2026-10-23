# frozen_string_literal: true

require "json"
require "nats/client"

module Anfs
  # The bus (NATS with JetStream, core/nats and anfsd) as its `reader` user: the durable consumer
  # `ui` on stream ANFS, every subject (anfs.>), new events only when it is first made. Yields
  # each CloudEvent (a Hash), then acks it. Runs forever: an unreachable bus, a refused login or a
  # missing password file is retried after 1, 2, 5, 10, 30, then every 60 s. The client's own
  # reconnecting is off, so this loop is the only one.
  #
  # The password is read from a file at each connect (in the container a read-only mount of
  # core/nats's users/reader), passed to the client apart from the URL, and redacted from every
  # message this logs or shows.
  class Bus
    STREAM = "ANFS"
    CONSUMER = "ui"
    SUBJECTS = "anfs.>"
    BACKOFF = [1, 2, 5, 10, 30, 60].freeze
    BATCH = 100
    WAIT = 30
    REDACTED = "[redacted]"

    # connect: (url, user:, pass:) to a connected client, NATS.connect's signature
    def initialize(config:, status: BusStatus.new, backoff: BACKOFF, sleeper: ->(s) { sleep s },
                   connect: ->(url, **opts) { NATS.connect(url, **opts) })
      @config = config
      @status = status
      @backoff = backoff
      @sleep = sleeper
      @connect = connect
      @url = display_url(config.url)
    end

    def run(&)
      failures = 0
      loop do
        session(&)
      rescue StandardError => e
        failures = 0 if @was_connected
        retry_in = @backoff.fetch(failures, @backoff.last)
        @status.unreachable("#{redact(message(e))}; next try in #{retry_in}s", retry_in)
        failures += 1
        @sleep.call(retry_in)
      end
    end

    private

    # One connection, until it fails (raises).
    def session(&)
      @was_connected = false
      @status.connecting(@url)
      @nc = phase("cannot connect to #{@url}") { connect }
      sub = phase("cannot read stream #{STREAM} (is anfsd running?)") { subscribe(@nc.jetstream) }
      @status.connected(@url)
      @was_connected = true
      phase("lost the connection") { pull(sub, &) }
    ensure
      close
    end

    def connect
      @connect.call(@config.url, user: @config.user, pass: password, name: "anfs-ui", reconnect: false,
                                 connect_timeout: 5)
    end

    # Errors from a step, said as that step's failure.
    def phase(what)
      yield
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "#{what}: #{message(e)}"
    end

    def password
      @password = File.read(@config.password_file).strip
    rescue SystemCallError => e
      raise Error, "cannot read the bus password (#{@config.password_file}): #{e.class.name.split("::").last}"
    end

    def subscribe(jetstream)
      begin
        jetstream.consumer_info(STREAM, CONSUMER)
      rescue NATS::JetStream::Error::NotFound
        jetstream.add_consumer(STREAM, durable_name: CONSUMER, ack_policy: "explicit", deliver_policy: "new",
                                       filter_subject: SUBJECTS)
      end
      jetstream.pull_subscribe(SUBJECTS, CONSUMER, stream: STREAM)
    end

    # A pull is open for WAIT seconds (idle, two requests a minute). Each message is handled as it
    # comes (fetch's block), not when the pull ends.
    def pull(sub, &)
      loop do
        sub.fetch(BATCH, timeout: WAIT) do |msg|
          deliver(msg, &)
          msg.ack
        end
      rescue NATS::Timeout
        raise Error, "the connection closed" if @nc.closed?
      end
    end

    # Not an event (not JSON, not an object): acked and skipped, as anfsd never ships one. What
    # the handler raises is its own failure, logged, not the connection's.
    def deliver(msg)
      event = JSON.parse(msg.data)
      yield event if event.is_a?(Hash)
    rescue JSON::ParserError
      nil
    rescue StandardError => e
      warn "anfs-ui: event #{msg.subject}: #{e.class}: #{redact(e.message)}"
    end

    def close
      @nc&.close
    rescue StandardError
      nil
    ensure
      @nc = nil
    end

    def message(error)
      text = error.message.to_s
      text = error.class.name if text.empty? || text == error.class.name
      text
    end

    def redact(text)
      text = text.gsub(@config.url, @url)
      @password.to_s.empty? ? text : text.gsub(@password, REDACTED)
    end

    # The URL without any user or password in it.
    def display_url(url) = url.sub(%r{//[^/@]*@}, "//")

    class Error < StandardError; end
  end
end
