# frozen_string_literal: true

RSpec.describe EventStream do
  # Stands in for the socket: collects writes, and raises like a closed
  # connection once it has taken `limit` of them.
  let(:fake_socket) do
    Class.new do
      attr_reader :writes

      def initialize(limit)
        @limit = limit
        @writes = []
        @closed = false
      end

      def write(text)
        raise Errno::EPIPE if @writes.size == @limit

        @writes << text
      end

      def close = @closed = true
      def closed? = @closed
    end
  end

  let(:store) { store_with }
  let(:hub) { Anfs::Hub.new }

  def run(show, limit:, publish: [])
    socket = fake_socket.new(limit)
    target, keys, content =
      if show == "overview"
        ["overview", [*Anfs::KINDS.keys, "bus"], -> { Views::Overview.new(store:, bus: Anfs::BusStatus.new.current) }]
      else
        ["panel-#{show}", [show], -> { Views::Panel.new(kind: Anfs::KINDS.fetch(show), snapshot: store[show]) }]
      end
    thread = Thread.new { described_class.new(hub:, target:, keys:, keepalive: 0.05, &content).call(socket) }
    sleep 0.01 until hub.size == 1 || !thread.alive?
    publish.each { hub.publish(it) }
    thread.join(2)
    socket
  end

  it "sends the panel as a Turbo Stream on connect, one SSE data line per line" do
    socket = run("containers", limit: 1)

    expect(socket.writes.first)
      .to start_with('data: <turbo-stream action="replace" target="panel-containers"><template>')
    expect(socket.writes.first).to end_with("</template></turbo-stream>\n\n")
  end

  it "sends the panel again when its kind changes, and a keepalive otherwise" do
    store.put("containers", Anfs::Result.new(rows: [{ "container" => "stack/minio", "status" => nil }], error: nil,
                                             exit_code: 0))
    socket = run("containers", limit: 3, publish: %w[containers])

    expect(socket.writes[1]).to include("minio")
    expect(socket.writes[2]).to eq(": keepalive\n\n")
  end

  it "ignores other kinds on a kind's page, and follows every kind and the bus on the overview" do
    expect(run("containers", limit: 2, publish: %w[machines]).writes[1]).to eq(": keepalive\n\n")
    expect(run("overview", limit: 2, publish: %w[machines]).writes[1]).to include('target="overview"')
    expect(run("overview", limit: 2, publish: %w[bus]).writes[1]).to include('target="overview"')
    expect(run("overview", limit: 2, publish: %w[events job:1]).writes[1]).to eq(": keepalive\n\n")
  end

  it "unsubscribes and closes when the browser goes away" do
    socket = run("overview", limit: 1)

    expect(hub.size).to eq(0)
    expect(socket).to be_closed
  end
end
