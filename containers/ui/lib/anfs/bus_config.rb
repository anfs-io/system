# frozen_string_literal: true

module Anfs
  class Bus
    # Where the bus is and who the ui is on it. ANFS_BUS_URL, ANFS_BUS_USER, ANFS_BUS_PASSWORD_FILE;
    # unset (or empty, as compose passes an unset variable), core/nats's own on this host: its port
    # file and users/reader.
    Config = Data.define(:url, :user, :password_file) do
      def self.from_env(env = ENV)
        nats = nats_dir(env)
        set = ->(key) { env[key] unless env[key].to_s.empty? }
        new(url: set["ANFS_BUS_URL"] || "nats://127.0.0.1:#{port(nats)}",
            user: set["ANFS_BUS_USER"] || "reader",
            password_file: set["ANFS_BUS_PASSWORD_FILE"] || File.join(nats, "users/reader"))
      end

      def self.nats_dir(env)
        state = env["XDG_STATE_HOME"].to_s
        File.join(state.empty? ? File.join(Dir.home, ".local/state") : state, "nats")
      end

      def self.port(nats)
        File.read(File.join(nats, "port")).strip
      rescue SystemCallError
        "47222"
      end
    end
  end
end
