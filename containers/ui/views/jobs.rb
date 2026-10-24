# frozen_string_literal: true

module Views
  # Every command run from the dashboard since it started, newest first.
  class JobList < Phlex::HTML
    include Sortable

    def initialize(jobs:)
      @jobs = jobs
    end

    def view_template
      section(id: "jobs", class: "panel") do
        next p(class: "muted") { "Nothing has been run from here yet." } if @jobs.empty?

        div(class: "scroll") do
          sortable_table("jobs") do
            thead do
              tr do
                sort_header("Started", type: "time")
                sort_header("Command")
                sort_header("Status")
              end
            end
            tbody do
              @jobs.each { |job| job_row(job) }
            end
          end
        end
      end
    end
  end

  class JobList
    private

    # Every cell is a link: on a phone the row is a card, and a tap anywhere
    # on it should open the output.
    def job_row(job)
      href = "/jobs/#{job.id}"
      tr do
        td(data: { sort_value: sort_value(job.started_at) }) { a(href:) { job.started_at.strftime("%H:%M:%S") } }
        td(data: { sort_value: job.title }) do
          a(href:) { code { job.title } }
          a(href:, class: "reason") { job.output.last } if job.status != "ok" && !job.running? && job.output.any?
        end
        td(class: "status") { a(href:) { render Badge.new(job.status) } }
      end
    end
  end

  # One command and what it has printed so far.
  class JobPanel < Phlex::HTML
    def initialize(job:)
      @job = job
    end

    def view_template
      section(id: "job-#{@job.id}", class: "panel") do
        header(class: "page-head") do
          h1 { code { @job.title } }
          render Badge.new(@job.status == "failed" && @job.exit_code ? "failed (exit #{@job.exit_code})" : @job.status)
          a(href: "/#{@job.key}", class: "muted") { "Back to #{Anfs::KINDS.fetch(@job.key).label.downcase}" }
        end
        pre(class: "output") { @job.output.join("\n") }
      end
    end
  end
end
