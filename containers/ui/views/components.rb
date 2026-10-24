# frozen_string_literal: true

module Views
  class Badge < Phlex::HTML
    def initialize(status)
      @status = status.to_s
    end

    def view_template
      span(class: "badge tone-#{Anfs.tone(@status)}") { @status }
    end
  end

  # A stacked bar of a tally, one segment per status. SVG rather than styled
  # divs: segment widths are attributes, so the CSP needs no inline styles.
  class Bar < Phlex::HTML
    WIDTH = 100
    GAP = 0.8

    def initialize(tally)
      @tally = tally
    end

    def view_template
      total = @tally.sum(&:last)
      svg(class: "bar", viewBox: "0 0 #{WIDTH} 4", preserveAspectRatio: "none", role: "img",
          aria_label: @tally.map { |status, count| "#{count} #{status}" }.join(", ")) do |s|
        x = 0.0
        @tally.each do |status, count|
          width = WIDTH * count.fdiv(total)
          s.rect(x: x.round(2), width: [width - GAP, GAP].max.round(2), height: 4, class: "tone-#{Anfs.tone(status)}")
          x += width
        end
      end
    end
  end

  # A table that sorts by the header clicked (public/controllers/sort_controller.js, public/sort.js).
  # The browser keeps the choice per key and applies it again whenever the table is re-rendered.
  module Sortable
    TYPES = %w[number version time text].freeze

    # The table's rows are written first, so its sort_headers name the columns of the control that
    # goes before them: a caption (inside the table, so it is re-rendered with it) with a select of
    # those columns and a direction button, shown only where the headers are not (app.css).
    def sortable_table(key, **, &)
      @sort_columns = []
      rows = capture(&)
      table(**, data: { controller: "sort", sort_key_value: key }) do
        sort_control(@sort_columns)
        raw(safe(rows))
      end
    end

    # type is one of TYPES; nil leaves it to the column's values.
    def sort_header(label, type: nil)
      raise ArgumentError, "sort type #{type}" unless type.nil? || TYPES.include?(type)

      @sort_columns&.push(label)
      th(data: { sort_column: label, sort_type: type }.compact) do
        button(type: "button", class: "sort", data: { action: "sort#by" }) { label }
      end
    end

    # Nothing chosen until the browser says otherwise: the server's order, "—" selected, the button
    # off; the controller sets the select, the arrow and the label from the stored choice.
    def sort_control(columns)
      caption(class: "sort-control") do
        div do
          label do
            span { "Sort" }
            select(data: { sort_target: "select", action: "sort#choose" }) do
              option(value: "", selected: true) { "—" }
              columns.each { |column| option(value: column) { column } }
            end
          end
          button(type: "button", disabled: true, aria_label: "Order", data: { sort_target: "direction",
                                                                              action: "sort#reverse" }) { "▲" }
        end
      end
    end

    # What a cell sorts by, when it shows more or other than its value.
    def sort_value(value)
      case value
      when nil then ""
      when Array then value.join(", ")
      when Time then value.utc.iso8601(3)
      else value.to_s
      end
    end
  end

  # Wraps a component in the Turbo Stream that swaps it into the page.
  class Stream < Phlex::HTML
    register_element :turbo_stream

    def initialize(target:, content:)
      @target = target
      @content = content
    end

    def view_template
      turbo_stream(action: "replace", target: @target) do
        template { render @content }
      end
    end
  end
end
