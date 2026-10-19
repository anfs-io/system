# frozen_string_literal: true

RSpec.describe Anfs::CLI do
  around { |example| Dir.mktmpdir { |dir| (@bin = dir) && example.run } }

  def tool(name, script)
    path = File.join(@bin, name)
    File.write(path, "#!/bin/sh\n#{script}\n")
    File.chmod(0o755, path)
  end

  subject(:cli) { described_class.new(bin_dir: @bin, timeout: 1) }

  it "parses the list a tool prints, asking for --json with the log off" do
    tool "pmm", %(echo "[{\\"args\\":\\"$*\\",\\"log\\":\\"$ANFS_LOG\\"}]")

    result = cli.run("pmm", "list")

    expect(result).to be_ok
    expect(result.rows).to eq([{ "args" => "list --json", "log" => "off" }])
  end

  it "ignores hints on stderr when the tool succeeds" do
    tool "pcm", "echo '[]'; echo 'pcm: nothing defined' >&2"

    expect(cli.run("pcm", "list").rows).to eq([])
  end

  it "reports stderr and the exit code when the tool fails" do
    tool "wsm", "echo 'wsm: no such source' >&2; exit 3"

    result = cli.run("wsm", "list")

    expect(result).to have_attributes(ok?: false, rows: nil, error: "wsm: no such source", exit_code: 3)
  end

  it "reports output that is not a JSON list" do
    tool "ppm", "echo 'stack/ruby 0.1.1'"
    tool "pim", "echo '{}'"

    expect(cli.run("ppm", "list").error).to eq("ppm: output was not JSON")
    expect(cli.run("pim", "list").error).to eq("pim: expected a JSON list")
  end

  it "reports a tool that is not there, as in a container, without running anything" do
    expect(cli.run("nope", "list")).to have_attributes(ok?: false, exit_code: nil,
                                                       error: "nope: #{described_class::UNAVAILABLE}")
  end

  it "gives up on a tool that hangs" do
    tool "psm", "sleep 30"

    started = Time.now
    result = cli.run("psm", "skills", "list")

    expect(result.error).to eq("psm: no answer after 1s")
    expect(Time.now - started).to be < 5
  end
end
