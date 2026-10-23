# frozen_string_literal: true

RSpec.describe "the toolkit API client" do
  let(:hub) { Anfs::Hub.new }
  let(:packages) { Anfs::KINDS.fetch("packages") }

  after { @api&.close }

  def api(transport = :tcp, &) = (@api = FakeAPI.new(transport, &))

  def rpc(token: nil) = Anfs::RPC.new(@api.url, token:, timeout: 2)

  describe Anfs::RPC do
    it "is off without ANFS_RPC_URL, which leaves the tools to ANFS_BIN" do
      expect(described_class.from_env({})).to be_nil
      expect(described_class.from_env({ "ANFS_RPC_URL" => "" })).to be_nil
      expect(described_class.from_env({ "ANFS_RPC_URL" => "unix:///run/anfs/rpc.sock" }).url)
        .to eq("unix:///run/anfs/rpc.sock")
    end

    it "refuses a URL that is neither tcp:// nor unix://" do
      expect { described_class.new("http://localhost:47100") }.to raise_error(ArgumentError, /tcp:/)
    end

    it "says what went wrong when nothing listens" do
      port = TCPServer.new("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } }

      expect { described_class.new("tcp://127.0.0.1:#{port}").call({ version: true }) }
        .to raise_error(described_class::Error, %r{toolkit API at tcp://127.0.0.1:#{port}})
    end
  end

  describe Anfs::CLI do
    %i[tcp unix].each do |transport|
      it "runs a list over #{transport} and parses its data, the token line first" do
        api(transport) { |_request, answer| answer.call({ exit: 0, data: [{ "package" => "core/anfs" }] }) }

        result = Anfs::CLI.new(rpc: rpc(token: "abc")).run("ppm", "list")

        expect(result).to have_attributes(ok?: true, rows: [{ "package" => "core/anfs" }])
        expect(@api.connections(1)).to eq([[{ "token" => "abc" }, { "run" => %w[ppm list] }]])
      end
    end

    it "sends no token line without a token" do
      api(:unix) { |_request, answer| answer.call({ exit: 0, data: [] }) }

      Anfs::CLI.new(rpc: rpc(token: "")).run("pcm", "list")

      expect(@api.connections(1)).to eq([[{ "run" => %w[pcm list] }]])
    end

    it "shows the API's error where a tool's stderr would be, and a refusal" do
      api do |request, answer|
        answer.call(request["run"][0] == "wsm" ? { exit: 3, error: "wsm: no such source" } : { error: "refused: x" })
      end

      expect(Anfs::CLI.new(rpc: rpc).run("wsm", "list"))
        .to have_attributes(ok?: false, error: "wsm: no such source", exit_code: 3)
      expect(Anfs::CLI.new(rpc: rpc).run("psm", "list")).to have_attributes(error: "refused: x", exit_code: nil)
    end

    it "keeps the command of a 77 for a person to run" do
      api { |_r, answer| answer.call({ exit: 77, needs: "terminal", command: %w[pmm list --json], error: "sudo" }) }

      expect(Anfs::CLI.new(rpc: rpc).run("pmm", "list"))
        .to have_attributes(needs_terminal?: true, command: %w[pmm list --json], error: "sudo")
    end

    it "reports an API that cannot be reached" do
      api { |_r, answer| answer.call({ exit: 0, data: [] }) }
      url = @api.url
      @api.close

      expect(Anfs::CLI.new(rpc: Anfs::RPC.new(url)).run("ppm", "list").error).to include("toolkit API at #{url}")
    end
  end

  describe Anfs::Jobs do
    let(:finished) { Queue.new }

    def run(kind, verb, subject)
      jobs = Anfs::Jobs.new(hub:, rpc: rpc, on_finish: ->(k) { finished << k })
      jobs.start(kind, verb, subject).tap { finished.pop(timeout: 5) }
    end

    it "streams each line as it comes and asks for yes instead of the kind's -y" do
      api do |_request, answer|
        answer.call({ out: "installing stack/ruby" })
        answer.call({ out: "done" })
        answer.call({ exit: 0 })
      end

      job = run(packages, "install", "stack/ruby")

      expect(job).to have_attributes(status: "ok", exit_code: 0, output: ["installing stack/ruby", "done"])
      expect(@api.connections(1).first.last).to eq("run" => %w[ppm install stack/ruby], "stream" => true, "yes" => true)
    end

    it "asks for yes on every kind's command: every tool takes -y" do
      api { |_request, answer| answer.call({ exit: 0 }) }

      run(Anfs::KINDS.fetch("spaces"), "install", "lgat/next")

      expect(@api.connections(1).first.last).to eq("run" => %w[wsm install lgat/next], "stream" => true, "yes" => true)
    end

    it "says to run a command in a terminal on 77, which is not a failure" do
      api { |_request, answer| answer.call({ exit: 77, needs: "terminal", command: %w[pmm up -y alpha] }) }

      job = run(Anfs::KINDS.fetch("machines"), "up", "alpha")

      expect(job).to have_attributes(status: "needs a terminal", exit_code: 77)
      expect(job.output.last).to eq("Run this in a terminal: pmm up -y alpha")
    end

    it "says so when the grant is read and the command a write" do
      api { |_request, answer| answer.call({ error: "refused: a write request (install) under --grant read" }) }

      job = run(packages, "install", "stack/ruby")

      expect(job.status).to eq("failed")
      expect(job.output).to eq(["refused: a write request (install) under --grant read", Anfs::Jobs::REFUSED])
    end
  end

  describe Views::Panel do
    it "shows a 77 as a command to run in a terminal, not as a failure" do
      result = Anfs::Result.new(rows: nil, error: "needs sudo", exit_code: 77, command: %w[pmm list --json])
      snapshot = Anfs::Store::Snapshot.new(result:, changed_at: Time.now)

      html = described_class.new(kind: Anfs::KINDS.fetch("machines"), snapshot:).call

      expect(html).to include("Run this in a terminal:", "pmm list --json", "needs sudo")
      expect(html).not_to include("failed")
    end
  end
end
