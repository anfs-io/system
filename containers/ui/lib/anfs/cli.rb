# frozen_string_literal: true

require "json"
require "open3"

module Anfs
  # command is set for exit 77: what to run in a terminal instead.
  Result = Data.define(:rows, :error, :exit_code, :command) do
    def initialize(command: nil, **) = super

    def ok? = error.nil?

    def needs_terminal? = exit_code == NEEDS_TERMINAL
  end

  # A confirm or a sudo the toolkit API cannot answer: the command has to be run by a person.
  NEEDS_TERMINAL = 77

  # Runs one anfs tool with --json and returns a Result, through the toolkit API when there is
  # one (ANFS_RPC_URL), else from ANFS_BIN. Never raises: the tools report failure as text on
  # stderr plus an exit code, and a panel has to be able to show that.
  class CLI
    # The tools append every invocation to a shared log; a dashboard's reads
    # are not worth a line in it.
    ENV_OVERRIDES = { "ANFS_LOG" => "off" }.freeze

    # Neither the toolkit API (ANFS_RPC_URL) nor the tools themselves (ANFS_BIN).
    UNAVAILABLE = "the tools are not reachable from here (no ANFS_RPC_URL, and not in ANFS_BIN)"

    class Timeout < StandardError; end

    def initialize(bin_dir: ENV.fetch("ANFS_BIN", File.expand_path("~/.local/bin")), timeout: 30,
                   rpc: RPC.from_env)
      @bin_dir = bin_dir
      @timeout = timeout
      @rpc = rpc
    end

    def run(tool, *) = @rpc ? remote(tool, *) : local(tool, *)

    private

    def local(tool, *)
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

    # The API adds --json and ANFS_LOG=off to a read itself.
    def remote(tool, *)
      answer = @rpc.call({ run: [tool, *] })
      return failure(answer["error"].to_s, answer["exit"], answer["command"]) if answer["error"] || answer["exit"] != 0

      rows(tool, answer["data"])
    rescue RPC::Error => e
      failure(e.message, nil)
    end

    def parse(tool, out) = rows(tool, JSON.parse(out))

    def rows(tool, rows)
      rows.is_a?(Array) ? Result.new(rows:, error: nil, exit_code: 0) : failure("#{tool}: expected a JSON list", 0)
    end

    def failure(message, exit_code, command = nil)
      Result.new(rows: nil, error: message.empty? ? "exit #{exit_code}" : message, exit_code:, command:)
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
