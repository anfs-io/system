# frozen_string_literal: true

module Anfs
  # Every kind is listed again this often (seconds) whatever happens: the slow reconcile behind
  # the bus's events (Poller), and all a kind with no events of its own gets besides the commands
  # run from here.
  RECONCILE = 300

  # One kind of asset: the list command that reports it, how often to ask, and how to read a
  # row (core AGENTS.md "Lists and --json"). Every list's first key is the resource, `source/name`
  # (`id`), and `status` is the second; `unset` names a null status (a string, or from the row). `columns` is header =>
  # JSON key, and doubles as the whitelist of what is ever rendered.
  #
  # A row's source is what comes before the / of its resource; a plain name (a machine run from
  # an image) has none, nor do the lists that are not of a source's resources (`sourced: false`).
  # A source's own row is its source (`sourced: :self`). A resource whose id is a path that may be
  # the source alone (wsm's root space `lgat`) has its first segment as the source (`sourced: :first`).
  #
  # `action` says what can be done to a row, as [verb, subject] or nil: the one command that
  # moves it out of the state it is in. The subject is the qualified resource.
  Kind = Data.define(:key, :label, :tool, :args, :every, :id, :columns, :unset, :sourced, :action) do
    def initialize(unset: nil, sourced: true, action: nil, every: RECONCILE, **) = super

    def command = [tool, *args, "--json"].join(" ")

    # In the list's group, if any: `pmm image list` builds with `pmm image build`. Every command
    # takes -y (core AGENTS.md): the click was the answer.
    def action_command(verb, subject) = [tool, *args[...-1], verb, "-y", subject]

    def status = ->(row) { row["status"] || (unset.respond_to?(:call) ? unset[row] : unset) }

    def source
      lambda do |row|
        value = row[id].to_s
        next value if sourced == :self
        next value.split("/", 2).first if sourced == :first && !value.empty?

        value.split("/", 2).first if sourced && value.include?("/")
      end
    end
  end

  # Up or down by resource, for a row whose status says which. Nothing for a definition shadowed
  # by another source: it is listed and nothing else.
  toggle = lambda do |id|
    lambda do |row|
      status = row["status"].to_s
      [status.start_with?("running") ? "down" : "up", row[id]] unless status.include?("shadowed")
    end
  end

  KINDS = [
    Kind.new(key: "sources", label: "Sources", tool: "anfs", args: %w[src list], id: "source",
             sourced: :self,
             columns: { "Source" => "source", "List" => "list", "Provides" => "provides", "URL" => "url" }),
    Kind.new(key: "stacks", label: "Stacks", tool: "anfs", args: %w[list], id: "stack",
             unset: "not installed",
             columns: { "Stack" => "stack", "Version" => "version" }),
    # installed, outdated (the source's version is newer) or null.
    Kind.new(key: "packages", label: "Packages", tool: "ppm", args: %w[list], id: "package",
             unset: "available",
             columns: { "Package" => "package", "Version" => "version" },
             action: ->(row) { [row["status"] ? "remove" : "install", row["package"]] }),
    Kind.new(key: "containers", label: "Containers", tool: "pcm", args: %w[list], id: "container",
             unset: "not created",
             columns: { "Container" => "container", "Version" => "version", "Description" => "description" },
             action: toggle["container"]),
    Kind.new(key: "images", label: "Images", tool: "pmm", args: %w[image list], id: "image",
             columns: { "Image" => "image", "Arch" => "arch", "Backend" => "backend", "Built" => "built" },
             # A plain name's definition is gone: nothing to build it from.
             action: lambda { |row|
               ["build", row["image"]] if %w[unbuilt stale].include?(row["status"]) && row["image"].include?("/")
             }),
    Kind.new(key: "machines", label: "Machines", tool: "pmm", args: %w[list], id: "machine",
             columns: { "Machine" => "machine", "Image" => "image", "Address" => "address" },
             action: toggle["machine"]),
    # ok, partial (Note says what is missing, wrong, in the way or left over) or not in the source;
    # null is not installed. An id is a path: the root space is its source's alias alone.
    Kind.new(key: "spaces", label: "Spaces", tool: "wsm", args: %w[list], id: "space",
             unset: "not installed", sourced: :first,
             columns: { "Space" => "space", "Directory" => "dir", "Note" => "note" },
             action: ->(row) { [row["dir"] ? "remove" : "install", row["space"]] }),
    # missing: its space is installed and it is not cloned. A space not installed is the
    # Spaces panel's install, which clones its repositories too.
    Kind.new(key: "repos", label: "Repositories", tool: "wsm", args: %w[repo list], id: "repository",
             sourced: :first,
             columns: { "Repository" => "repository", "URL" => "url" },
             action: ->(row) { ["install", row["repository"]] if row["status"] == "missing" }),
    Kind.new(key: "skills", label: "Skills", tool: "psm", args: %w[list], id: "skill",
             columns: { "Skill" => "skill", "Config" => "config", "Repo" => "repo" },
             # psm syncs a whole config, so every row of one shares the subject and the job.
             action: ->(row) { ["sync", row["config"]] unless row["status"] == "ok" })
  ].to_h { [it.key, it] }.freeze

  TONES = {
    good: %w[running clean ok installed built],
    warn: ["dirty", "unpushed", "no upstream", "dirty, unpushed", "dirty, no upstream", "outdated", "partial",
           "stale", "shadowed", "running, shadowed", "stopped, shadowed", "not in the source",
           "needs a terminal"],
    bad: ["failed", "missing", "not a repo", "no path", "invalid"]
  }.flat_map { |tone, statuses| statuses.map { [it, tone] } }.to_h.freeze

  def self.tone(status) = TONES.fetch(status, :mute)

  # [[status, count], ...] for a kind's rows, healthiest first.
  def self.tally(kind, rows)
    order = %i[good warn bad mute]
    rows.map { kind.status[it].to_s }.tally.sort_by { |status, count| [order.index(tone(status)), -count] }
  end
end
