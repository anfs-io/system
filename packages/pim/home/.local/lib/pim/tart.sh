#!/usr/bin/env bash
# pim library: the tart backend — macOS guests on Apple silicon (Virtualization.framework).
# Sourced by ~/.local/bin/pim; functions only.
#
# A tart image starts from an OCI base (base:, e.g. ghcr.io/cirruslabs/macos-tahoe-vanilla)
# rather than an ISO. Its VMs live in tart's own store (~/.tart, which also caches the base
# images), named by pim:
#
#   pim-<name>-<key>        a build (stopped; cloned, never booted read-write)
#   pim-<name>              the image's VM (pim up)
#   pim-<name>-snap-<snap>  a snapshot of it
#   pim-<name>-building     a build in progress
#
# Clones are APFS copy-on-write, so they cost seconds and almost no disk. The stock image's own
# account (user.bootstrap, default admin/admin) is used once with its password to install the
# image's key; scripts then run as root through its sudo. user.name is who `pim shell` logs in as
# (a script creates it and authorizes $PIM_SSH_PUBKEY when it is not the bootstrap account).
#
# Shutting down is from inside the guest, then waiting for tart: `tart stop` can return while the
# guest's last writes are still buffered, and a clone taken then has an older APFS checkpoint.

tart_vm_build() { echo "pim-$1-$2"; }

_tart_names() {
  tart list --format json 2>/dev/null | yq -p json -r '.[] | select(.Source == "local") | .Name' 2>/dev/null
}
tart_exists() { _tart_names | grep -qx "$1"; }
_tart_state() {
  tart list --format json 2>/dev/null | yq -p json -r ".[] | select(.Name == \"$1\") | .State" 2>/dev/null
}

# The bootstrap account of <id>'s root image: sets BOOT_USER, BOOT_PW
_tart_boot() {
  local root
  root=$(img_root "$1")
  BOOT_USER=$(img_get "$root" .user.bootstrap.name admin)
  BOOT_PW=$(img_get "$root" .user.bootstrap.password admin)
}

TART_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

_tart_ssh() {  # <key> <ip> <user> [args...]
  local key="$1" ip="$2" user="$3"
  shift 3
  ssh "${TART_SSH_OPTS[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$key" "$user@$ip" "$@"
}

# ssh with a password, through SSH_ASKPASS (no sshpass, and the password stays out of argv)
_tart_ssh_pw() {  # <ip> <user> <password> [args...]
  local ip="$1" user="$2" pw="$3" askpass rc=0
  shift 3
  askpass=$(mktemp)
  printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$(shq "$pw")" > "$askpass"
  chmod 700 "$askpass"
  SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    ssh "${TART_SSH_OPTS[@]}" -o PreferredAuthentications=password,keyboard-interactive \
      -o PubkeyAuthentication=no "$user@$ip" "$@" || rc=$?
  rm -f "$askpass"
  return $rc
}

# Run a local script as root through the bootstrap account's sudo
_tart_root() {  # <key> <ip> <script> [NAME=value...]
  local key="$1" ip="$2" script="$3" env="" kv
  shift 3
  for kv in "$@"; do env+=" $(shq "$kv")"; done
  _tart_ssh "$key" "$ip" "$BOOT_USER" "printf '%s\n' $(shq "$BOOT_PW") | sudo -S -p '' env$env bash -s" < "$script" 2>&1 | sed 's/^/  | /'
  return "${PIPESTATUS[0]}"
}

_tart_wait() {  # <secs> <command...>: until the command succeeds
  local secs="$1" start
  shift
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) - start < secs )) || return 1
    sleep 5
  done
}

