# frozen_string_literal: true

RSpec.describe Anfs::Kind do
  def kind(key) = Anfs::KINDS.fetch(key)

  it "asks each tool for its current list" do
    expect(Anfs::KINDS.values.to_h { [it.key, it.command] }).to eq(
      "sources" => "anfs src list --json", "stacks" => "anfs list --json", "packages" => "ppm list --json",
      "containers" => "pcm list --json", "images" => "pmm image list --json", "machines" => "pmm list --json",
      "spaces" => "wsm list --json", "repos" => "wsm repo list --json", "skills" => "psm list --json",
      "vaults" => "pvm list --json", "links" => "pvm link list --json"
    )
  end

  it "takes a row's source from before the / of its resource, and none from a plain name" do
    expect(kind("containers").source[{ "container" => "core/ui" }]).to eq("core")
    expect(kind("spaces").source[{ "space" => "anfs-dev/" }]).to eq("anfs-dev")
    expect(kind("repos").source[{ "repository" => "lgat/main/app" }]).to eq("lgat")
    expect(kind("machines").source[{ "machine" => "web1" }]).to be_nil
    expect(kind("sources").source[{ "source" => "core" }]).to eq("core")
    expect(kind("links").source[{ "source" => "spaces/anfs/products" }]).to be_nil
  end

  it "reads status, and names a null one" do
    expect(kind("packages").status[{ "status" => "outdated" }]).to eq("outdated")
    expect(kind("packages").status[{ "status" => nil }]).to eq("available")
    expect(kind("stacks").status[{ "status" => nil }]).to eq("not installed")
    expect(kind("spaces").status[{ "status" => nil, "dir" => "/x" }]).to eq("installed")
    expect(kind("spaces").status[{ "status" => "stale", "dir" => "/x" }]).to eq("stale")
    expect(kind("vaults").status[{ "status" => "ok" }]).to eq("ok")
  end

  it "warns of a clone with work not on its remote" do
    states = ["dirty", "unpushed", "no upstream", "dirty, unpushed", "dirty, no upstream"]
    expect(states.map { Anfs.tone(it) }.uniq).to eq([:warn])
    expect(Anfs.tone("clean")).to eq(:good)
  end

  it "builds the command of an action on the qualified resource" do
    expect(kind("images").action_command("build", "core/debian-13")).to eq(%w[pmm image build -y core/debian-13])
    expect(kind("packages").action_command("install", "stack/ruby")).to eq(%w[ppm install -y stack/ruby])
    expect(kind("containers").action[{ "container" => "core/ui", "status" => "stopped" }]).to eq(%w[up core/ui])
    expect(kind("containers").action[{ "container" => "x/ui", "status" => "running, shadowed" }]).to be_nil
    expect(kind("stacks").action).to be_nil
    repo = { "repository" => "lgat/next/docs", "status" => "missing" }
    expect(kind("repos").action[repo]).to eq(%w[install lgat/next/docs])
    expect(kind("repos").action_command("install", "lgat/next/docs")).to eq(%w[wsm repo install -y lgat/next/docs])
    expect(kind("repos").action[repo.merge("status" => "not installed")]).to be_nil
  end
end
