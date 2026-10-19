# frozen_string_literal: true

require "json"
require "open3"

module Anfs
  Result = Data.define(:rows, :error, :exit_code) do
    def ok? = error.nil?
  end

  # Runs one anfs tool with --json and returns a Result. Never raises: the
  # tools report failure as text on stderr plus an exit code, and a panel has
  # to be able to show that.
  class CLI
    # The tools append every invocation to a shared log. The poller follows
    # that log, so our own calls must stay out of it.
    ENV_OVERRIDES = { "ANFS_LOG" => "off" }.freeze

    # In a container the tools are not there: they run on the host, and the toolkit API that will
    # reach them from here (anfs rpc) does not exist yet.
    UNAVAILABLE = "the tools are not reachable from here (no toolkit API yet)"

    class Timeout < StandardError; end

    def initialize(bin_dir: ENV.fetch("ANFS_BIN", File.expand_path("~/.local/bin")), timeout: 30)
      @bin_dir = bin_dir
      @timeout = timeout
    end

    def run(tool, *)
      path = File.join(@bin_dir, tool)
      return failure("#{tool}: #{UNAVAILABLE}", nil) unless File.executable?(path)

      out, err, status = capture(path, *, "--json")
      status.success? ? parse(tool, out) : failure(err.strip, status.exitstatus)
    rescue JSON::ParserError
      failure("#{tool}: output was not JSON", 0)
    rescue Timeout
      failure("#{tool}: no answer after #{@timeout}s", nil)
    rescue SystemCallError => e
      failure(e.message, nil)
    end

    private

    def parse(tool, out)
      rows = JSON.parse(out)
      rows.is_a?(Array) ? Result.new(rows:, error: nil, exit_code: 0) : failure("#{tool}: expected a JSON list", 0)
    end

    def failure(message, exit_code)
      Result.new(rows: nil, error: message.empty? ? "exit #{exit_code}" : message, exit_code:)
    end

    # Own process group, so a timeout takes the tool's children with it
    # (psm runs npx).
    def capture(*cmd)
      Open3.popen3(ENV_OVERRIDES, *cmd, pgroup: true) do |stdin, stdout, stderr, wait|
        stdin.close
        out, err = [stdout, stderr].map { |io| reader(io) }
        unless wait.join(@timeout)
          kill_group(wait.pid)
          raise Timeout
        end
        [out.value, err.value, wait.value]
      end
    end

    # Quiet: on a timeout the pipes are closed under these threads.
    def reader(io) = Thread.new { io.read }.tap { it.report_on_exception = false }

    def kill_group(pid)
      Process.kill("TERM", -pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
