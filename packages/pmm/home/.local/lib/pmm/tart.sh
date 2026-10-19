#!/usr/bin/env bash
# pmm library: the tart backend — macOS guests on Apple silicon (Virtualization.framework).
# Sourced by ~/.local/bin/pmm; functions only.
#
# A tart image starts from an OCI base (base:, e.g. ghcr.io/cirruslabs/macos-tahoe-vanilla)
# rather than an ISO. Its VMs live in tart's own store (~/.tart, which also caches the base
# images), named by pmm:
#
#   pmm-image-<name>-<key>        a build (stopped; cloned, never booted read-write)
#   pmm-image-<name>-building     a build in progress
#   pmm-image-<name>-test         the throwaway copy `pmm image test` boots
#   pmm-<name>                    a machine, a clone of a build (machine.sh)
#
# What starts, reaches and stops a tart VM serves builds and machines alike, so those functions
# take the VM and what they need, never an image id.
#
# Clones are APFS copy-on-write, so they cost seconds and almost no disk. The stock image's own
# account (user.bootstrap, default admin/admin) is used once with its password to install the
# image's key; the provision steps then run as root through its sudo, which wants the password
# again: pmm puts an askpass helper in the guest before the first step and takes it out after the
# last, so a provisioner is given a way to be root (guest_ssh, ssh.sh) and never the password.
# user.name is who `pmm shell` logs in as (a step creates it and authorizes
# $ANFS_IMAGE_SSH_PUBKEY when it is not the bootstrap account).
#
# Shutting down is from inside the guest, then waiting for tart: `tart stop` can return while the
# guest's last writes are still buffered, and a clone taken then has an older APFS checkpoint.

tart_vm_build() { echo "pmm-image-$1-$2"; }

# Every VM that is <name>'s: its builds, one in progress, a test's copy. Not another image's
# whose name starts with this one's.
_tart_image_vms() {
  local names vm rest
  names=$(_tart_names) || true
  # the name is compared as text: a . in it is not a pattern's
  while IFS= read -r vm; do
    rest="${vm#"pmm-image-$1-"}"
    [[ "$vm" != "$rest" && "$rest" =~ ^([0-9a-f]{16}|building|test)$ ]] && echo "$vm"
  done <<< "$names"
  return 0
}

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

# How a provisioner is root in a tart guest: the bootstrap account's sudo, with an askpass helper
# (sudo -S would read the password from stdin, which carries the step). The helper holds the
# stock image's own password, readable only by its account. Sets GUEST_DIR and GUEST_ENV.
TART_ASKPASS=/tmp/pmm-askpass
_tart_guest() {  # <dir> <key> <ip>
  local dir="$1" key="$2" ip="$3"
  printf '#!/bin/sh\necho %s\n' "$(shq "$BOOT_PW")" |
    _tart_ssh "$key" "$ip" "$BOOT_USER" "umask 077; cat > $TART_ASKPASS && chmod 700 $TART_ASKPASS" || return 1
  guest_ssh "$dir" "SUDO_ASKPASS=$TART_ASKPASS sudo -A" "$ip" 22 "$BOOT_USER" "$key" \
    ssh "${TART_SSH_OPTS[@]}" -o BatchMode=yes -o IdentitiesOnly=yes -i "$key" "$BOOT_USER@$ip"
}

