# podman

install_linux() {
  _podman_subids

  # Podman API socket for docker-compatible clients (dockge, dev containers, testcontainers)
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user enable --now podman.socket
  else
    user_message "No systemd user session, so the podman API socket was not enabled.\nRun 'podman system service --time=0 &' when a docker-compatible client needs it."
  fi
}

# Rootless podman maps container IDs onto a subordinate range from /etc/subuid and /etc/subgid.
# useradd allocates one only if those files already exist, so an account created before uidmap
# was installed (Debian ships them in uidmap) has none, and podman fails with "newuidmap" or
# "no subuid ranges found". Give the user the next free 65536 IDs, then have podman re-read them.
_podman_subids() {
  local user f start next have_uid=false have_gid=false
  user=$(id -un)
  grep -q "^$user:" /etc/subuid 2>/dev/null && have_uid=true
  grep -q "^$user:" /etc/subgid 2>/dev/null && have_gid=true
  $have_uid && $have_gid && return 0

  # First ID past every range already handed out in either file, 100000 at the least
  start=100000
  for f in /etc/subuid /etc/subgid; do
    [[ -r "$f" ]] || continue
    next=$(awk -F: '$2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { e = $2 + $3; if (e > m) m = e } END { print m + 0 }' "$f")
    (( next > start )) && start=$next
  done

  local range="$start-$((start + 65535))" args=()
  $have_uid || args+=(--add-subuids "$range")
  $have_gid || args+=(--add-subgids "$range")
  _system_sudo "subordinate IDs for $user" \
    "Rootless podman needs subordinate IDs for $user; run: sudo usermod ${args[*]} $user && podman system migrate" ||
    return 0
  sudo -n usermod "${args[@]}" "$user" || { ppm_fail "usermod ${args[*]} $user failed"; return 0; }
  podman system migrate >/dev/null 2>&1 || true
  user_message "Gave $user subordinate IDs $range for rootless podman"
}

install_macos() {
  # Only the binaries here: the podman machine VM is created and started by pcm the first time a
  # service needs it (pcm_podman_ready), so an install never pays for a VM nobody uses.
  # Clients running in containers get the VM-side API socket from:
  #   podman info --format '{{.Host.RemoteSocket.Path}}'
  :
}
