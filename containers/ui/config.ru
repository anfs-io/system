# frozen_string_literal: true

# In development the views are reloaded when they change, so an edit on the host shows on the
# next request. Only views/: app.rb and lib/ hold the store, the hub and the poller's threads,
# which a reload would orphan (for those: pcm down ui && pcm up ui).
if ENV["RACK_ENV"] == "development"
  require "phlex"
  require "rack/unreloader"
  Unreloader = Rack::Unreloader.new(subclasses: %w[Phlex::HTML], reload: true) { App.app }
  Unreloader.require(File.expand_path("views", __dir__))
end

require_relative "app"

# The bus is required: unreachable, the page says so and the lists are only reconciled.
bus = Anfs::Bus.new(config: Anfs::Bus::Config.from_env, status: App.opts[:bus_status])
poller = Anfs::Poller.new(store: App.opts[:store], hub: App.opts[:hub], bus:).start
App.opts[:events] = poller.events
# Re-read a tool's lists as soon as a command run from here has finished.
App.opts[:jobs] = Anfs::Jobs.new(hub: App.opts[:hub], on_finish: ->(kind) { poller.nudge(kind.tool) })

run defined?(Unreloader) ? Unreloader : App.freeze.app
