# frozen_string_literal: true

module Anfs
  # One kind of asset: the list command that reports it, how often to ask,
  # and how to read a row. `status` and `source` are the two things every
  # tool spells differently; `columns` is header => JSON key, and doubles as
  # the whitelist of what is ever rendered.
  #
  # `action` says what can be done to a row, as [verb, subject] or nil: the
  # one command that moves it out of the state it is in.
  Kind = Data.define(:key, :label, :tool, :args, :every, :status, :source, :columns, :action, :action_flags) do
    def initialize(action: nil, action_flags: [], **) = super

    def command = [tool, *args, "--json"].join(" ")

    def action_command(verb, subject) = [tool, verb, *action_flags, subject]
  end

  # Up or down by name, for a row whose state says which. Nothing for a
  # definition shadowed by another source: the name would reach the other one.
  toggle = lambda do |state_key|
    lambda do |row|
      state = row[state_key].to_s
      [state.start_with?("running") ? "down" : "up", row["name"]] unless state.include?("shadowed")
    end
  end

  first_segment = ->(key) { ->(row) { row[key].to_s.split("/").first } }

  KINDS = [
    Kind.new(key: "sources", label: "Sources", tool: "anfs", args: %w[src list], every: 30,
             status: ->(row) { row["status"] },
             source: ->(row) { row["alias"] },
             columns: { "Alias" => "alias", "List" => "list", "Provides" => "provides", "URL" => "url" }),
    Kind.new(key: "packages", label: "Packages", tool: "ppm", args: %w[list], every: 60,
             status: ->(row) { row["installed"] ? "installed" : "available" },
             source: first_segment["package"],
             columns: { "Package" => "package", "Version" => "installed" },
             action: ->(row) { [row["installed"] ? "remove" : "install", row["package"]] },
             action_flags: %w[-y]),
    Kind.new(key: "containers", label: "Containers", tool: "pcm", args: %w[list], every: 5,
             status: ->(row) { row["status"] || "not created" },
             source: ->(row) { row["source"] },
             columns: { "Service" => "name", "Source" => "source" },
             action: toggle["status"]),
    Kind.new(key: "images", label: "Images", tool: "pim", args: %w[list], every: 30,
             status: ->(row) { row["status"].to_s.start_with?("built") ? "built" : row["status"] || "not built" },
             source: ->(row) { row["source"] },
             columns: { "Image" => "name", "Source" => "source", "Builds" => "status" },
             action: ->(row) { ["build", row["name"]] if row["status"].nil? }),
    Kind.new(key: "machines", label: "Machines", tool: "pmm", args: %w[list], every: 5,
             status: ->(row) { row["state"] },
             source: ->(row) { row["source"] },
             columns: { "Machine" => "name", "Source" => "source", "Image" => "image", "Address" => "address" },
             action: toggle["state"]),
    Kind.new(key: "spaces", label: "Spaces", tool: "wsm", args: %w[list], every: 30,
             status: ->(row) { row["note"] || (row["dir"] ? "installed" : "not installed") },
             source: first_segment["id"],
             columns: { "Id" => "id", "Level" => "level", "Directory" => "dir" },
             action: ->(row) { [row["dir"] ? "remove" : "install", row["id"]] }),
    Kind.new(key: "repos", label: "Repositories", tool: "wsm", args: %w[list -r], every: 60,
             status: ->(row) { row["state"] },
             source: first_segment["path"],
             columns: { "Path" => "path", "URL" => "url" }),
    Kind.new(key: "skills", label: "Skills", tool: "psm", args: %w[skills list], every: 300,
             status: ->(row) { row["status"] == "*" ? "wildcard" : row["status"] },
             source: ->(row) { row["config"] },
             columns: { "Skill" => "skill", "Config" => "config", "Repo" => "repo" },
             # psm syncs a whole config, so every row of one shares the subject and the job.
             action: ->(row) { ["sync", row["config"]] unless row["status"] == "ok" }),
    Kind.new(key: "vaults", label: "Vaults", tool: "pvm", args: %w[list], every: 60,
             status: ->(row) { row["state"] },
             source: ->(_row) {},
             columns: { "Vault" => "name", "Id" => "id", "Path" => "path" }),
    Kind.new(key: "links", label: "Vault links", tool: "pvm", args: %w[link list], every: 60,
             status: ->(row) { row["state"] },
             source: first_segment["target"],
             columns: { "Target" => "target", "As" => "as", "From" => "source", "Vault" => "vault" })
  ].to_h { [it.key, it] }.freeze

  TONES = {
    good: %w[running clean ok installed built],
    warn: ["dirty", "partial", "stale", "pending", "unknown", "shadowed", "running, shadowed",
           "stopped, shadowed", "not in the source"],
    bad: ["failed", "missing", "conflict", "dangling", "not a repo", "no path"]
  }.flat_map { |tone, statuses| statuses.map { [it, tone] } }.to_h.freeze

  def self.tone(status) = TONES.fetch(status, :mute)

  # [[status, count], ...] for a kind's rows, healthiest first.
  def self.tally(kind, rows)
    order = %i[good warn bad mute]
    rows.map { kind.status[it].to_s }.tally.sort_by { |status, count| [order.index(tone(status)), -count] }
  end
end