# Take out of the guest what pmm put there for the steps: files/ (root's), then the helper
_tart_guest_close() {  # <key> <ip>
  "$GUEST_DIR/exec" rm -rf /tmp/pmm-files || true
  _tart_ssh "$1" "$2" "$BOOT_USER" "rm -f $TART_ASKPASS"
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

TART_BUILDING="" TART_GUEST=""

# A failed build: stop its VM and delete it
_tart_build_cleanup() {
  [[ -n "$BUILD_PID" ]] && pid_alive "$BUILD_PID" && { tart stop "$TART_BUILDING" >/dev/null 2>&1 || kill "$BUILD_PID" 2>/dev/null; wait_exit "$BUILD_PID" 20 || kill -9 "$BUILD_PID" 2>/dev/null; }
  [[ -n "$TART_BUILDING" ]] && tart delete "$TART_BUILDING" >/dev/null 2>&1
  [[ -n "$TART_GUEST" ]] && rm -rf "$TART_GUEST"
  BUILD_PID="" TART_BUILDING="" TART_GUEST=""
  return 0
}

tart_build() {
  local id="$1" arch="$2" key="$3"
  local name bname base vm built sshkey user ip pid start log s cpus mem disk
  [[ "$(host_os)" == darwin && "$(host_arch)" == arm64 ]] || die "tart images build only on Apple silicon macOS"
  command -v tart >/dev/null || die "tart is not installed (ppm install core/pmm)"
  name=$(img_name "$id") bname=$(img_bname "$id")
  _tart_boot "$id"
  base=$(img_get "$(img_root "$id")" .base)
  sshkey=$(img_key "$id")
  user=$(img_user "$id")
  vm="pmm-image-$name-building"
  log="$PMM_STATE_HOME/logs/$bname-$arch"
  mkdir -p "$log" "$(meta_dir "$bname" "$arch")"
  start=$(date +%s)

  echo "== build $id (tart) -> $key"
  tart delete "$vm" >/dev/null 2>&1 || true
  local parent
  parent=$(img_parent "$id") || parent=""
  if [[ -n "$parent" ]]; then
    tart clone "$(tart_vm_build "$(img_name "$parent")" "$(meta_get "$(img_bname "$parent")" "$arch" .cache_key)")" "$vm"
  else
    echo "Cloning $base (a first pull downloads the image, ~25GB for macOS)"
    tart clone "$base" "$vm" || die "tart clone $base failed"
  fi
  cpus=$(img_setting "$id" .build.cpus 4)
  mem=$(img_setting "$id" .build.memory 8192)
  disk=$(img_setting "$id" .build.disk "")
  tart set "$vm" --cpu "$cpus" --memory "$mem" ${disk:+--disk-size "${disk%G}"}

  pid=$(_tart_run "$vm" "$log/boot.log")
  BUILD_PID="$pid"
  TART_BUILDING="$vm"
  anfs_on_exit _tart_build_cleanup
  trap 'exit 130' INT TERM
  ip=$(tart ip "$vm" --wait 180 2>/dev/null) || die "$vm got no address; see $(tilde "$log/boot.log")"
  echo "Booted ($ip); installing the image's key for $BOOT_USER"
  if [[ -z "$parent" ]]; then
    _tart_wait 300 _tart_ssh_pw "$ip" "$BOOT_USER" "$BOOT_PW" true || die "no ssh to $BOOT_USER@$ip"
    _tart_ssh_pw "$ip" "$BOOT_USER" "$BOOT_PW" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < "$sshkey.pub" ||
      die "could not install the key for $BOOT_USER"
  fi
  _tart_wait 300 _tart_ssh "$sshkey" "$ip" "$BOOT_USER" true || die "no key login for $BOOT_USER@$ip"

  TART_GUEST="$PMM_STATE_HOME/build/$bname-$arch"
  _tart_guest "$TART_GUEST/guest" "$sshkey" "$ip" || die "could not install the askpass helper for $BOOT_USER"
  prov_image_env "$id" "$arch"
  PROV_ENV+=("${GUEST_ENV[@]}")
  : > "$log/provision.log"
  provision_steps "$id" "$log/provision.log"
  # what finalize is to a qemu build: nothing of pmm's own is left in the image
  _tart_guest_close "$sshkey" "$ip" || die "could not remove the askpass helper"
  rm -rf "$TART_GUEST"
  TART_GUEST=""

  # A reboot, so whatever the steps set up for boot (synthetic.conf, launchd) is in place
  echo "Rebooting"
  _tart_ssh "$sshkey" "$ip" "$BOOT_USER" "printf '%s\n' $(shq "$BOOT_PW") | sudo -S -p '' shutdown -r now" >/dev/null 2>&1 || true
  sleep 20
  ip=$(tart ip "$vm" --wait 180 2>/dev/null) || die "$vm got no address after the reboot"
  _tart_wait 300 _tart_ssh "$sshkey" "$ip" "$user" true || die "no key login for $user@$ip after the reboot"

  echo "Shutting down"
  _tart_shutdown "$vm" "$pid" "$sshkey" "$ip"
  BUILD_PID=""
  anfs_on_exit ''; trap - INT TERM
  TART_BUILDING=""
  built=$(tart_vm_build "$name" "$key")
  tart delete "$built" >/dev/null 2>&1 || true
  tart rename "$vm" "$built"
  # superseded builds: nothing is an overlay on a tart build (clones are independent). The build
  # of a parent of the same name (from: its own name) is not one: it is that definition's current
  local keep=""
  [[ -z "$parent" || "$(img_name "$parent")" != "$name" ]] ||
    keep=$(tart_vm_build "$name" "$(meta_get "$(img_bname "$parent")" "$arch" .cache_key)")
  _tart_image_vms "$name" | while read -r s; do
    [[ "$s" == "$built" || "$s" == "$keep" || "$s" == *-building || "$s" == *-test ]] || tart delete "$s" >/dev/null 2>&1 || true
  done || true
  meta_write_build "$id" "$arch" "$key" "$parent"
  meta_set "$bname" "$arch" '.disk = strenv(v)' "$built"
  echo "Built $id (tart) in $(( $(date +%s) - start ))s: $built"
}

tart_test() {
  local id="$1" name key built vm script pid ip sshkey user log rc=0
  name=$(img_name "$id")
  key=$(meta_get "$(img_bname "$id")" arm64 .cache_key)
  built=$(tart_vm_build "$name" "$key")
  tart_exists "$built" || die "$id has no tart build (pmm image build $id)"
  script=$(img_test_script "$id") || true
  [[ -n "$script" ]] || { echo "$id has no test.sh; nothing to test"; return 0; }
  _tart_boot "$id"
  sshkey=$(img_key "$id")
  user=$(img_user "$id")
  vm="pmm-image-$name-test"
  log="$PMM_STATE_HOME/logs/$(img_bname "$id")-arm64"
  mkdir -p "$log"
  tart delete "$vm" >/dev/null 2>&1 || true
  tart clone "$built" "$vm"
  local -a shares=()
  mapfile -t shares < <(img_list "$id" .shares)
  _tart_dirs ${shares[@]+"${shares[@]}"}
  echo "== test $id (tart, $key) with $(tilde "$script")"
  pid=$(_tart_run "$vm" "$log/test.log" ${TART_DIRS[@]+"${TART_DIRS[@]}"})
  if ip=$(tart ip "$vm" --wait 180 2>/dev/null) && _tart_wait 300 _tart_ssh "$sshkey" "$ip" "$user" true; then
    # test.sh is a shell script: the sh provisioner runs it, as it does a .sh step. The copy is
    # deleted below, and the askpass helper with it
    if _tart_guest "$PMM_STATE_HOME/build/test-$(img_bname "$id")-arm64/guest" "$sshkey" "$ip"; then
      prov_image_env "$id" arm64
      PROV_ENV+=("${GUEST_ENV[@]}" ANFS_IMAGE_FILES=)
      prov_run "$script" || rc=$?
    else
      rc=1
    fi
    rm -rf "$PMM_STATE_HOME/build/test-$(img_bname "$id")-arm64"
  else
    rc=1
  fi
  tart stop "$vm" >/dev/null 2>&1 || true
  wait_exit "$pid" 30 || kill -9 "$pid" 2>/dev/null || true
  tart delete "$vm" >/dev/null 2>&1 || true
  if [[ $rc -eq 0 ]]; then
    meta_set "$(img_bname "$id")" arm64 '.tested_key = strenv(v)' "$key"
    echo "Tested $id (tart)"
  else
    echo "The test of $id (tart) FAILED"
  fi
  return $rc
}

tart_rm() {
  # tart creates its home on any command; a machine that never ran tart has none to clean
  [[ -d "${TART_HOME:-$HOME/.tart}" ]] || return 0
  local name="$1" vm
  command -v tart >/dev/null || return 0
  _tart_image_vms "$name" | while read -r vm; do [[ -z "$vm" ]] || tart delete "$vm" >/dev/null 2>&1 || true; done || true
}

