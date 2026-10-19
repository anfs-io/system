# frozen_string_literal: true

require_relative "app"

poller = Anfs::Poller.new(store: App.opts[:store], hub: App.opts[:hub]).start
# Re-read a tool's lists as soon as a command run from here has finished.
App.opts[:jobs] = Anfs::Jobs.new(hub: App.opts[:hub], on_finish: ->(kind) { poller.nudge(kind.tool) })

run App.freeze.app
