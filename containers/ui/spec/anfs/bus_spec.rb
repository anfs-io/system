# frozen_string_literal: true

require "tmpdir"

# A message of the fake client's
FakeMsg = Struct.new(:data, :subject, :acked) do
  def ack = self.acked = true
end

RSpec.describe Anfs::Bus do
  let(:dir) { Dir.mktmpdir("bus") }
  let(:password) { "f00dfeedcafe5ecret" }
  let(:password_file) { File.join(dir, "reader").tap { File.write(it, "#{password}\n") } }
  let(:config) { Anfs::Bus::Config.new(url: "nats://127.0.0.1:47222", user: "reader", password_file:) }
  let(:lines) { [] }
  let(:status) { Anfs::BusStatus.new(log: ->(line) { lines << line }) }
  let(:sleeps) { [] }

  after { FileUtils.rm_rf(dir) }

  # NATS's client, JetStream and the pull subscription in one: each fetch delivers a batch, then
  # the connection closes.
  let(:fake_nats) do
    Class.new do
      attr_reader :consumers, :batches, :logins

      def initialize(batches, consumer: nil)
        @batches = batches.map { |batch| batch.map { FakeMsg.new(it, "anfs.host.anfs.x.y", false) } }
        @consumers = [consumer].compact
        @logins = []
      end

      def connect(url, **opts)
        @logins << [url, opts]
        self
      end

      def jetstream = self

      def consumer_info(_stream, name)
        return if @consumers.any? { it[:durable_name] == name }

        raise NATS::JetStream::Error::NotFound.new(description: "consumer not found")
      end

      def add_consumer(stream, config) = @consumers << config.merge(stream:)

      def pull_subscribe(*) = self

      def fetch(_batch, **, &)
        raise NATS::IO::ConnectionClosedError, "closed" if (@fetched = (@fetched || 0) + 1) > @batches.size

        @batches[@fetched - 1].each(&)
      end

      def closed? = false
      def close = nil
    end
  end

  # Runs the bus until `stop` sleeps have been asked for (each try ends in one), collecting events.
  def run(connect, stop: 1)
    events = []
    sleeper = lambda do |seconds|
      sleeps << seconds
      raise StopIteration if sleeps.size >= stop
    end
    bus = described_class.new(config:, status:, sleeper:, connect:)
    begin
      bus.run { events << it }
    rescue StopIteration
      nil
    end
    events
  end

  it "makes the durable consumer ui once, then yields each event and acks it" do
    nats = fake_nats.new([['{"type":"io.anfs.container.started"}', "not json", "[1]"], ['{"type":"io.anfs.x.y"}']])

    events = run(nats.method(:connect))

    expect(events).to eq([{ "type" => "io.anfs.container.started" }, { "type" => "io.anfs.x.y" }])
    expect(nats.batches.flatten.map(&:acked)).to all(be(true))
    expect(nats.consumers).to eq([{ durable_name: "ui", ack_policy: "explicit", deliver_policy: "new",
                                    filter_subject: "anfs.>", stream: "ANFS" }])
    expect(nats.logins).to eq([["nats://127.0.0.1:47222",
                                { user: "reader", pass: password, name: "anfs-ui", reconnect: false,
                                  connect_timeout: 5 }]])
    expect(status.current.state).to eq(:unreachable)
    expect(lines).to eq(["anfs-ui: bus connected: nats://127.0.0.1:47222",
                         "anfs-ui: bus unreachable: lost the connection: closed; next try in 1s"])
  end

  it "keeps an existing consumer, and a handler's failure is not the connection's" do
    nats = fake_nats.new([%w[{"n":1} {"n":2}]], consumer: { durable_name: "ui" })
    seen = []

    bus = described_class.new(config:, status:, sleeper: ->(_) { raise StopIteration }, connect: nats.method(:connect))
    expect do
      bus.run do |event|
        seen << event
        raise "boom" if event["n"] == 1
      end
    rescue StopIteration
      nil
    end.to output(/anfs-ui: event anfs.host.anfs.x.y: RuntimeError: boom/).to_stderr

    expect(seen).to eq([{ "n" => 1 }, { "n" => 2 }])
    expect(nats.consumers.size).to eq(1)
  end

  it "retries an unreachable bus after 1, 2, 5, 10, 30, then every 60 s, with one log line" do
    refused = ->(*) { raise Errno::ECONNREFUSED, "connect(2) for 127.0.0.1:47222" }

    run(refused, stop: 8)

    expect(sleeps).to eq([1, 2, 5, 10, 30, 60, 60, 60])
    expect(lines.size).to eq(1)
    expect(lines.first).to start_with("anfs-ui: bus unreachable: cannot connect to nats://127.0.0.1:47222: ")
    expect(status.current).to have_attributes(state: :unreachable, retry_at: be > Time.now + 50)
  end

  it "starts the backoff again once a connection was made" do
    nats = fake_nats.new([[]])
    tries = 0
    flaky = lambda do |*args, **opts|
      tries += 1
      raise Errno::ECONNREFUSED if [1, 2, 4].include?(tries)

      nats.connect(*args, **opts).tap { nats.instance_variable_set(:@fetched, 0) }
    end

    run(flaky, stop: 4)

    expect(sleeps).to eq([1, 2, 1, 2])
  end

  it "says when the password file cannot be read" do
    File.delete(password_file)

    run(->(*) { raise "never" })

    expect(status.current.detail).to eq("cannot read the bus password (#{password_file}): ENOENT; next try in 1s")
  end

  it "never logs or shows the password, or a URL's user and password" do
    leaky = ->(url, pass:, **) { raise NATS::IO::AuthError, "Authorization Violation for #{url} with #{pass}" }
    config = self.config.with(url: "nats://reader:#{password}@127.0.0.1:47222")

    begin
      described_class.new(config:, status:, sleeper: ->(_) { raise StopIteration }, connect: leaky).run
    rescue StopIteration
      nil
    end

    expect(lines.join).to include("Authorization Violation for nats://127.0.0.1:47222 with [redacted]")
    expect([lines.join, status.current.detail]).to all(satisfy { !it.include?(password) })
  end

  describe Anfs::Bus::Config do
    it "is core/nats's own on the host: its port file and users/reader" do
      FileUtils.mkdir_p(File.join(dir, "nats/users"))
      File.write(File.join(dir, "nats/port"), "47999\n")

      config = described_class.from_env("XDG_STATE_HOME" => dir, "ANFS_BUS_URL" => "")

      expect(config).to eq(described_class.new(url: "nats://127.0.0.1:47999", user: "reader",
                                               password_file: File.join(dir, "nats/users/reader")))
    end

    it "is the environment's in the container" do
      config = described_class.from_env("ANFS_BUS_URL" => "nats://host.containers.internal:47222",
                                        "ANFS_BUS_PASSWORD_FILE" => "/run/secrets/anfs-bus-reader")

      expect(config).to have_attributes(url: "nats://host.containers.internal:47222",
                                        password_file: "/run/secrets/anfs-bus-reader")
    end
  end

  # The real thing: the pinned nats-server on a random port in a temp dir, the reader with the
  # permissions core/nats gives it (lib/anfs/bus.sh), the stream as anfsd makes it.
  describe "against nats-server" do
    let(:permissions) do
      %w[$JS.API.INFO $JS.API.STREAM.INFO.ANFS $JS.API.CONSUMER.*.ANFS.> $JS.API.CONSUMER.DURABLE.CREATE.ANFS.>
         $JS.API.CONSUMER.MSG.NEXT.ANFS.> $JS.ACK.ANFS.>]
    end
    let(:bus_sh) { File.expand_path("../../../../packages/anfs/home/.local/lib/anfs/bus.sh", __dir__) }
    let(:server) { which("nats-server") }
    let(:url) { "nats://127.0.0.1:#{@port}" }
    let(:config) { Anfs::Bus::Config.new(url:, user: "reader", password_file:) }

    def which(name) = ENV["PATH"].split(":").map { File.join(it, name) }.find { File.executable?(it) }

    def start_server(port = -1)
      File.write(File.join(dir, "server.conf"), <<~CONF)
        listen: 127.0.0.1:#{port}
        jetstream { store_dir: "#{dir}/js" }
        authorization {
          users: [
            {user: "admin", password: "adminpw"}
            {user: "reader", password: "#{password}", permissions: {
              subscribe: {allow: ["anfs.>", "_INBOX.>"]}
              publish: {allow: #{permissions.to_json}}
            }}
          ]
        }
      CONF
      @pid = Process.spawn(server, "-c", "server.conf", "--ports_file_dir", dir, chdir: dir, %i[out err] => File::NULL)
      ports = File.join(dir, "nats-server_#{@pid}.ports")
      50.times { File.exist?(ports) ? break : sleep(0.1) }
      @port = JSON.parse(File.read(ports))["nats"].first[/\d+\z/] if port == -1
    end

    def stop_server
      Process.kill("TERM", @pid)
      Process.wait(@pid)
    end

    def admin = (@admin ||= NATS.connect(url, user: "admin", pass: "adminpw"))

    def until_true(seconds = 10)
      deadline = Time.now + seconds
      sleep 0.05 until yield || Time.now > deadline
    end

    before do
      skip "no nats-server on PATH" unless server
      start_server
      admin.jetstream.add_stream(name: "ANFS", subjects: ["anfs.>"])
    end

    after do
      stop_bus if @bus
      @admin&.close
      stop_server if @pid
    end

    def start_bus(backoff: [0.2])
      events = Queue.new
      @bus = described_class.new(config:, status:, backoff:)
      @threads = [Thread.new { @bus.run { events << it } }]
      until_true { status.current.connected? }
      events
    end

    # As the process ending would: no thread, no connection (its pull goes with it).
    def stop_bus
      @threads.each(&:kill)
      @bus.instance_variable_get(:@nc)&.close
    end

    it "matches the reader's permissions in core/nats" do
      skip "core is not beside the ui" unless File.exist?(bus_sh)

      permissions.each { expect(File.read(bus_sh)).to include(%("#{it}")) }
    end

    it "yields what anfsd publishes, as it comes, and acks it" do
      events = start_bus
      admin.jetstream.publish("anfs.host.anfs.container.started", '{"type":"io.anfs.container.started"}')

      expect(events.pop(timeout: 5)).to eq("type" => "io.anfs.container.started")
      until_true { admin.jetstream.consumer_info("ANFS", "ui").num_ack_pending.zero? }
      expect(admin.jetstream.consumer_info("ANFS", "ui")).to have_attributes(num_ack_pending: 0, num_pending: 0)
    end

    it "takes up after a restart of the ui where it left off, and never sees history from before it existed" do
      admin.jetstream.publish("anfs.host.anfs.old.event", '{"n":0}')
      start_bus
      stop_bus
      admin.jetstream.publish("anfs.host.anfs.x.y", '{"n":1}')

      events = start_bus

      expect(events.pop(timeout: 5)).to eq("n" => 1)
      expect(events.pop(timeout: 0.5)).to be_nil
    end

    it "is unreachable while the server is down, without spinning, and connects again" do
      events = start_bus(backoff: [0.3])
      stop_server
      until_true { status.current.state == :unreachable }
      before = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
      sleep 2
      cpu = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - before

      start_server(@port)
      until_true { status.current.connected? }
      @admin = nil
      admin.jetstream.publish("anfs.host.anfs.x.y", '{"n":2}')

      expect(cpu).to be < 0.1
      expect(events.pop(timeout: 5)).to eq("n" => 2)
      expect(lines.grep(/unreachable/).size).to eq(1)
    end

    # The person's by-hand step after the subjects changed (agents/05b): anfsd stopped, the stream
    # removed with its consumers (ui's too), anfsd started (it makes ANFS again). The pull on the
    # deleted consumer ends with an error, and the loop makes ui again (new events only) once the
    # stream is back, after its backoff; no restart of the ui.
    it "makes its consumer again when the stream is removed and made again" do
      events = start_bus(backoff: [0.2])
      admin.jetstream.delete_stream("ANFS")
      until_true { status.current.state == :unreachable }
      expect(status.current.state).to eq(:unreachable)
      admin.jetstream.add_stream(name: "ANFS", subjects: ["anfs.>"])
      until_true { status.current.connected? }
      admin.jetstream.publish("anfs.host.anfs.container.started", '{"n":3}')

      expect(events.pop(timeout: 5)).to eq("n" => 3)
      expect(admin.jetstream.consumer_info("ANFS", "ui").config.deliver_policy).to eq("new")
    end

    it "is refused a publish to the stream's subjects as the reader" do
      reader = NATS.connect(url, user: "reader", pass: password)
      errors = Queue.new
      reader.on_error { errors << it }
      reader.publish("anfs.host.anfs.x.y", "{}")

      expect(errors.pop(timeout: 2)&.message).to match(/Permissions Violation/)
    ensure
      reader&.close
    end
  end
end
