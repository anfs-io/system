# frozen_string_literal: true

module Views
  # Everything at a glance: a tile per kind, then sources against kinds.
  class Overview < Phlex::HTML
    def initialize(store:)
      @store = store
    end

    def view_template
      div(id: "overview") do
        section(class: "tiles") do
          Anfs::KINDS.each_value { |kind| tile(kind, @store[kind.key]) }
        end
        matrix
      end
    end

    private

    def tile(kind, snapshot)
      article(class: "tile") do
        a(href: "/#{kind.key}", class: "tile-head") do
          span { kind.label }
          strong { snapshot&.result&.ok? ? snapshot.result.rows.size.to_s : "–" }
        end
        if snapshot.nil?
          p(class: "muted") { "Loading…" }
        elsif snapshot.result.ok?
          breakdown(kind, Anfs.tally(kind, snapshot.result.rows))
        else
          p(class: "tone-bad") { snapshot.result.error.lines.first }
        end
      end
    end

    def breakdown(kind, tally)
      render Bar.new(tally)
      ul(class: "legend") do
        tally.each do |status, count|
          li do
            a(href: filter_href(kind, "status", status), class: "tone-#{Anfs.tone(status)}") { "#{count} #{status}" }
          end
        end
      end
    end

    # Kinds whose rows belong to a source, as columns; sources as rows.
    def matrix
      kinds = Anfs::KINDS.values_at("packages", "containers", "images", "machines", "spaces", "repos", "skills",
                                    "links")
      by_source = kinds.to_h { |kind| [kind.key, @store.rows(kind.key).group_by(&kind.source)] }
      sources = @store.rows("sources").to_h { [it["alias"], it] }
      aliases = sources.keys | by_source.values.flat_map(&:keys).compact.sort

      div(class: "scroll") do
        table(class: "matrix") do
          thead do
            tr do
              th { "Source" }
              kinds.each { |kind| th { a(href: "/#{kind.key}") { kind.label } } }
            end
          end
          tbody do
            aliases.each { |name| matrix_row(name, sources[name], kinds, by_source) }
          end
        end
      end
    end

    def matrix_row(name, source, kinds, by_source)
      tr do
        th(scope: "row") do
          plain name
          whitespace
          source ? render(Badge.new(source["status"])) : span(class: "muted") { "not a source" }
        end
        kinds.each do |kind|
          rows = by_source.dig(kind.key, name)
          td { rows ? cell(kind, name, rows) : span(class: "muted") { "·" } }
        end
      end
    end

    def cell(kind, name, rows)
      a(href: filter_href(kind, "source", name)) do
        plain rows.size.to_s
        render Bar.new(Anfs.tally(kind, rows))
      end
    end

    def filter_href(kind, field, value)
      "/#{kind.key}?q=#{field}:#{value.tr(" ", "-")}"
    end
  end
end
