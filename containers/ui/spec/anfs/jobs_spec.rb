# frozen_string_literal: true

RSpec.describe Anfs::Jobs do
  around { |example| Dir.mktmpdir { |dir| (@bin = dir) && example.run } }

  let(:hub) { Anfs::Hub.new }
  let(:packages) { Anfs::KINDS.fetch("packages") }
  let(:finished) { Queue.new }

  subject(:jobs) { described_class.new(hub:, bin_dir: @bin, on_finish: ->(kind) { finished << kind }) }

  def tool(name, script)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\n#{script}\n")
    File.chmod(0o755, path)
  end

  def run(*) = jobs.start(*).tap { finished.pop(timeout: 5) }

  it "runs the kind's command for the subject and keeps what it printed" do
    tool "ppm", %(echo "ran: $*"; echo "to stderr" >&2)

    job = run(packages, "install", "stack/ruby")

    expect(job).to have_attributes(status: "ok", exit_code: 0, title: "ppm install -y stack/ruby")
    expect(job.output).to contain_exactly("ran: install -y stack/ruby", "to stderr")
    expect(finished).to be_empty
  end

  it "marks a command that exits non-zero, or cannot be run, as failed" do
    tool "ppm", "echo 'ppm: no such package' >&2; exit 1"

    expect(run(packages, "install", "stack/nope")).to have_attributes(status: "failed", exit_code: 1)
    expect(run(Anfs::KINDS.fetch("machines"), "up", "alpha")).to have_attributes(status: "failed", exit_code: nil)
  end

  it "refuses a second command for a subject while one is running" do
    tool "ppm", "sleep 0.3"

    first = jobs.start(packages, "install", "stack/ruby")

    expect(jobs.start(packages, "remove", "stack/ruby")).to be_nil
    expect(jobs.start(packages, "install", "stack/node")).not_to be_nil
    2.times { finished.pop(timeout: 5) }
    expect(first.status).to eq("ok")
  end

  it "tells the hub about the job, the list of jobs and the kind" do
    tool "ppm", "echo hi"
    queue = hub.subscribe

    job = run(packages, "install", "stack/ruby")

    keys = Array.new(queue.size) { queue.pop }
    expect(keys.uniq).to contain_exactly("job:#{job.id}", "jobs", "packages")
  end

  it "gives the newest job per subject of a kind" do
    tool "ppm", "exit 0"
    run(packages, "install", "stack/ruby")
    second = run(packages, "remove", "stack/ruby")

    expect(jobs.latest("packages")).to eq("stack/ruby" => second)
    expect(jobs.latest("machines")).to eq({})
  end
end
