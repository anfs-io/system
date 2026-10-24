# frozen_string_literal: true

require "open3"

# Every table sorts on a header click: the markup the sort controller reads (public/sort.js does
# the comparing; spec/js/sort_test.mjs tests it under node when node is on PATH).
RSpec.describe "sortable tables" do
  include Rack::Test::Methods

  let(:job) do
    Anfs::Jobs::Job.new("ab12", "packages", "stack/node", "install", %w[ppm install -y stack/node], "failed", 1,
                        ["ppm: no"], Time.utc(2026, 10, 24, 8, 1, 2))
  end
  let(:events) do
    Anfs::EventLog.new.tap do |log|
      log.add({ "type" => "io.anfs.container.died", "subject" => "valkey_valkey_1", "source" => "/anfs/host",
                "time" => "2026-10-23T19:22:07.804Z", "actor" => "podman" })
    end
  end
  let(:app) do
    store = store_with
    jobs = instance_double(Anfs::Jobs, latest: {}, all: [job])
    events = self.events
    Class.new(App) { opts.merge!(store:, jobs:, events:, bus_status: Anfs::BusStatus.new(log: ->(_) {})) }.app
  end

  before { header "Host", "localhost" }

  def body(path)
    get path
    last_response.body
  end

  def header_button(label, type = nil)
    attrs = %(data-sort-column="#{label}"#{%( data-sort-type="#{type}") if type})
    %(<th #{attrs}><button type="button" class="sort" data-action="sort#by">#{label}</button></th>)
  end

  it "makes every kind's table sortable, its key the kind's, versions by version" do
    Anfs::KINDS.each_key do |key|
      page = body("/#{key}")
      next unless page.include?("<table")

      expect(page).to include(%(<table data-controller="sort" data-sort-key-value="#{key}">))
      expect(page).to include(header_button("Status"))
    end

    packages = body("/packages")
    expect(packages).to include(header_button("Package"), header_button("Version", "version"))
    expect(packages).to include('<td data-sort-value="stack/ruby">', '<td data-sort-value="0.1.1">')
    expect(packages).to include("<th></th>") # the action column has nothing to sort
  end

  it "sorts a cell by its value, not by what is shown beside it" do
    spaces = body("/spaces")
    expect(spaces).to include('<td data-sort-value="~/spaces/user/dev/gems">', '<td data-sort-value="">')

    sources = body("/sources")
    expect(sources).to include('<td data-sort-value="packages, containers">')
  end

  it "sorts the overview's sources, and the kinds against them by count" do
    overview = body("/")
    expect(overview).to include('<table class="matrix" data-controller="sort" data-sort-key-value="overview">')
    expect(overview).to include(header_button("Source"), header_button("Packages", "number"))
    expect(overview).to include('<th scope="row" data-sort-value="stack">', '<td data-sort-value="2">')
  end

  it "sorts events and activity by their full times" do
    expect(body("/events")).to include('data-sort-key-value="events"', header_button("Time", "time"),
                                       header_button("Subject"), '<td data-sort-value="2026-10-23T19:22:07.804Z">')

    expect(body("/jobs")).to include('data-sort-key-value="jobs"', header_button("Started", "time"),
                                     header_button("Command"), '<td data-sort-value="2026-10-24T08:01:02.000Z">',
                                     '<td data-sort-value="ppm install -y stack/node">')
  end

  def sort_control(*columns)
    options = columns.map { %(<option value="#{it}">#{it}</option>) }.join
    none = %(<option value="" selected>—</option>)
    select = %(<select data-sort-target="select" data-action="sort#choose">#{none}#{options}</select>)
    button = %(<button type="button" disabled aria-label="Order" data-sort-target="direction" ) +
             %(data-action="sort#reverse">▲</button>)
    %(<caption class="sort-control"><div><label><span>Sort</span>#{select}</label>#{button}</div></caption>)
  end

  it "puts a phone's sort control (select and direction) first in every table, its columns the headers'" do
    packages = sort_control("Package", "Version", "Status")
    expect(body("/packages")).to include(%(data-sort-key-value="packages">#{packages}<thead>))
    overview = body("/")
    kinds = Anfs::KINDS.values.select { it.sourced == true }.map(&:label)
    expect(overview).to include(%(data-sort-key-value="overview">#{sort_control("Source", *kinds)}))
    expect(overview.scan('<caption class="sort-control">').size).to eq(overview.scan("<table").size)
    expect(body("/events")).to include(sort_control("Time", "Type", "Subject", "Space", "By"))
    expect(body("/jobs")).to include(sort_control("Started", "Command", "Status"))
  end

  it "writes each table's control with its own columns" do
    view = Class.new(Phlex::HTML) do
      include Views::Sortable

      def view_template
        2.times do |n|
          sortable_table("t#{n}") do
            thead { tr { sort_header("A#{n}") } }
            tbody { tr { td { "<x>" } } }
          end
        end
      end
    end
    html = view.new.call
    expect(html.scan(/<option value="A\d">/)).to eq(['<option value="A0">', '<option value="A1">'])
    expect(html).to include("<td>&lt;x&gt;</td>") # the rows are escaped once, not twice
  end

  it "leaves aria-sort to the browser: the server's order is no column's" do
    expect(%w[/ /packages /events /jobs].map { body(it) }.join).not_to include("aria-sort")
  end

  it "refuses a sort type the controller does not know" do
    expect { Class.new(Phlex::HTML) { include Views::Sortable }.new.sort_header("X", type: "date") }
      .to raise_error(ArgumentError)
  end

  it "compares as the controller does (node --test spec/js)" do
    node = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { File.join(it, "node") }.find { File.executable?(it) }
    skip "node is not on PATH" unless node

    output, status = Open3.capture2e(node, "--test", "spec/js/", chdir: File.expand_path("..", __dir__))
    expect(status).to be_success, output
  end
end
