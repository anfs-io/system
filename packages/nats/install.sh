# nats
#
# core/nats's hooks: NATS with JetStream, the anfs bus (lib/anfs/bus.sh). post_install fetches the
# pinned nats-server and nats CLI (pins.yml, lib/anfs/pins.sh) into ~/.local/share/nats/<version>/
# and links them from ~/.local/bin; makes ~/.local/state/nats/ (0700: a password per user, made
# once; server.conf rendered from nats.env; the port); writes and loads the service
# (lib/anfs/service.sh: io.anfs.nats, anfs-nats.service). post_remove unloads and deletes the
# service and the links; DATA, the store and the passwords stay (anfs implode removes STATE).
#
# The libs are sourced from core/anfs in this checkout, not from ~/.local/lib: post_remove runs
# after the unstow.

_nats_pkg() {
  local here lib f
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  lib="$here/../anfs/home/.local/lib/anfs"
  for f in paths service pins bus; do
    # shellcheck source=/dev/null
    source "$lib/$f.sh"
  done
  NATS_PKG_DIR="$here"
  anfs_bus_paths
}

post_install() {
  _nats_pkg
  local name
  local -A prog=()
  # both fetched before anything is linked: a failure leaves no link
  for name in nats-server nats; do
    anfs_pin_fetch "$NATS_PKG_DIR/pins.yml" "$name" nats || { ppm_fail "$PIN_ERR"; return; }
    prog[$name]="$REPLY"
  done
  for name in nats-server nats; do
    anfs_pin_link "${prog[$name]}" "$name" || { ppm_fail "$PIN_ERR"; return; }
  done
  anfs_bus_nats_users
  anfs_bus_nats_conf || { ppm_fail "server.conf not written: fix the settings in ~/.config/nats/nats.local.env"; return; }
  anfs_bus_nats_unit
  anfs_service_load ANFS_BUS_SVC_NATS
  user_message "NATS listens on 127.0.0.1:$ANFS_NATS_PORT (monitoring $ANFS_NATS_HTTP_PORT); anfs bus status, anfs bus nats -- <args>"
}

post_remove() {
  _nats_pkg
  anfs_service_remove ANFS_BUS_SVC_NATS
  anfs_pin_unlink nats-server
  anfs_pin_unlink nats
}
