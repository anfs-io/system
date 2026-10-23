# frozen_string_literal: true

RSpec.describe Anfs::Poller do
  let(:store) { Anfs::Store.new }
  let(:hub) { Anfs::Hub.new }
  let(:queue) { hub.subscribe }
  let(:cli) { instance_double(Anfs::CLI) }
  let(:machines) { Anfs::KINDS.fetch("machines") }

  subject(:poller) { described_class.new(store:, hub:, cli:, events: nil) }

  def result(rows) = Anfs::Result.new(rows:, error: nil, exit_code: 0)

  it "publishes a kind when its rows change, and not when they are the same" do
    allow(cli).to receive(:run).with("pmm", "list").and_return(result([]), result([]), result([{ "name" => "a" }]))
    queue

    3.times { poller.refresh(machines) }

    expect(queue.size).to eq(2)
    expect(store.rows("machines")).to eq([{ "name" => "a" }])
  end

  describe "#log_line" do
    before { allow(poller).to receive(:nudge) }

    it "refreshes a tool's kinds when the log shows it changing something" do
      poller.log_line("2026-10-11T16:58:17-0400 pmm[1] start: up debian-13\n")

      expect(poller).to have_received(:nudge).with("pmm").at_least(:once)
    end

    it "ignores read-only commands and other log levels" do
      poller.log_line("2026-10-11T16:58:17-0400 pmm[1] start: list\n")
      poller.log_line("2026-10-11T16:58:17-0400 anfs[1] start: src list\n")
      poller.log_line("2026-10-11T16:58:17-0400 ppm[1] debug: Source: x -> y\n")

      expect(poller).not_to have_received(:nudge)
    end

    it "ignores an API connection, which is every refresh through the API" do
      poller.log_line("2026-10-23T09:00:00-0400 anfs[7] start: 7-1792760000 rpc --token\n")
      poller.log_line("2026-10-23T09:00:00-0400 anfs[8] start: 8-1792760000 -d rpc --grant write\n")

      expect(poller).not_to have_received(:nudge)
    end
  end

  describe "#event" do
    before { allow(poller).to receive(:nudge) }

    def start(tool, args, id = "1-1") = { "event" => "start", "id" => id, "tool" => tool, "pid" => 1, "args" => args }

    it "ignores an API connection's start and end" do
      poller.event(start("anfs", "rpc --token"))
      poller.event({ "event" => "end", "id" => "1-1", "tool" => "anfs", "pid" => 1, "exit" => 0 })

      expect(poller).not_to have_received(:nudge)
    end

    it "still nudges for anfs commands that change something" do
      poller.event(start("anfs", "src install core"))

      expect(poller).to have_received(:nudge).with("anfs")
    end
  end

  describe "polling" do
    # Events, then nothing: a Watch that has gone quiet
    let(:events) do
      Class.new do
        def initialize(list) = (@list = list)

        def each(&)
          @list.each(&)
          sleep
        end
      end
    end
    let(:calls) { Hash.new(0) }
    let(:kinds) { Anfs::KINDS.values_at("packages", "machines").map { it.with(every: 60) } }

    before do
      allow(cli).to receive(:run) do |tool, *args|
        calls[[tool, *args].join(" ")] += 1
        result([])
      end
    end

    def poll(list)
      stub_const("#{described_class}::COALESCE", 0.3)
      threads = Thread.list
      described_class.new(store:, hub:, cli:, kinds:, events: events.new(list)).start
      sleep 0.5
    ensure
      (Thread.list - threads).each(&:kill)
    end

    def connection(pid)
      { "event" => "start", "id" => "#{pid}-1", "tool" => "anfs", "pid" => pid, "args" => "rpc --token" }
    end

    it "does not refresh on API connections and reads, however many: only the first poll" do
      reads = Array.new(200) do |i|
        [connection(i), { "event" => "end", "id" => "#{i}-1", "tool" => "anfs", "pid" => i, "exit" => 0 },
         { "event" => "start", "id" => "#{i}-2", "tool" => "ppm", "pid" => i, "args" => "list" },
         "2026-10-23T09:00:00-0400 anfs[#{i}] start: #{i}-3 rpc --token\n"]
      end

      poll(reads.flatten)

      expect(calls).to eq("ppm list" => 1, "pmm list" => 1)
    end

    it "refreshes a tool's kinds on a write" do
      poll([{ "event" => "start", "id" => "1-1", "tool" => "ppm", "pid" => 1, "args" => "install -y stack/ruby" }])

      expect(calls).to eq("ppm list" => 2, "pmm list" => 1)
    end

    it "coalesces nudges: the first refreshes at once, the rest once at the end of the window" do
      stub_const("#{described_class}::COALESCE", 0.5)
      poller = described_class.new(store:, hub:, cli:, kinds:, events: nil)
      threads = Thread.list
      poller.start
      sleep 0.6 # past the first poll's window

      poller.nudge("ppm")
      sleep 0.1
      expect(calls["ppm list"]).to eq(2)

      50.times { poller.nudge("ppm") }
      sleep 0.2
      expect(calls["ppm list"]).to eq(2)
      sleep 0.4
      expect(calls).to eq("ppm list" => 3, "pmm list" => 1)
    ensure
      (Thread.list - threads).each(&:kill)
    end
  end
end
