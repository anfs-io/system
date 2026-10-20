# frozen_string_literal: true

require "roda"
require "phlex"
require "securerandom"
require "socket"

require_relative "lib/anfs"
require_relative "views/components"
require_relative "views/layout"
require_relative "views/overview"
require_relative "views/panel"
require_relative "views/jobs"
require_relative "event_stream"

class App < Roda
  # A page on any website can make the browser call localhost. Answering only
  # to our own names stops it reading the inventory through DNS rebinding.
  HOSTS = [
    "localhost", "127.0.0.1", "[::1]", Socket.gethostname, "#{Socket.gethostname.delete_suffix(".local")}.local",
    *Socket.ip_address_list.reject(&:ipv6?).map(&:ip_address), *ENV.fetch("ANFS_UI_HOSTS", "").split(",")
  ].uniq.freeze

  LOOPBACK = ["127.0.0.1", "::1"].freeze
  TURBO_STREAM = "text/vnd.turbo-stream.html; charset=utf-8"

  # What one page shows and the event stream keeps current: the DOM id, the
  # hub keys it depends on (nil for all), and how to build it.
  Watch = Data.define(:target, :keys, :content)

  opts[:store] = Anfs::Store.new
  opts[:hub] = Anfs::Hub.new
  opts[:jobs] = Anfs::Jobs.new(hub: opts[:hub])
  # There is no login. Running commands is for whoever is sitting at this
  # machine, unless this says other machines may too.
  opts[:remote_actions] = ENV["ANFS_UI_REMOTE_ACTIONS"] == "1"
  # In the container every request comes from podman's forwarder, never loopback, so the
  # address it is published on decides instead: published on loopback, only this machine
  # reaches it. Unset on the host (bundle exec puma), where REMOTE_ADDR is real.
  opts[:local_only] = LOOPBACK.include?(ENV.fetch("ANFS_UI_BIND", nil))

  plugin :heartbeat, path: "/up"
  plugin :host_authorization, HOSTS
  plugin :public
  plugin :default_headers, "content-type" => "text/html; charset=utf-8", "x-content-type-options" => "nosniff",
                           "x-frame-options" => "deny", "referrer-policy" => "no-referrer"
  plugin :content_security_policy do |csp|
    csp.default_src :self
    csp.base_uri :none
    csp.form_action :self
    csp.frame_ancestors :none
  end
  plugin :custom_block_results
  handle_block_result(Phlex::SGML, &:call)
  plugin :not_found do
    "Not found"
  end

  route do |r|
    check_host_authorization!
    r.public

    r.root { page("Overview", "overview") }

    r.get "stream" do
      next unless (watch = watch(r.params["show"].to_s))

      r.halt [200, EventStream::HEADERS.dup,
              EventStream.new(hub: opts[:hub], target: watch.target, keys: watch.keys, &watch.content)]
    end

    r.on "jobs" do
      r.get(true) { page("Activity", "jobs") }
      r.get(String) { |id| page("Activity", "job:#{id}") }
    end

    r.on String do |key|
      next unless (kind = Anfs::KINDS[key])

      r.get(true) { page(kind.label, key) }
      r.post("action") { act(kind, r.params["verb"], r.params["subject"]) }
    end
  end

  private

  def store = opts[:store]
  def jobs = opts[:jobs]

  def watch(show)
    case show
    when "overview" then Watch.new("overview", nil, -> { Views::Overview.new(store:) })
    when "jobs" then Watch.new("jobs", ["jobs"], -> { Views::JobList.new(jobs: jobs.all) })
    when /\Ajob:(\h+)\z/ then watch_job(show, Regexp.last_match(1))
    else watch_kind(Anfs::KINDS[show])
    end
  end

  def watch_job(show, id)
    Watch.new("job-#{id}", [show], -> { Views::JobPanel.new(job: jobs[id]) }) if jobs[id]
  end

  def watch_kind(kind)
    return unless kind

    latest = -> { jobs.latest(kind.key) if may_act? }
    Watch.new("panel-#{kind.key}", [kind.key],
              -> { Views::Panel.new(kind:, snapshot: store[kind.key], jobs: latest.call) })
  end

  # Nil, and so a 404, for something that cannot be shown.
  def page(title, show)
    return unless (watch = watch(show))

    content = watch.content.call
    if (kind = Anfs::KINDS[show])
      content = Views::KindPage.new(kind:, panel: content, query: request.params["q"].to_s)
    end
    nonce = SecureRandom.base64(16)
    content_security_policy.add_style_src(:self, [:nonce, nonce])
    Views::Layout.new(title:, show:, nonce:, content:)
  end

  # Runs the action a row offers, and only that: the verb and subject must be
  # what the kind says can be done to a row it currently lists.
  def act(kind, verb, subject)
    refuse(403) unless may_act? && same_origin?
    refuse(422) unless offered?(kind, verb, subject)

    jobs.start(kind, verb, subject)
    response["content-type"] = TURBO_STREAM
    Views::Stream.new(target: "panel-#{kind.key}", content: watch_kind(kind).content.call)
  end

  def offered?(kind, verb, subject) = kind.action && store.rows(kind.key).any? { kind.action[it] == [verb, subject] }

  def refuse(status)
    response.status = status
    request.halt
  end

  def may_act? = opts[:remote_actions] || opts[:local_only] || LOOPBACK.include?(env["REMOTE_ADDR"])

  # A form on another site can post here too; the browser says where from.
  def same_origin? = env["HTTP_ORIGIN"] == "#{request.scheme}://#{env["HTTP_HOST"]}"
end
