# frozen_string_literal: true

RSpec.describe App do
  include Rack::Test::Methods

  let(:store) { store_with }
  let(:jobs) { instance_double(Anfs::Jobs, latest: {}, all: [], start: nil) }
  let(:local_only) { false }
  let(:app) do
    store = self.store
    jobs = self.jobs
    local_only = self.local_only
    Class.new(described_class) do
      opts[:store] = store
      opts[:jobs] = jobs
      opts[:local_only] = local_only
    end.app
  end

  before { header "Host", "localhost" }

  it "shows a tile per kind and a row per source on the overview" do
    get "/"

    expect(last_response).to be_ok
    expect(last_response.body).to include('id="overview"', "1 running", "1 not created", "/containers?q=source:stack")
    expect(last_response.body).to include("local", "not a source")
  end

  it "lists a kind with filter tokens on each row" do
    get "/containers"

    expect(last_response.body).to include('id="panel-containers"', "postgres", "pcm list --json")
    expect(last_response.body).to include('data-tokens="source:stack status:not-created"')
  end

  it "shortens the home directory and keeps the filter from the address" do
    get "/spaces", q: "source:user"

    expect(last_response.body).to include("~/<wbr>spaces/<wbr>user/<wbr>dev/<wbr>gems", 'value="source:user"')
    expect(last_response.body).not_to include(Dir.home)
  end

  it "shows a tool's error in place of its table" do
    store.put("machines", Anfs::Result.new(rows: nil, error: "pmm: <broken>", exit_code: 127))

    get "/machines"

    expect(last_response.body).to include("pmm list --json failed (exit 127)", "pmm: &lt;broken&gt;")
  end

  it "says Loading for a kind not read yet" do
    get "/skills"

    expect(last_response.body).to include("Loading")
  end

  describe "the events page" do
    let(:events) { Anfs::EventLog.new }
    let(:bus) { Anfs::BusStatus.new(log: ->(_) {}) }
    let(:app) do
      store = self.store
      jobs = self.jobs
      events = self.events
      bus = self.bus
      Class.new(described_class) do
        opts.merge!(store:, jobs:, events:, bus_status: bus)
      end.app
    end

    it "lists the latest events, newest first: time, type, subject, space, by" do
      events.add({ "type" => "io.anfs.container.died", "subject" => "valkey_valkey_1", "source" => "/anfs/host",
                   "time" => "2026-10-23T19:22:07.804Z", "actor" => "podman" })
      events.add({ "type" => "io.anfs.report.filed", "subject" => "r-20261023-1", "spacepath" => "anfs-dev",
                   "source" => "/anfs/spaces/tkj76y3nfx", "time" => "2026-10-23T19:23:00Z",
                   "actor" => "claude:2e9431a0", "actorrole" => "maintainer" })
      events.add({ "type" => "io.cnfs.partitia.report.filed", "subject" => "4182",
                   "source" => "/cnfs/spaces/m2vq7cfr4k/partitia", "time" => "2026-10-23T19:24:00Z",
                   "actor" => "user:u7f3a" })

      get "/events"

      body = last_response.body
      expect(body).to include('id="events"', "report.filed", "r-20261023-1", "anfs-dev",
                              "claude:2e9431a0 as maintainer", "container.died", "valkey_valkey_1", "host", "podman",
                              'src="/stream?show=events"', "cnfs.partitia.report.filed", "m2vq7cfr4k")
      expect(body).not_to include("io.cnfs", ">partitia<")
      expect(body.index("report.filed")).to be < body.index("container.died")
      expect(body).to include("Bus: connecting")
    end

    it "says the bus is unreachable, why, and that lists are only reconciled" do
      bus.unreachable("cannot connect to nats://host.containers.internal:47222: Connection refused; next try in 5s", 5)

      get "/events"

      expect(last_response.body).to include("Bus unreachable", "Connection refused; next try in 5s", "every 5 minutes",
                                            "No events since the dashboard started")
    end

    it "shows the bus's state on the overview" do
      bus.connected("nats://host.containers.internal:47222")

      get "/"

      expect(last_response.body).to include("Bus connected", 'href="/events"')
    end
  end

  it "answers 404 for anything else" do
    get "/nope"
    expect(last_response.status).to eq(404)

    get "/stream", show: "nope"
    expect(last_response.status).to eq(404)
  end

  context "with no tools, as in a container before the toolkit API" do
    let(:store) do
      Anfs::Store.new.tap do |store|
        poller = Anfs::Poller.new(store:, hub: Anfs::Hub.new, cli: Anfs::CLI.new(bin_dir: Dir.mktmpdir))
        Anfs::KINDS.each_value { poller.refresh(it) }
      end
    end

    it "serves every page, saying the tools are not reachable" do
      ["/", *Anfs::KINDS.keys.map { "/#{it}" }].each do |path|
        get path

        expect(last_response).to be_ok, "#{path}: #{last_response.status}"
        expect(last_response.body).to include(Anfs::CLI::UNAVAILABLE)
      end
    end
  end

  it "refuses a request addressed to another host" do
    header "Host", "evil.example"
    get "/"

    expect(last_response.status).to eq(403)
  end

  it "allows scripts and styles from itself only" do
    get "/"

    csp = last_response.headers["content-security-policy"]
    nonce = last_response.body[/name="csp-nonce" content="([^"]+)"/, 1]
    expect(csp).to include("default-src 'self'", "style-src 'self' 'nonce-#{nonce}'")
    expect(last_response.body).not_to match(/<script(?![^>]*src=)|style=/)
  end

  describe "actions" do
    let(:origin) { { "HTTP_ORIGIN" => "http://localhost" } }

    def act(kind, verb, subject, env = origin) = post("/#{kind}/action", { verb:, subject: }, env)

    it "offers each row the one thing that can be done to it" do
      get "/packages"
      expect(last_response.body).to match(%r{name="verb" value="remove">.{0,80}value="stack/ruby"})
      expect(last_response.body).to match(%r{name="verb" value="install">.{0,80}value="stack/node"})
      expect(last_response.body).to include('data-turbo-confirm="Remove stack/ruby?"')

      get "/containers"
      expect(last_response.body).to match(%r{value="down">.{0,80}value="stack/postgres"})
      expect(last_response.body).to match(%r{value="up">.{0,80}value="stack/redis"})

      get "/machines"
      expect(last_response.body).to match(%r{value="down">.{0,80}value="local/debian-13"})
      expect(last_response.body).to match(/value="up">.{0,80}value="web1"/)
    end

    it "offers install or remove on spaces, build on unbuilt or stale images, sync on skills not ok" do
      ok = ->(rows) { Anfs::Result.new(rows:, error: nil, exit_code: 0) }
      store.put("images", ok[[{ "image" => "core/debian-13", "status" => "built", "arch" => "arm64" },
                              { "image" => "core/fedora-44", "status" => "unbuilt", "arch" => nil },
                              { "image" => "core/alpine", "status" => "stale", "arch" => "arm64" },
                              { "image" => "user/debian-13", "status" => "shadowed", "arch" => nil },
                              { "image" => "gone", "status" => "unbuilt", "arch" => nil }]])
      store.put("skills", ok[[{ "skill" => "pony/ponytail", "status" => "partial", "config" => "pony" },
                              { "skill" => "stack/hello", "status" => "ok", "config" => "stack" }]])

      get "/spaces"
      expect(last_response.body).to match(%r{value="remove">.{0,80}value="user/dev/gems"})
      expect(last_response.body).to match(%r{value="install">.{0,80}value="user/dev/old"})

      get "/images"
      expect(last_response.body.scan(/name="subject" value="([^"]+)"/)).to eq([["core/fedora-44"], ["core/alpine"]])

      get "/skills"
      expect(last_response.body.scan(/value="sync">.{0,60}value="([^"]+)"/)).to eq([["pony"]])
    end

    it "offers nothing on kinds without actions" do
      get "/sources"

      expect(last_response.body).not_to include("<form")
    end

    it "starts the job and answers with the panel as a Turbo Stream" do
      act "packages", "install", "stack/node"

      expect(jobs).to have_received(:start).with(Anfs::KINDS.fetch("packages"), "install", "stack/node")
      expect(last_response.headers["content-type"]).to start_with("text/vnd.turbo-stream.html")
      expect(last_response.body).to start_with('<turbo-stream action="replace" target="panel-packages">')
    end

    it "shows a running job in place of the button, and a failed one beside it" do
      job = Anfs::Jobs::Job.new("ab12", "packages", "stack/node", "install", [], "running", nil, ["ppm: boom"])
      allow(jobs).to receive(:latest).with("packages").and_return("stack/node" => job)

      get "/packages"
      expect(last_response.body).to include('<a href="/jobs/ab12" class="busy">install…</a>')
      expect(last_response.body).not_to include('name="subject" value="stack/node"')

      job.status = "failed"
      get "/packages"
      expect(last_response.body).to include("install failed", 'name="subject" value="stack/node"')
      expect(last_response.body).to include('<a href="/jobs/ab12" class="reason">ppm: boom</a>')
    end

    it "refuses anything a row does not offer" do
      [%w[packages remove stack/node], %w[packages install stack/nope], %w[packages install -f],
       %w[containers up stack/postgres], %w[containers up postgres],
       %w[sources update stack]].each do |kind, verb, subject|
        act kind, verb, subject
        expect(last_response.status).to eq(422)
      end
      expect(jobs).not_to have_received(:start)
    end

    it "refuses a post from another site" do
      act "packages", "install", "stack/node", "HTTP_ORIGIN" => "http://evil.example"
      expect(last_response.status).to eq(403)

      act "packages", "install", "stack/node", {}
      expect(last_response.status).to eq(403)
      expect(jobs).not_to have_received(:start)
    end

    it "keeps actions to this machine unless told otherwise" do
      remote = origin.merge("REMOTE_ADDR" => "192.168.1.20")

      get "/packages", {}, remote
      expect(last_response.body).not_to include("<form")

      act "packages", "install", "stack/node", remote
      expect(last_response.status).to eq(403)
    end

    context "when published on loopback only" do
      let(:local_only) { true }

      it "lets the forwarded requests act: only this machine reaches it" do
        forwarded = origin.merge("REMOTE_ADDR" => "192.168.127.1")

        get "/packages", {}, forwarded
        expect(last_response.body).to include("<form")

        act "packages", "install", "stack/node", forwarded
        expect(jobs).to have_received(:start)
      end
    end
  end

  describe "activity" do
    let(:job) do
      Anfs::Jobs::Job.new("ab12", "packages", "stack/node", "install", %w[ppm install -y stack/node], "failed", 1,
                          ["ppm: <no>"], Time.now)
    end
    let(:jobs) { instance_double(Anfs::Jobs, latest: {}, all: [job]) }

    before { allow(jobs).to receive(:[]) { |id| job if id == "ab12" } }

    it "lists what has been run" do
      get "/jobs"

      expect(last_response.body).to include('id="jobs"', "ppm install -y stack/node", "failed")
      expect(last_response.body).to include('<a href="/jobs/ab12" class="reason">ppm: &lt;no&gt;</a>')
    end

    it "shows a job's output, and 404 for one it does not know" do
      get "/jobs/ab12"
      expect(last_response.body).to include('id="job-ab12"', "failed (exit 1)", "ppm: &lt;no&gt;")
      expect(last_response.body).to include("/stream?show=job:ab12")

      get "/jobs/ffff"
      expect(last_response.status).to eq(404)
    end
  end
end
