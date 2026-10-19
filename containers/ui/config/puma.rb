# frozen_string_literal: true

# Loopback unless HOST says otherwise (HOST=0.0.0.0 for every interface).
# Every open page holds one thread for its event stream.
bind "tcp://#{ENV.fetch("HOST", "localhost")}:#{ENV.fetch("PORT", 9292)}"
threads 4, 32

# An event stream never finishes on its own, so do not wait for one on shutdown.
force_shutdown_after 1
