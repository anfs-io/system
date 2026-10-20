# frozen_string_literal: true

require "open3"
require "securerandom"

module Anfs
  # Commands that change something, run in the background so the page does
  # not wait on them. Held in memory: a restart forgets the history, and the
  # tools' own log keeps the record.
  class Jobs
    NEEDS_TERMINAL_STATUS = "needs a terminal"
    REFUSED = "This dashboard may only read: its container.yml says toolkit: read, or the token is the read one."
    KEEP = 50
    MAX_LINES = 2000

    Job = Struct.new(:id, :key, :subject, :verb, :command, :status, :exit_code, :output, :started_at) do
      def running? = status == "running"
      def title = command.join(" ")
    end

    # on_finish is called with the kind once its command has ended.
    def initialize(hub:, bin_dir: ENV.fetch("ANFS_BIN", File.expand_path("~/.local/bin")), on_finish: nil,
                   rpc: RPC.from_env)
      @hub = hub
      @bin_dir = bin_dir
      @rpc = rpc
      @on_finish = on_finish
      @mutex = Mutex.new
      @jobs = []
    end

    # Nil when the subject already has a command running.
    def start(kind, verb, subject)
      return unless (job = claim(kind, verb, subject))

      Thread.new { run(job, kind) }
      announce(job)
      job
    end

    def all = @mutex.synchronize { @jobs.dup }

    def [](id) = all.find { it.id == id }

    # The newest job for each subject of a kind: what a row needs to show.
    def latest(key) = all.reverse.select { it.key == key }.to_h { [it.subject, it] }

    private

    def claim(kind, verb, subject)
      @mutex.synchronize do
        next if @jobs.any? { it.running? && it.key == kind.key && it.subject == subject }

        job = Job.new(SecureRandom.hex(4), kind.key, subject, verb, kind.action_command(verb, subject), "running",
                      nil, [], Time.now)
        @jobs.unshift(job).slice!(KEEP..)
        job
      end
    end

    def run(job, kind)
      @rpc ? remote(job) : local(job)
    rescue StandardError => e # whatever happens, the job must not stay "running"
      append(job, e.message)
      finish(job, nil)
    ensure
      @on_finish&.call(kind)
    end

    # Own process group: stopping the server from a terminal must not cut an
    # install off half-way.
    def local(job)
      Open3.popen2e(File.join(@bin_dir, job.command.first), *job.command.drop(1), pgroup: true) do |stdin, out, wait|
        stdin.close
        out.each_line { append(job, it) }
        finish(job, wait.value.exitstatus)
      end
    end

    # The API adds -y itself (yes), so the kind's own -y is left out. Only for a command the kind
    # says takes it: wsm, pcm and the rest refuse an option they do not declare.
    def remote(job)
      yes = job.command.include?("-y")
      answer = @rpc.call({ run: job.command - ["-y"], stream: true, yes: }) { append(job, it) }
      explain(job, answer)
      finish(job, answer["exit"])
    end

    def explain(job, answer)
      if (error = answer["error"])
        append(job, error)
        append(job, REFUSED) if error.start_with?("refused: a write")
      end
      append(job, "Run this in a terminal: #{Array(answer["command"]).join(" ")}") if answer["needs"] == "terminal"
    end

    def append(job, line)
      @mutex.synchronize do
        job.output << line.chomp.gsub(/\e\[[\d;]*m/, "")
        job.output.shift while job.output.size > MAX_LINES
      end
      @hub.publish("job:#{job.id}")
    end

    def finish(job, exit_code)
      @mutex.synchronize do
        job.exit_code = exit_code
        job.status = { 0 => "ok", NEEDS_TERMINAL => NEEDS_TERMINAL_STATUS }.fetch(exit_code, "failed")
      end
      announce(job)
    end

    def announce(job) = ["job:#{job.id}", "jobs", job.key].each { @hub.publish(it) }
  end
end
