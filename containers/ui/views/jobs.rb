# frozen_string_literal: true

module Views
  # Every command run from the dashboard since it started, newest first.
  class JobList < Phlex::HTML
    def initialize(jobs:)
      @jobs = jobs
    end

    def view_template
      section(id: "jobs", class: "panel") do
        next p(class: "muted") { "Nothing has been run from here yet." } if @jobs.empty?

        div(class: "scroll") do
          table do
            thead { tr { %w[Started Command Status].each { |header| th { header } } } }
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
        td { a(href:) { job.started_at.strftime("%H:%M:%S") } }
        td do
          a(href:) { code { job.title } }
          a(href:, class: "reason") { job.output.last } if job.status == "failed" && job.output.any?
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
          render Badge.new(@job.exit_code&.positive? ? "failed (exit #{@job.exit_code})" : @job.status)
          a(href: "/#{@job.key}", class: "muted") { "Back to #{Anfs::KINDS.fetch(@job.key).label.downcase}" }
        end
        pre(class: "output") { @job.output.join("\n") }
      end
    end
  end
end