# --dir arguments for shares: path[:tag][:ro]; a path ending in /* is each directory in it, tagged
# by its name. Extra specs (pim up --share) come first, and win over an image share of the same
# tag. In the guest they appear under "/Volumes/My Shared Files/<tag>".
# Usage: _tart_dirs <id> [extra spec...]
_tart_dirs() {
  local id="$1" spec path tag ro d tags=" "
  shift
  TART_DIRS=()
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    spec="${spec/\$\{ANFS_SOURCES_HOME\}/$ANFS_SOURCES_HOME}"
    ro=""
    [[ "$spec" == *:ro ]] && { ro=":ro"; spec="${spec%:ro}"; }
    path="${spec%%:*}"
    if [[ "$path" == */\* ]]; then
      for d in "${path%/\*}"/*/; do
        tag=$(basename "$d")
        [[ -d "$d" && "$tags" != *" $tag "* ]] || continue
        tags+="$tag "
        TART_DIRS+=("--dir=$tag:$(cd "$d" && pwd -P)$ro")
      done
    else
      tag=$(basename "$path"); [[ "$spec" == *:* ]] && tag="${spec#*:}"
      [[ "$tags" != *" $tag "* ]] || continue
      tags+="$tag "
      TART_DIRS+=("--dir=$tag:$(cd "$path" && pwd -P)$ro")
    fi
  done < <(printf '%s\n' "$@"; img_list "$id" .shares)
}

# Boot a VM headless in the background (tart has no daemon: the process is the VM); prints its pid
_tart_run() {  # <vm> <log> [tart run args...]
  local vm="$1" log="$2"
  shift 2
  nohup tart run --no-graphics "$@" "$vm" > "$log" 2>&1 &
  echo $!
}

# Shut a VM down from inside and wait for its tart process; tart stop only as a last resort
_tart_shutdown() {  # <vm> <pid> <key> <ip>
  local vm="$1" pid="$2" key="$3" ip="$4"
  _tart_ssh "$key" "$ip" "$BOOT_USER" "sync; printf '%s\n' $(shq "$BOOT_PW") | sudo -S -p '' shutdown -h now" >/dev/null 2>&1 || true
  wait_exit "$pid" 120 && return 0
  warn "$vm did not shut down; forcing it (its last writes may be lost)"
  tart stop "$vm" >/dev/null 2>&1 || true
  wait_exit "$pid" 30 || kill -9 "$pid" 2>/dev/null || true
}

tart_build() {
  local id="$1" arch="$2" key="$3"
  local name base vm built sshkey user ip pid start log s cpus mem disk
  [[ "$(host_os)" == darwin && "$(host_arch)" == arm64 ]] || die "tart images build only on Apple silicon macOS"
  command -v tart >/dev/null || die "tart is not installed (ppm install anfs/pim)"
  name=$(img_name "$id")
  _tart_boot "$id"
  base=$(img_get "$(img_root "$id")" .base)
  sshkey=$(pim_key "$id")
  user=$(img_user "$id")
  vm="pim-$name-building"
  log="$PIM_STATE_HOME/logs/$name-$arch"
  mkdir -p "$log" "$(meta_dir "$name" "$arch")"
  start=$(date +%s)

  echo "== build $id (tart) -> $key"
  tart delete "$vm" >/dev/null 2>&1 || true
  local parent
  parent=$(img_parent "$id") || parent=""
  if [[ -n "$parent" ]]; then
    tart clone "$(tart_vm_build "$(img_name "$parent")" "$(meta_get "$(img_name "$parent")" "$arch" .cache_key)")" "$vm"
  else
    echo "Cloning $base (a first pull downloads the image, ~25GB for macOS)"
    tart clone "$base" "$vm" || die "tart clone $base failed"
  fi
  cpus=$(img_setting "$id" .cpus 4)
  mem=$(img_setting "$id" .memory 8192)
  disk=$(img_setting "$id" .disk "")
  tart set "$vm" --cpu "$cpus" --memory "$mem" ${disk:+--disk-size "${disk%G}"}

  pid=$(_tart_run "$vm" "$log/boot.log")
  BUILD_PID="$pid"
  ip=$(tart ip "$vm" --wait 180 2>/dev/null) || die "$vm got no address; see $(tilde "$log/boot.log")"
  echo "Booted ($ip); installing the image's key for $BOOT_USER"
  if [[ -z "$parent" ]]; then
    _tart_wait 300 _tart_ssh_pw "$ip" "$BOOT_USER" "$BOOT_PW" true || die "no ssh to $BOOT_USER@$ip"
    _tart_ssh_pw "$ip" "$BOOT_USER" "$BOOT_PW" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < "$sshkey.pub" ||
      die "could not install the key for $BOOT_USER"
  fi
  _tart_wait 300 _tart_ssh "$sshkey" "$ip" "$BOOT_USER" true || die "no key login for $BOOT_USER@$ip"

  : > "$log/provision.log"
  while IFS= read -r s; do
    _provision "$log/provision.log" "$(basename "$s")" _tart_root "$sshkey" "$ip" "$s" \
      PIM_IMAGE="$name" PIM_ARCH="$arch" PIM_USER="$user" PIM_SSH_PUBKEY="$(cat "$sshkey.pub")"
  done < <(img_scripts "$id")

  # A reboot, so whatever the scripts set up for boot (synthetic.conf, launchd) is in place
  echo "Rebooting"
  _tart_ssh "$sshkey" "$ip" "$BOOT_USER" "printf '%s\n' $(shq "$BOOT_PW") | sudo -S -p '' shutdown -r now" >/dev/null 2>&1 || true
  sleep 20
  ip=$(tart ip "$vm" --wait 180 2>/dev/null) || die "$vm got no address after the reboot"
  _tart_wait 300 _tart_ssh "$sshkey" "$ip" "$user" true || die "no key login for $user@$ip after the reboot"

  echo "Shutting down"
  _tart_shutdown "$vm" "$pid" "$sshkey" "$ip"
  BUILD_PID=""
  built=$(tart_vm_build "$name" "$key")
  tart delete "$built" >/dev/null 2>&1 || true
  tart rename "$vm" "$built"
  # superseded builds: nothing is an overlay on a tart build (clones are independent)
  _tart_names | grep -E "^pim-$name-[0-9a-f]{16}\$" | grep -vx "$built" | while read -r s; do tart delete "$s" >/dev/null 2>&1 || true; done
  meta_write_build "$id" "$arch" "$key" "$parent"
  meta_set "$name" "$arch" '.disk = strenv(v)' "$built"
  echo "Built $id (tart) in $(( $(date +%s) - start ))s: $built"
}

tart_running() {
  local r
  r=$(run_dir "$1")
  [[ -f "$r/pid" ]] && pid_alive "$(cat "$r/pid")"
}

tart_up() {
  local id="$1" fresh="$2" name key built inst r pid ip sshkey user
  shift 2
  name=$(img_name "$id")
  key=$(meta_get "$name" arm64 .cache_key)
  built=$(tart_vm_build "$name" "$key")
  inst="pim-$name"
  tart_exists "$built" || die "$id has no tart build (pim build $id)"
  $fresh && tart delete "$inst" >/dev/null 2>&1 || true
  tart_exists "$inst" || tart clone "$built" "$inst"
  sshkey=$(pim_key "$id")
  user=$(img_user "$id")
  _tart_dirs "$id" "$@"
  r=$(run_dir "$name")
  mkdir -p "$r"
  pid=$(_tart_run "$inst" "$r/tart.log" ${TART_DIRS[@]+"${TART_DIRS[@]}"})
  printf '%s\n' "$pid" > "$r/pid"
  printf '%s\n' tart > "$r/backend"
  printf '%s\n' arm64 > "$r/arch"
  printf '%s\n' "$user" > "$r/user"
  printf '%s\n' "$sshkey" > "$r/key"
  printf '%s\n' "$id" > "$r/id"
  ip=$(tart ip "$inst" --wait 180 2>/dev/null) || die "$inst got no address; see $(tilde "$r/tart.log")"
  printf '%s\n' "$ip" > "$r/ip"
  printf '%s\n' 22 > "$r/port"
  _tart_wait "$PIM_SSH_TIMEOUT" _tart_ssh "$sshkey" "$ip" "$user" true || die "no ssh to $user@$ip"
  echo "$name is up: pim shell $name  (ssh $user@$ip -i $(tilde "$sshkey"))"
}

tart_shell() {
  local name="$1" user="$2" r ip
  shift 2
  r=$(run_dir "$name")
  ip=$(tart ip "pim-$name" --wait 30 2>/dev/null) || die "pim-$name has no address"
  if [[ $# -gt 0 ]]; then _tart_ssh "$(cat "$r/key")" "$ip" "$user" "$*"
  elif [[ -t 0 ]]; then _tart_ssh "$(cat "$r/key")" "$ip" "$user" -t
  else _tart_ssh "$(cat "$r/key")" "$ip" "$user" bash -s
  fi
}

tart_stop() {
  local name="$1" r ip
  r=$(run_dir "$name")
  _tart_boot "$(cat "$r/id")"
  ip=$(tart ip "pim-$name" --wait 10 2>/dev/null || cat "$r/ip")
  _tart_shutdown "pim-$name" "$(cat "$r/pid")" "$(cat "$r/key")" "$ip"
}

tart_verify() {
  local id="$1" name key built vm script pid ip sshkey user log rc=0
  name=$(img_name "$id")
  key=$(meta_get "$name" arm64 .cache_key)
  built=$(tart_vm_build "$name" "$key")
  tart_exists "$built" || die "$id has no tart build (pim build $id)"
  script=$(img_verify_script "$id") || true
  [[ -n "$script" ]] || { echo "$id has no verify.sh; nothing to verify"; return 0; }
  _tart_boot "$id"
  sshkey=$(pim_key "$id")
  user=$(img_user "$id")
  vm="pim-$name-verify"
  log="$PIM_STATE_HOME/logs/$name-arm64"
  mkdir -p "$log"
  tart delete "$vm" >/dev/null 2>&1 || true
  tart clone "$built" "$vm"
  _tart_dirs "$id"
  echo "== verify $id (tart, $key) with $(tilde "$script")"
  pid=$(_tart_run "$vm" "$log/verify.log" ${TART_DIRS[@]+"${TART_DIRS[@]}"})
  if ip=$(tart ip "$vm" --wait 180 2>/dev/null) && _tart_wait 300 _tart_ssh "$sshkey" "$ip" "$user" true; then
    _tart_root "$sshkey" "$ip" "$script" PIM_IMAGE="$name" PIM_ARCH=arm64 PIM_USER="$user" || rc=$?
  else
    rc=1
  fi
  tart stop "$vm" >/dev/null 2>&1 || true
  wait_exit "$pid" 30 || kill -9 "$pid" 2>/dev/null || true
  tart delete "$vm" >/dev/null 2>&1 || true
  if [[ $rc -eq 0 ]]; then
    meta_set "$name" arm64 '.verified_key = strenv(v)' "$key"
    echo "Verified $id (tart)"
  else
    echo "Verification of $id (tart) FAILED"
  fi
  return $rc
}

tart_snapshot() {
  local id="$1" snap="$2" name inst was=false
  name=$(img_name "$id")
  inst="pim-$name"
  tart_exists "$inst" || die "$name has no VM yet (pim up $name)"
  vm_running "$name" && { was=true; vm_stop "$name"; }
  tart delete "$inst-snap-$snap" >/dev/null 2>&1 || true
  tart clone "$inst" "$inst-snap-$snap"
  echo "Saved snapshot $snap of $name (pim reset $name $snap)"
  # Recreated from the snapshot rather than restarted: a restarted original has been seen to come
  # back without the writes the clone captured
  if $was; then
    tart delete "$inst" >/dev/null
    tart clone "$inst-snap-$snap" "$inst"
    tart_up "$id" false
  fi
}

tart_reset() {
  local id="$1" snap="$2" name inst was=false
  name=$(img_name "$id")
  inst="pim-$name"
  [[ -z "$snap" ]] || tart_exists "$inst-snap-$snap" || die "$name has no snapshot '$snap'"
  vm_running "$name" && { was=true; vm_stop "$name"; }
  tart delete "$inst" >/dev/null 2>&1 || true
  [[ -z "$snap" ]] || tart clone "$inst-snap-$snap" "$inst"
  echo "Reset $name${snap:+ to $snap}"
  $was && tart_up "$id" false
  return 0
}

tart_snapshots() { _tart_names | sed -n "s/^pim-$1-snap-//p"; }

tart_rm() {
  local name="$1" vm
  command -v tart >/dev/null || return 0
  _tart_names | grep -E "^pim-$name(-|\$)" | while read -r vm; do tart delete "$vm" >/dev/null 2>&1 || true; done
}

tart_implode() {
  local vm
  command -v tart >/dev/null || return 0
  _tart_names | grep '^pim-' | while read -r vm; do tart stop "$vm" >/dev/null 2>&1 || true; tart delete "$vm" >/dev/null 2>&1 || true; done
}
