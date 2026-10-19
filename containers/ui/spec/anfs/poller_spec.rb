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
  end
end
