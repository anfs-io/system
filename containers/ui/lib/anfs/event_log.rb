# frozen_string_literal: true

require "time"

module Anfs
  # The latest events from the bus, newest first, for the events page. In memory: a restart
  # starts it empty (`anfs events ls` reads the complete record).
  class EventLog
    KEEP = 100

    # type: the short type (the event spec, anfs-io/events: io.anfs. dropped from anfs's types,
    # io. from another layer's: cnfs.partitia.report.filed). space: the space's path when the
    # event has one, else its scope (a space id, or host), from any layer's source.
    Entry = Data.define(:time, :type, :subject, :space, :by)

    def initialize(keep: KEEP)
      @keep = keep
      @mutex = Mutex.new
      @entries = []
    end

    def add(event)
      entry = self.class.entry(event)
      @mutex.synchronize { @entries.unshift(entry).slice!(@keep..) }
      entry
    end

    def all = @mutex.synchronize { @entries.dup }

    def self.entry(event)
      Entry.new(time: time(event["time"]), type: short(event["type"].to_s),
                subject: event["subject"], space: space(event), by: by(event))
    end

    def self.time(value)
      Time.iso8601(value.to_s).localtime
    rescue ArgumentError
      nil
    end

    def self.short(type) = type.start_with?("io.anfs.") ? type.delete_prefix("io.anfs.") : type.delete_prefix("io.")

    # /<layer>/host or /<layer>/spaces/<id>, each with segments of the layer's after it
    def self.space(event)
      return event["spacepath"] if event["spacepath"]

      m = event["source"].to_s.match(%r{\A/[a-z][a-z0-9-]*/(host|spaces/([a-z0-9]{10}))(/|\z)})
      m && (m[2] || m[1])
    end

    def self.by(event)
      [event["actor"], ("as #{event["actorrole"]}" if event["actorrole"])].compact.join(" ")
    end
  end
end
