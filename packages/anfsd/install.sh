# anfsd
#
# core/anfsd's hooks: anfsd, the anfs daemon (anfs-io/runtime; lib/anfs/bus.sh). post_install
# fetches the pinned release (pins.yml, lib/anfs/pins.sh) into ~/.local/share/anfsd/<version>/ and
# links it from ~/.local/bin; ANFSD_BIN (anfsd.local.env) runs one built from source instead, and
# is enough while no release is pinned. Then the service is written and loaded (io.anfs.anfsd,
# anfsd.service: after NATS, KillMode=process). post_remove unloads and deletes it and the link;
# ~/.local/state/anfsd (the cursors) stays.

_anfsd_pkg() {
  local here lib f
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  lib="$here/../anfs/home/.local/lib/anfs"
  for f in paths service pins bus; do
    # shellcheck source=/dev/null
    source "$lib/$f.sh"
  done
  ANFSD_PKG_DIR="$here"
  anfs_bus_paths
}

post_install() {
  _anfsd_pkg
  if anfs_pin_fetch "$ANFSD_PKG_DIR/pins.yml" anfsd anfsd; then
    anfs_pin_link "$REPLY" anfsd || { ppm_fail "$PIN_ERR"; return; }
  elif [[ -n "${ANFSD_BIN:-}" ]]; then
    user_message "No anfsd release installed ($PIN_ERR); the service runs ANFSD_BIN=$ANFSD_BIN"
  else
    ppm_fail "$PIN_ERR; or build anfsd from source and set ANFSD_BIN in ~/.config/anfsd/anfsd.local.env (core/anfsd's README)"
    return
  fi
  if ! anfs_bus_anfsd_unit; then
    ppm_fail "ANFSD_BIN=$ANFSD_BIN is not an executable file"
    return
  fi
  anfs_service_load ANFS_BUS_SVC_ANFSD
  user_message "anfsd ships the event log to NATS (${ANFS_BUS_ANFSD_FROM:-release}); anfs bus status"
}

post_remove() {
  _anfsd_pkg
  anfs_service_remove ANFS_BUS_SVC_ANFSD
  anfs_pin_unlink anfsd
}
