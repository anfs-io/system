# frozen_string_literal: true

module Views
  # One kind as a table. This is the unit the event stream replaces.
  class Panel < Phlex::HTML
    include Sortable

    HOME = Dir.home

    # jobs is the latest job per subject, or nil for a viewer who may not act.
    def initialize(kind:, snapshot:, jobs: nil)
      @kind = kind
      @snapshot = snapshot
      @jobs = jobs if kind.action
    end

    def view_template
      section(id: "panel-#{@kind.key}", class: "panel") do
        if @snapshot.nil?
          p(class: "muted") { "Loading…" }
        elsif @snapshot.result.ok?
          listing
        else
          failure(@snapshot.result)
        end
      end
    end

    private

    def listing
      div(class: "scroll") do
        sortable_table(@kind.key) do
          thead do
            tr do
              @kind.columns.each { |header, key| sort_header(header, type: ("version" if key == "version")) }
              sort_header("Status")
              th if @jobs
            end
          end
          tbody do
            @snapshot.result.rows.each { |row| table_row(row) }
          end
        end
      end
      p(class: "muted") { "Last changed #{@snapshot.changed_at.strftime("%H:%M:%S")}" }
    end

    # data-tokens gives the filter exact terms (source:stack, status:running)
    # alongside the row's visible text.
    def table_row(row)
      status = @kind.status[row].to_s
      tokens = "source:#{@kind.source[row]} status:#{status.tr(" ", "-")}"
      tr(data: { filter_target: "row", tokens: }) do
        @kind.columns.each_value.with_index do |key, index|
          td(data: { sort_value: home(sort_value(row[key])) }) do
            cell(row[key])
            reason(@kind.action[row]&.last) if index.zero? && @jobs
          end
        end
        td(class: "status") { render Badge.new(status) }
        td(class: "action") { action(*@kind.action[row]) } if @jobs
      end
    end

    # The one thing that can be done to this row, or how it is going.
    def action(verb = nil, subject = nil)
      return if verb.nil?

      job = @jobs[subject]
      return a(href: "/jobs/#{job.id}", class: "busy") { "#{job.verb}…" } if job&.running?

      if failed?(job)
        a(href: "/jobs/#{job.id}", class: "tone-bad", title: job.output.last) { "#{job.verb} #{job.status}" }
      end
      form(method: "post", action: "/#{@kind.key}/action", data: confirmation(verb, subject)) do
        input(type: "hidden", name: "verb", value: verb)
        input(type: "hidden", name: "subject", value: subject)
        button { verb.capitalize }
      end
    end

    # A command that needs a terminal did not fail, but did not happen either: say what to run.
    def failed?(job) = ["failed", Anfs::Jobs::NEEDS_TERMINAL_STATUS].include?(job&.status)

    # Why the last attempt on this row failed, under the row's own cells.
    def reason(subject)
      job = @jobs&.[](subject)
      a(href: "/jobs/#{job.id}", class: "reason") { job.output.last } if failed?(job) && job.output.any?
    end

    def confirmation(verb, subject) = verb == "remove" ? { turbo_confirm: "Remove #{subject}?" } : {}

    def cell(value)
      case value
      when nil, "" then span(class: "muted") { "–" }
      when Array then plain value.join(", ")
      else breakable(home(value.to_s))
      end
    end

    def home(text) = text.sub(/\A#{Regexp.escape(HOME)}/o, "~")

    # Paths and URLs wrap after a slash on a narrow screen, not mid-word.
    def breakable(text)
      text.split(%r{(?<=/)}).each_with_index do |part, index|
        raw safe("<wbr>") if index.positive? # Phlex closes wbr as if it had content
        plain part
      end
    end

    def failure(result)
      return terminal(result) if result.needs_terminal?

      div(class: "failure") do
        strong { "#{@kind.command} failed#{" (exit #{result.exit_code})" if result.exit_code}" }
        pre { result.error }
      end
    end
  end

  class Panel
    private

    def terminal(result)
      div(class: "failure") do
        strong { "Run this in a terminal:" }
        pre { Array(result.command).join(" ") }
        p(class: "muted") { result.error }
      end
    end
  end

  # A kind's page: heading, filter box, and its panel.
  class KindPage < Phlex::HTML
    def initialize(kind:, panel:, query:)
      @kind = kind
      @panel = panel
      @query = query
    end

    def view_template
      div(data: { controller: "filter" }) do
        header(class: "page-head") do
          h1 { @kind.label }
          code { @kind.command }
          input(type: "search", name: "q", value: @query, placeholder: "Filter, e.g. source:stack status:dirty",
                autocomplete: "off", data: { filter_target: "input", action: "input->filter#apply" })
          span(class: "muted", data: { filter_target: "count" })
        end
        render @panel
      end
    end
  end
end
