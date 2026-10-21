# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
# Host mode unless a spec hands out a client: never the real toolkit API.
ENV.delete("ANFS_RPC_URL")
ENV.delete("ANFS_RPC_TOKEN")

require "rack/test"
require "tmpdir"
require_relative "../app"
require_relative "fake_api"

# Rows shaped like the tools' real output.
ROWS = {
  "sources" => [
    { "source" => "stack", "url" => "git@example.com:anfs/stack", "list" => "system", "status" => "dirty",
      "provides" => %w[packages containers] },
    { "source" => "user", "url" => "git@example.com:me/anfs", "list" => "user", "status" => "clean",
      "provides" => %w[spaces] }
  ],
  "packages" => [
    { "package" => "stack/ruby", "status" => "installed", "version" => "0.1.1" },
    { "package" => "stack/node", "status" => nil, "version" => "0.1.0" }
  ],
  "containers" => [
    { "container" => "stack/postgres", "status" => "running", "version" => "0.1.0", "description" => "PostgreSQL" },
    { "container" => "stack/redis", "status" => nil, "version" => "0.1.0", "description" => "Redis" }
  ],
  "machines" => [
    { "machine" => "local/debian-13", "status" => "running", "image" => "anfs/debian-13",
      "address" => "127.0.0.1:2222" },
    { "machine" => "web1", "status" => "stopped", "image" => "core/debian-13", "address" => nil }
  ],
  "spaces" => [
    { "space" => "user/dev/gems", "status" => "ok", "dir" => "#{Dir.home}/spaces/user/dev/gems", "note" => nil },
    { "space" => "user/dev/old", "status" => nil, "dir" => nil, "note" => nil }
  ]
}.freeze

def store_with(rows = ROWS)
  Anfs::Store.new.tap do |store|
    rows.each { |key, list| store.put(key, Anfs::Result.new(rows: list, error: nil, exit_code: 0)) }
  end
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with(:rspec) { it.syntax = :expect }
end
