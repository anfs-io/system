#!/usr/bin/env bash
# pim library: the tart backend — macOS guests on Apple silicon (Virtualization.framework).
# Sourced by ~/.local/bin/pim; functions only.
#
# A tart image starts from an OCI base (base:, e.g. ghcr.io/cirruslabs/macos-tahoe-vanilla)
# rather than an ISO. Its VMs live in tart's own store (~/.tart, which also caches the base
# images), named by pim:
#
#   pim-<name>-<key>        a build (stopped; cloned, never booted read-write)
#   pim-<name>-building     a build in progress
#   pim-<name>-verify       the throwaway copy `pim verify` boots
#
# Machines made from a build are pmm's (pmm-<name>); pmm sources this file for what starts, reaches
# and stops a tart VM, so those functions take the VM and what they need, never an image id.
#
# Clones are APFS copy-on-write, so they cost seconds and almost no disk. The stock image's own
# account (user.bootstrap, default admin/admin) is used once with its password to install the
# image's key; scripts then run as root through its sudo. user.name is who `pmm shell` logs in as
# (a script creates it and authorizes $PIM_SSH_PUBKEY when it is not the bootstrap account).
#
# Shutting down is from inside the guest, then waiting for tart: `tart stop` can return while the
# guest's last writes are still buffered, and a clone taken then has an older APFS checkpoint.

tart_vm_build() { echo "pim-$1-$2"; }

_tart_names() {
  tart list --format json 2>/dev/null | yq -p json -r '.[] | select(.Source == "local") | .Name' 2>/dev/null
}
# The names are read whole first: grep -q leaves at its first match, and under pipefail a writer
# cut short by that would make the answer "no"
tart_exists() {
  local names
  names=$(_tart_names) || true
  grep -qx "$1" <<< "$names"
}
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
  # sudo -A with an askpass helper (sudo -S would read the password from stdin, which carries
  # the script). The helper holds the stock image's own password, readable only by its account.
  printf '#!/bin/sh\necho %s\n' "$(shq "$BOOT_PW")" |
    _tart_ssh "$key" "$ip" "$BOOT_USER" 'umask 077; cat > /tmp/pim-askpass && chmod 700 /tmp/pim-askpass' || return 1
  _tart_ssh "$key" "$ip" "$BOOT_USER" "SUDO_ASKPASS=/tmp/pim-askpass sudo -A env$env bash -s" < "$script" 2>&1 | sed 's/^/  | /'
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
# by its name. An earlier spec wins over a later one of the same tag. In the guest they appear
# under "/Volumes/My Shared Files/<tag>".
# Usage: _tart_dirs [spec...]
_tart_dirs() {
  local spec path tag ro d tags=" "
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
  done < <(printf '%s\n' "$@")
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

TART_BUILDING=""

# A failed build: stop its VM and delete it
_tart_build_cleanup() {
  [[ -n "$BUILD_PID" ]] && pid_alive "$BUILD_PID" && { tart stop "$TART_BUILDING" >/dev/null 2>&1 || kill "$BUILD_PID" 2>/dev/null; wait_exit "$BUILD_PID" 20 || kill -9 "$BUILD_PID" 2>/dev/null; }
  [[ -n "$TART_BUILDING" ]] && tart delete "$TART_BUILDING" >/dev/null 2>&1
  BUILD_PID="" TART_BUILDING=""
  return 0
}

tart_build() {
  local id="$1" arch="$2" key="$3"
  local name base vm built sshkey user ip pid start log s cpus mem disk
  [[ "$(host_os)" == darwin && "$(host_arch)" == arm64 ]] || die "tart images build only on Apple silicon macOS"
  command -v tart >/dev/null || die "tart is not installed (ppm install core/pim)"
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
  TART_BUILDING="$vm"
  trap _tart_build_cleanup EXIT
  trap 'exit 130' INT TERM
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
  trap - EXIT INT TERM
  TART_BUILDING=""
  built=$(tart_vm_build "$name" "$key")
  tart delete "$built" >/dev/null 2>&1 || true
  tart rename "$vm" "$built"
  # superseded builds: nothing is an overlay on a tart build (clones are independent)
  _tart_names | grep -E "^pim-$name-[0-9a-f]{16}\$" | grep -vx "$built" | while read -r s; do tart delete "$s" >/dev/null 2>&1 || true; done || true
  meta_write_build "$id" "$arch" "$key" "$parent"
  meta_set "$name" "$arch" '.disk = strenv(v)' "$built"
  echo "Built $id (tart) in $(( $(date +%s) - start ))s: $built"
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
  local -a shares=()
  mapfile -t shares < <(img_list "$id" .shares)
  _tart_dirs ${shares[@]+"${shares[@]}"}
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

tart_rm() {
  # tart creates its home on any command; a machine that never ran tart has none to clean
  [[ -d "${TART_HOME:-$HOME/.tart}" ]] || return 0
  local name="$1" vm
  command -v tart >/dev/null || return 0
  _tart_names | grep -E "^pim-$name(-|\$)" | while read -r vm; do tart delete "$vm" >/dev/null 2>&1 || true; done || true
}

tart_implode() {
  # tart creates its home on any command; a machine that never ran tart has none to clean
  [[ -d "${TART_HOME:-$HOME/.tart}" ]] || return 0
  local vm
  command -v tart >/dev/null || return 0
  _tart_names | grep '^pim-' | while read -r vm; do tart stop "$vm" >/dev/null 2>&1 || true; tart delete "$vm" >/dev/null 2>&1 || true; done || true
}
