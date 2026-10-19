# frozen_string_literal: true

module Views
  # The page shell. `show` names what this page displays ("overview" or a
  # kind key); the event stream sends updates for that and nothing else.
  class Layout < Phlex::HTML
    register_element :turbo_stream_source

    def initialize(title:, show:, nonce:, content:)
      @title = title
      @show = show
      @nonce = nonce
      @content = content
    end

    def view_template
      doctype
      html(lang: "en") do
        head do
          meta(charset: "utf-8")
          meta(name: "viewport", content: "width=device-width, initial-scale=1")
          # Turbo styles its progress bar with an inline <style>; this lets it past the CSP.
          meta(name: "csp-nonce", content: @nonce)
          title { "#{@title} · anfs" }
          link(rel: "icon", href: "/favicon.svg", type: "image/svg+xml")
          link(rel: "stylesheet", href: "/app.css")
          script(type: "module", src: "/app.js")
        end
        body do
          navigation
          main { render @content }
          turbo_stream_source(src: "/stream?show=#{@show}")
        end
      end
    end

    private

    def navigation
      nav do
        a(href: "/", class: "brand", **current("overview")) { "anfs" }
        Anfs::KINDS.each_value do |kind|
          a(href: "/#{kind.key}", **current(kind.key)) { kind.label }
        end
        a(href: "/jobs", class: "activity", **current("jobs")) { "Activity" }
      end
    end

    def current(key) = key == @show.split(":").first.sub(/\Ajob\z/, "jobs") ? { aria_current: "page" } : {}
  end
end
