# frozen_string_literal: true

ENV["RACK_ENV"] = "test"

require "rack/test"
require "tmpdir"
require_relative "../app"

# Rows shaped like the tools' real output.
ROWS = {
  "sources" => [
    { "alias" => "stack", "url" => "git@example.com:anfs/stack", "list" => "system", "status" => "dirty",
      "provides" => %w[packages containers] },
    { "alias" => "user", "url" => "git@example.com:me/anfs", "list" => "user", "status" => "clean",
      "provides" => %w[spaces] }
  ],
  "packages" => [
    { "package" => "stack/ruby", "installed" => "0.1.1" },
    { "package" => "stack/node", "installed" => nil }
  ],
  "containers" => [
    { "name" => "postgres", "source" => "stack", "status" => "running" },
    { "name" => "redis", "source" => "stack", "status" => nil }
  ],
  "machines" => [
    { "name" => "debian-13", "source" => "local", "image" => "anfs/debian-13", "state" => "running",
      "address" => "127.0.0.1:2222" }
  ],
  "spaces" => [
    { "id" => "user/dev/gems", "dir" => "#{Dir.home}/spaces/user/dev/gems", "level" => "space", "note" => nil },
    { "id" => "user/dev/old", "dir" => nil, "level" => "space", "note" => nil }
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
