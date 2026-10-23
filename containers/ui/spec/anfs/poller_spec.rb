# frozen_string_literal: true

RSpec.describe Anfs::Poller do
  let(:store) { Anfs::Store.new }
  let(:hub) { Anfs::Hub.new }
  let(:queue) { hub.subscribe }
  # Strict: a spec that expects no command fails on any
  let(:cli) { instance_double(Anfs::CLI) }
  let(:machines) { Anfs::KINDS.fetch("machines") }

  subject(:poller) { described_class.new(store:, hub:, cli:, bus: nil) }

  def result(rows) = Anfs::Result.new(rows:, error: nil, exit_code: 0)

  # A CloudEvent as anfsd ships it (02c's container events, 01's report events)
  def event(type, subject = nil, data = {}, **extra)
    { "specversion" => "1.0", "id" => SecureRandom.uuid, "source" => "/anfs/host", "type" => "io.anfs.#{type}",
      "subject" => subject, "time" => "2026-10-23T19:22:07.804Z", "actor" => "podman", "anfsv" => 1,
      "data" => data, **extra.transform_keys(&:to_s) }.compact
  end

  def container(verb, name, service = name.split("_").first) = event("container.#{verb}", name, { "pcm" => service })

  def keys(queue) = Array.new(queue.size) { queue.pop }

  it "publishes a kind when its rows change, and not when they are the same" do
    allow(cli).to receive(:run).with("pmm", "list").and_return(result([]), result([]), result([{ "name" => "a" }]))
    queue

    3.times { poller.refresh(machines) }

    expect(queue.size).to eq(2)
    expect(store.rows("machines")).to eq([{ "name" => "a" }])
  end

  describe "#apply: containers from the event's data" do
    let(:rows) do
      [{ "container" => "local/valkey", "status" => "shadowed", "version" => "0.1.0" },
       { "container" => "stack/valkey", "status" => "running", "version" => "0.1.0" },
       { "container" => "stack/authentik", "status" => "running", "version" => "0.2.0" },
       { "container" => "stack/postgres", "status" => nil, "version" => "0.1.0" }]
    end

    before { store.put("containers", result(rows)) }

    def status(id) = store.rows("containers").find { it["container"] == id }["status"]

    it "gives the winning definition's row pcm's status, and runs no command" do
      poller.apply(container("died", "valkey_valkey_1"))
      expect(status("stack/valkey")).to eq("stopped")

      poller.apply(container("removed", "valkey_valkey_1"))
      expect(status("stack/valkey")).to be_nil

      poller.apply(container("created", "valkey_valkey_1"))
      expect(status("stack/valkey")).to eq("stopped")

      poller.apply(container("started", "valkey_valkey_1"))
      expect(status("stack/valkey")).to eq("running")
      expect(status("local/valkey")).to eq("shadowed")
      expect(store.rows("containers").find { it["container"] == "stack/valkey" }["version"]).to eq("0.1.0")
    end

    it "keeps a service running while one of its containers does" do
      poller.apply(container("started", "authentik_server_1"))
      poller.apply(container("started", "authentik_worker_1"))
      poller.apply(container("died", "authentik_worker_1"))
      expect(status("stack/authentik")).to eq("running")

      poller.apply(container("died", "authentik_server_1"))
      expect(status("stack/authentik")).to eq("stopped")

      %w[server worker].each { poller.apply(container("removed", "authentik_#{it}_1")) }
      expect(status("stack/authentik")).to be_nil
    end

    it "changes no row for health, pods, a container pcm did not start or a service it does not list" do
      before = store.rows("containers")

      poller.apply(event("container.health", "valkey_valkey_1", { "pcm" => "valkey", "health" => "healthy" }))
      poller.apply(event("pod.removed", "pod_valkey", { "id" => "fe7ee28799d9" }))
      poller.apply(event("container.died", "busybox", { "image" => "busybox" }))
      poller.apply(container("started", "nope_nope_1"))

      expect(store.rows("containers")).to eq(before)
    end

    it "applies again what came while a list ran, over the list" do
      allow(cli).to receive(:run).with("pcm", "list") do
        poller.apply(container("died", "valkey_valkey_1")) # podman says so mid-list
        result(rows)
      end

      poller.refresh(Anfs::KINDS.fetch("containers"))

      expect(status("stack/valkey")).to eq("stopped")
    end
  end

  describe "#apply: everything goes to the events page" do
    let(:events) { poller.events }

    it "keeps the type, subject, space and who, newest first" do
      poller.apply(event("report.filed", "r-20261023-1", { "to" => "file" },
                         source: "/anfs/spaces/tkj76y3nfx", spacepath: "anfs-dev", actor: "claude:2e9431a0",
                         actorrole: "maintainer"))
      poller.apply(event("run.completed", "019a", {}, source: "/anfs/spaces/tkj76y3nfx", actor: "anfsd"))

      expect(events.all.map(&:to_h)).to match(
        [hash_including(type: "run.completed", subject: "019a", space: "tkj76y3nfx", by: "anfsd"),
         hash_including(type: "report.filed", subject: "r-20261023-1", space: "anfs-dev",
                        by: "claude:2e9431a0 as maintainer", time: Time.utc(2026, 10, 23, 19, 22, 7.804r).localtime)]
      )
    end
  end

  describe "events and reads" do
    # The bus: quiet while the first lists run, then the events (a number is a pause), then quiet
    let(:bus) do
      Class.new do
        def initialize(list) = (@list = list)

        def run(&)
          sleep 0.4
          @list.each { it.is_a?(Numeric) ? sleep(it) : yield(it) }
          sleep
        end
      end
    end
    let(:calls) { Hash.new(0) }
    let(:times) { Hash.new { |hash, key| hash[key] = [] } }
    let(:kinds) { Anfs::KINDS.values_at("sources", "containers", "packages", "machines").map { it.with(every: 60) } }
    let(:valkey) { [{ "container" => "stack/valkey", "status" => nil }] }

    before do
      stub_const("#{described_class}::COALESCE", 0.3)
      allow(cli).to receive(:run) do |tool, *args|
        calls[[tool, *args].join(" ")] += 1
        times[[tool, *args].join(" ")] << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result(tool == "pcm" ? valkey : [])
      end
    end

    # Runs the poller for the first lists' window (0.4 s), the events and `wait`, then the block.
    def run_with(list, wait: 0.5)
      threads = Thread.list
      poller = described_class.new(store:, hub:, cli:, kinds:, bus: bus.new(list)).start
      sleep 0.4 + wait
      yield poller if block_given?
    ensure
      (Thread.list - threads).each(&:kill)
    end

    it "re-reads only the kind an event names, and only for the events that name one" do
      run_with([event("source.updated", "core", { "from" => "a", "to" => "b" }),
                event("podman.connected"),
                event("report.filed", "r-1"), event("run.completed", "019a"), event("pod.created", "pod_x"),
                container("started", "valkey_valkey_1")])

      expect(calls).to eq("anfs src list" => 2, "pcm list" => 2, "ppm list" => 1, "pmm list" => 1)
    end

    it "reads once for a burst, however many events" do
      run_with(Array.new(200) { event("source.updated", "core") } + Array.new(200) { event("podman.disconnected") })

      expect(calls).to eq("anfs src list" => 2, "pcm list" => 2, "ppm list" => 1, "pmm list" => 1)
    end

    it "reads at most once per window while events keep coming" do
      run_with(Array.new(10) { [event("source.updated", "core"), 0.1] }.flatten, wait: 1.4)

      gaps = times["anfs src list"].each_cons(2).map { |earlier, later| later - earlier }
      expect(gaps.size).to be >= 3
      expect(gaps).to all(be >= 0.29)
    end

    it "coalesces the re-renders a burst of events causes" do
      store.put("containers", result(valkey))
      queue
      verbs = %w[created started died removed]

      run_with(Array.new(200) { |i| container(verbs[i % 4], "valkey_valkey_1") } +
               Array.new(200) { event("report.filed", "r-1") })

      expect(keys(queue).tally).to include("containers" => 2, "events" => 2)
    end

    it "re-reads every kind on its own interval, with or without the bus" do
      kinds.map! { it.with(every: 0.25) }

      run_with([], wait: 0.3)

      expect(calls.values).to all(be >= 3)
    end

    it "spreads the kinds' reconciles over the interval" do
      kinds.map! { it.with(every: 0.8) }

      run_with([], wait: 0.05) # 0.45 s: the first lists, then the reconciles due by then (0.2 and 0.4)

      expect(calls).to eq("anfs src list" => 2, "pcm list" => 2, "ppm list" => 1, "pmm list" => 1)
    end

    it "re-reads a tool's kinds when a command run from here ends, and no other" do
      run_with([], wait: 0.1) do |poller|
        poller.nudge("pmm")
        sleep 0.1
      end

      expect(calls).to eq("anfs src list" => 1, "pcm list" => 1, "ppm list" => 1, "pmm list" => 2)
    end
  end

  it "uses next to no CPU when nothing happens" do
    allow(cli).to receive(:run).and_return(result([]))
    quiet = Class.new { def run = sleep }.new
    threads = Thread.list
    described_class.new(store:, hub:, cli:, bus: quiet).start
    sleep 0.2
    before = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
    sleep 2

    expect(Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - before).to be < 0.04
  ensure
    (Thread.list - threads).each(&:kill)
  end
end

RSpec.describe Anfs::Coalescer do
  it "runs the first call at once, then one for all the calls within the window, at its end" do
    runs = Queue.new
    coalescer = described_class.new(window: 0.3)

    coalescer.call(:k) { runs << :now }
    50.times { coalescer.call(:k) { runs << :later } }
    coalescer.call(:other) { runs << :other }

    expect(Array.new(runs.size) { runs.pop }).to eq(%i[now other])
    sleep 0.4
    expect(Array.new(runs.size) { runs.pop }).to eq([:later])
    sleep 0.35
    coalescer.call(:k) { runs << :quiet }
    expect(runs.pop(timeout: 0.05)).to eq(:quiet)
  end
end
