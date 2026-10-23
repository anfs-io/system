# frozen_string_literal: true

require "time"

module Anfs
  # The latest events from the bus, newest first, for the events page. In memory: a restart
  # starts it empty (`anfs events ls` reads the complete record).
  class EventLog
    KEEP = 100

    # space: the space's path when the event has one, else its scope (a space id, or host).
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
      Entry.new(time: time(event["time"]), type: event["type"].to_s.delete_prefix("io.anfs."),
                subject: event["subject"], space: space(event), by: by(event))
    end

    def self.time(value)
      Time.iso8601(value.to_s).localtime
    rescue ArgumentError
      nil
    end

    # /anfs/host, or /anfs/spaces/<id>
    def self.space(event) = event["spacepath"] || event["source"].to_s.split("/").last

    def self.by(event)
      [event["actor"], ("as #{event["actorrole"]}" if event["actorrole"])].compact.join(" ")
    end
  end
end
