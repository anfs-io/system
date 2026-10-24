# frozen_string_literal: true

module Views
  # One line on the bus: connected, connecting, or unreachable with why and the next try.
  class BusLine < Phlex::HTML
    def initialize(bus:)
      @bus = bus
    end

    def view_template
      p(class: "bus") do
        case @bus.state
        when :connected
          span(class: "tone-good") { "Bus connected" }
          plain " since #{clock(@bus.since)} (#{@bus.detail}): lists change as events come."
        when :unreachable
          strong(class: "tone-bad") { "Bus unreachable" }
          plain " since #{clock(@bus.since)}: #{@bus.detail}. "
          plain "Lists are re-read every #{Anfs::RECONCILE / 60} minutes meanwhile."
        else
          span(class: "muted") { "Bus: connecting…" }
        end
      end
    end

    private

    def clock(time) = time.strftime("%H:%M:%S")
  end

  # The latest events from the bus, newest first: the bus made visible.
  class Events < Phlex::HTML
    include Sortable

    def initialize(events:, bus:)
      @events = events
      @bus = bus
    end

    def view_template
      section(id: "events", class: "panel") do
        render BusLine.new(bus: @bus)
        next p(class: "muted") { "No events since the dashboard started." } if @events.empty?

        div(class: "scroll") do
          sortable_table("events") do
            thead do
              tr do
                sort_header("Time", type: "time")
                %w[Type Subject Space By].each { sort_header(it) }
              end
            end
            tbody { @events.each { |entry| event_row(entry) } }
          end
        end
        p(class: "muted") { "The latest #{Anfs::EventLog::KEEP}. Every one: anfs events ls --all" }
      end
    end

    private

    def event_row(entry)
      tr do
        td(data: { sort_value: sort_value(entry.time) }) { entry.time&.strftime("%H:%M:%S") || "–" }
        td { code { entry.type } }
        td { entry.subject || span(class: "muted") { "–" } }
        td { entry.space }
        td { entry.by }
      end
    end
  end
end
