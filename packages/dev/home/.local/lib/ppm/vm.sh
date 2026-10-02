#!/usr/bin/env bash
# anfs/dev — adds `ppm vm`: disposable macOS VMs for testing ppm on Apple Silicon
# Stowed to ~/.local/lib/ppm/ and sourced by ppm, so cmd_vm() is the command `ppm vm`
#
# The sibling of `ppm container`, with the same subcommands and the same contract: host source
# repos are mounted read-only at /src/<alias> and each test user's ppm data dirs link to them, so
# the box tests the working tree. What it adds over a container is everything a container cannot
# reach — login shells (so rc files and chsh are real), launchd services, and macOS itself, which
# is where ppm's most fragile paths live: the Xcode CLT, the Homebrew prefix, sysadminctl.
#
# Backed by tart (https://tart.run), which boots Apple's Virtualization.framework. Snapshots are
# APFS copy-on-write clones, so they cost seconds and almost no disk.

# vms/<target>/{vm.conf,provision.sh} live in the anfs/dev package, found through the stow link
PPM_VM_DIR="$(cd "$(_resolve_path "${BASH_SOURCE[0]}")/../../../.." && pwd)/vms"
PPM_VM_STATE_DIR="$PPM_CACHE_HOME/vm"
PPM_VM_KEY="$PPM_VM_STATE_DIR/id_ed25519"
PPM_VM_INSTALLER_URL=https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh
PPM_VM_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
                 -o LogLevel=ERROR -o ConnectTimeout=10)

cli_cmd vm "vm <command> <target> [...]" "Disposable macOS VMs (tart) for testing anfs installs"

cmd_vm() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  if [[ -n "$subcommand" && "$subcommand" != "help" ]]; then
    _vm_supported || return 1
  fi

  case "$subcommand" in
    build)    _vm_build "$@" ;;
    start)    _vm_start "$@" ;;
    shell)    _vm_shell "$@" ;;
    install)  _vm_install "$@" ;;
    snapshot) _vm_snapshot "$@" ;;
    reset)    _vm_reset "$@" ;;
    stop)     _vm_target "${1:-}" && _vm_stop "$1" ;;
    rm)       _vm_rm "$@" ;;
    list)     _vm_list ;;
    ip)       _vm_target "${1:-}" && tart ip "ppm-$1" --wait 5 ;;
    *)
      echo "Usage: ppm vm <command> <target> [...]"
      echo "  build <target> [--force]                      Pull the image, provision it, save it as the base"
      echo "                                                (a first pull is ~25GB; --force rebuilds an existing base)"
      echo "  start <target> [--from SNAPSHOT] [--sources a,b|none] [-- tart-run-args]"
      echo "                                                Start ppm-<target>; host sources mounted ro at /src"
      echo "                                                (--sources none for a clean box; -- passes extra"
      echo "                                                 tart run args, e.g. -- --dir=x:/tmp/x)"
      echo "  shell <target> [owner|other]                  Login shell as a test user"
      echo "  install <target> [owner|other] [--pushed] [installer args]"
      echo "                                                Run install.sh from the working tree (--pushed: from GitHub)"
      echo "  snapshot <target> <name>                      Save the VM as a snapshot, then recreate it from that"
      echo "  reset <target> [snapshot]                     Recreate from the base image or a snapshot"
      echo "  stop <target>                                 Shut the VM down"
      echo "  rm <target> [snapshot|--base]                 Remove the VM, one of its snapshots, or it and its base"
      echo "  ip <target>                                   The VM's address"
      echo "  list                                          VMs and snapshots"
      echo ""
      echo "Targets: $(_vm_targets)"
      echo "Users: owner (admin, password 'owner'), other (no admin)"
      echo "Host repos are mounted read-only, so commands that write into a repo (file claim) fail."
      echo "Apple allows two macOS guests running at once, per host."
      [[ -z "$subcommand" || "$subcommand" == "help" ]] || return 1
      ;;
  esac
}

# Apple silicon macOS only: Virtualization.framework runs macOS guests nowhere else
_vm_supported() {
  if [[ "$(os)" != "macos" || "$(arch)" != "arm64" ]]; then
    echo "ppm vm needs macOS on Apple silicon (this is $(os)/$(arch)); use ppm container instead"
    return 1
  fi
  if ! command -v tart >/dev/null 2>&1; then
    echo "ppm vm needs tart: ppm install -r anfs/dev (or brew trust openai/tools && brew install openai/tools/tart)"
    return 1
  fi
}

_vm_targets() {
  local dir names=""
  for dir in "$PPM_VM_DIR"/*/; do
    [[ -f "$dir/provision.sh" ]] && names="$names $(basename "$dir")"
  done
  echo "${names# }"
}

_vm_target() {
  local target="${1:-}"
  if [[ -z "$target" || ! -f "$PPM_VM_DIR/$target/provision.sh" ]]; then
    echo "Unknown target '${target}'. Available: $(_vm_targets)"
    return 1
  fi
  # VM_IMAGE, VM_ADMIN_USER, VM_ADMIN_PASSWORD, VM_CPU, VM_MEMORY
  source "$PPM_VM_DIR/$target/vm.conf"
}

_vm_user() {
  case "${1:-}" in
    owner|other) return 0 ;;
    *) echo "Unknown user '${1:-}'. Test users: owner, other"; return 1 ;;
  esac
}

# tart's table output pads and wraps; its JSON is parsed with yq, which ppm already requires
_vm_state() {
  tart list --format json 2>/dev/null |
    yq -p json -r ".[] | select(.Name == \"$1\") | .State" 2>/dev/null
}

_vm_exists() { [[ -n "$(_vm_state "$1")" ]]; }

_vm_is_running() { [[ "$(_vm_state "$1")" == "running" ]]; }

_vm_running() {
  if ! _vm_is_running "ppm-$1"; then
    echo "ppm-$1 is not running (ppm vm start $1)"
    return 1
  fi
}

# The harness key, generated once. Test boxes are disposable and local, so it is unencrypted and
# lives beside the rest of ppm's cache rather than in ~/.ssh.
_vm_key() {
  [[ -f "$PPM_VM_KEY" ]] && return 0
  mkdir -p "$PPM_VM_STATE_DIR"
  ssh-keygen -t ed25519 -N '' -C ppm-vm -f "$PPM_VM_KEY" >/dev/null
  debug "generated $PPM_VM_KEY"
}

# ssh as a test user; a TTY only when we have one, so sudo can prompt interactively
_vm_ssh() {
  local name="$1" user="$2" ip tty=()
  shift 2
  ip=$(tart ip "$name" --wait 60 2>/dev/null) || { echo "no address for $name" >&2; return 1; }
  [[ -t 0 && -t 1 ]] && tty=(-t)
  ssh -i "$PPM_VM_KEY" ${tty[@]+"${tty[@]}"} "${PPM_VM_SSH_OPTS[@]}" "$user@$ip" "$@"
}

# First contact with a stock image, before the harness key exists. SSH_ASKPASS (OpenSSH >= 8.4)
# keeps the image's password out of the process table and needs no sshpass or expect.
_vm_ssh_admin() {
  local name="$1" ip askpass rc; shift
  ip=$(tart ip "$name" --wait 60 2>/dev/null) || { echo "no address for $name" >&2; return 1; }
  askpass=$(mktemp)
  printf '#!/bin/sh\necho %s\n' "$VM_ADMIN_PASSWORD" > "$askpass"
  chmod 700 "$askpass"
  SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    ssh "${PPM_VM_SSH_OPTS[@]}" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      "$VM_ADMIN_USER@$ip" "$@"
  rc=$?
  rm -f "$askpass"
  return $rc
}

_vm_wait_ssh() {
  local name="$1" as="${2:-admin}" i
  for i in $(seq 1 60); do
    if [[ "$as" == "admin" ]]; then
      _vm_ssh_admin "$name" true 2>/dev/null && return 0
    else
      _vm_ssh "$name" "$as" true 2>/dev/null && return 0
    fi
    sleep 5
  done
  echo "timed out waiting for ssh on $name"
  return 1
}

# Run a VM headless in the background. tart has no daemon: the process is the VM.
_vm_run() {
  local name="$1"
  shift
  mkdir -p "$PPM_VM_STATE_DIR"
  nohup tart run --no-graphics "$@" "$name" > "$PPM_VM_STATE_DIR/$name.log" 2>&1 &
  disown 2>/dev/null || true
}

# Shut the guest down from inside and wait for tart to agree.
#
# This is NOT `podman stop`, and the difference matters: `tart stop` can report the VM stopped
# while the guest's most recent writes are still buffered, and a clone taken then captures APFS's
# last consistent checkpoint instead -- silently losing the last minute of work. So we sync, ask
# the guest to shut itself down, and only force it as a last resort.
_vm_shutdown() {
  local name="$1" user="${2:-owner}" i
  _vm_is_running "$name" || return 0
  _vm_ssh "$name" "$user" "sync; echo $user | sudo -S -p '' shutdown -h now" >/dev/null 2>&1 ||
    _vm_ssh_admin "$name" "sync; echo $VM_ADMIN_PASSWORD | sudo -S -p '' shutdown -h now" >/dev/null 2>&1 || true
  for i in $(seq 1 60); do
    _vm_is_running "$name" || return 0
    sleep 2
  done
  echo "$name did not shut down; forcing it (recent writes may be lost)" >&2
  tart stop "$name" >/dev/null 2>&1 || true
  sleep 5
}

# Build the base image: pull, provision, reboot for /src, verify, shut down.
# The result is the pristine machine every box is cloned from -- no Homebrew, no CLT.
_vm_build() {
  local target="${1:-}"
  shift 2>/dev/null || true
  _vm_target "$target" || return 1

  local force=false
  [[ "${1:-}" == "--force" ]] && force=true
  local base="ppm-$target-base"

  if _vm_exists "$base"; then
    if ! $force; then
      echo "$base already exists (ppm vm build $target --force to rebuild it)"
      return 1
    fi
    _vm_shutdown "$base"
    tart delete "$base" >/dev/null
  fi

  _vm_key
  echo "Cloning $VM_IMAGE (a first pull downloads ~25GB)"
  tart clone "$VM_IMAGE" "$base" || return 1
  tart set "$base" --cpu "$VM_CPU" --memory "$VM_MEMORY"

  echo "Starting $base to provision it"
  _vm_run "$base"
  _vm_wait_ssh "$base" admin || return 1

  echo "Provisioning:"
  _vm_ssh_admin "$base" "cat > /tmp/ppm-provision.sh" < "$PPM_VM_DIR/$target/provision.sh" || return 1
  _vm_ssh_admin "$base" "echo $VM_ADMIN_PASSWORD | sudo -S -p '' env PPM_VM_PUBKEY='$(cat "$PPM_VM_KEY.pub")' bash /tmp/ppm-provision.sh" |
    sed 's/^/  /' || return 1

  # /src comes from synthetic.conf, which is only read at boot
  echo "Rebooting to realize /src"
  _vm_ssh_admin "$base" "echo $VM_ADMIN_PASSWORD | sudo -S -p '' shutdown -r now" >/dev/null 2>&1 || true
  sleep 20
  _vm_wait_ssh "$base" owner || return 1
  _vm_ssh "$base" owner '[[ -L /src ]] || { echo "/src is missing"; exit 1; }' || return 1

  _vm_shutdown "$base"
  echo "Built $base (ppm vm start $target)"
}

_vm_start() {
  local target="${1:-}"
  shift 2>/dev/null || true
  _vm_target "$target" || return 1

  local from="" sources="" extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="${2:?--from requires a snapshot name}"; shift ;;
      --sources) sources="${2:?--sources requires a comma-separated list of aliases (or 'none')}"; shift ;;
      --) shift; extra=("$@"); break ;;
      *) echo "Unknown option: $1"; return 1 ;;
    esac
    shift
  done

  local name="ppm-$target" image="ppm-$target-base"
  [[ -z "$from" ]] || image="ppm-$target-$from"

  if _vm_exists "$name"; then
    echo "$name already exists (ppm vm reset $target to recreate it)"
    return 1
  fi
  if ! _vm_exists "$image"; then
    if [[ -n "$from" ]]; then
      echo "No snapshot '$from' for $target (see: ppm vm list)"
      return 1
    fi
    _vm_build "$target" || return 1
  fi

  # Mount host sources in source-list order. tart has no equivalent of a container label, so the
  # list is recorded beside the VM for install and reset to read back.
  collect_repos
  local mounts=() aliases="" i alias host_dir
  if [[ "$sources" != "none" ]]; then
    for i in "${!GITSRC_NAMES[@]}"; do
      alias="${GITSRC_NAMES[$i]}"
      [[ -z "$sources" || ",$sources," == *",$alias,"* ]] || continue
      if [[ ! -d "$ANFS_SOURCES_HOME/$alias" ]]; then
        echo "Skipping $alias: not cloned on this host"
        continue
      fi
      host_dir=$(cd "$ANFS_SOURCES_HOME/$alias" && pwd -P)
      mounts+=("--dir=$alias:$host_dir:ro")
      aliases="$aliases $alias"
    done
  fi
  aliases="${aliases# }"

  # anfs/dev's own commands (vm install) need the anfs source mounted; warn but allow,
  # so the box is usable for general experimentation too.
  if [[ " $aliases " != *" anfs "* ]]; then
    echo "Note: anfs source not mounted; 'ppm vm install $target' won't work here" >&2
  fi

  tart clone "$image" "$name" || return 1
  mkdir -p "$PPM_VM_STATE_DIR"
  printf '%s\n' "$aliases" > "$PPM_VM_STATE_DIR/$name.sources"
  _vm_run "$name" ${mounts[@]+"${mounts[@]}"} ${extra[@]+"${extra[@]}"}
  echo "Started $name from $image with sources: ${aliases:-none}"
  if [[ ${#extra[@]} -gt 0 ]]; then echo "  extra tart args: ${extra[*]}"; fi
  echo "  address: $(tart ip "$name" --wait 90 2>/dev/null || echo 'still booting')"
}

_vm_shell() {
  local target="${1:-}" user="${2:-owner}"
  _vm_target "$target" && _vm_user "$user" && _vm_running "$target" || return 1
  echo "$user@ppm-$target (sudo password: $user)"
  _vm_ssh "ppm-$target" "$user" 'exec $SHELL -l'
}

_vm_install() {
  local target="${1:-}"
  shift 2>/dev/null || true

  local user=owner pushed=false args=()
  if [[ "${1:-}" == "owner" || "${1:-}" == "other" ]]; then
    user="$1"
    shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pushed) pushed=true ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  _vm_target "$target" && _vm_running "$target" || return 1
  local name="ppm-$target"

  if $pushed; then
    _vm_ssh "$name" "$user" "PPM_URL='$PPM_VM_INSTALLER_URL' PPM_ARGS='${args[*]-}' bash -s" <<'GUEST'
      if [[ -L ~/.local/share/anfs/sources/anfs ]]; then
        echo "~/.local/share/anfs/sources is linked to the working tree; ppm vm reset first"
        exit 1
      fi
      curl -fsSL "$PPM_URL" | bash -s -- $PPM_ARGS
GUEST
    return
  fi

  # Link the user's ppm data dirs to the mounted working tree; local-path sources are never pulled.
  #
  # The list is written to user.list, NOT the legacy sources.list: install.sh seeds an empty
  # user.list on a fresh box, and _user_sources_read prefers user.list whenever it exists, so a
  # sources.list would be shadowed and the whole run would test the pushed repos instead of the
  # mount. Note also that ssh re-parses the remote command line (podman exec passes argv
  # straight through), which is why the list travels as an env var rather than as $1.
  local sources
  sources=$(cat "$PPM_VM_STATE_DIR/$name.sources" 2>/dev/null || true)
  _vm_ssh "$name" "$user" "PPM_VM_SOURCES='$sources' bash -s" <<'GUEST' || return 1
set -euo pipefail
mkdir -p ~/.local/share/anfs/sources ~/.config/anfs
: > ~/.config/anfs/user.list.new
for alias in $PPM_VM_SOURCES; do
  target=~/.local/share/anfs/sources/$alias
  if [[ -e $target && ! -L $target ]]; then
    echo "$target is a clone (from --pushed); ppm vm reset first"
    exit 1
  fi
  ln -sfn "/src/$alias" "$target"
  printf "/src/%s  %s\n" "$alias" "$alias" >> ~/.config/anfs/user.list.new
done
rm -f ~/.config/anfs/sources.list
mv ~/.config/anfs/user.list.new ~/.config/anfs/user.list
GUEST

  # install.sh's _system_sudo primes the credential cache and then uses `sudo -n`; over ssh there
  # is no tty for it to prompt on, so the password is fed once here. The sudoers drop-in from
  # provisioning is what keeps that cache alive for the length of a cold run.
  _vm_ssh "$name" "$user" "PPM_ARGS='${args[*]-}' bash -s" <<GUEST
echo $user | sudo -S -p '' -v
bash /src/anfs/install.sh \$PPM_ARGS
GUEST
}

# podman commit keeps the container running; this cannot. The VM is shut down to be cloned, and
# the working box is then recreated *from the snapshot* rather than restarted -- a restarted
# original has been seen to come back without the writes the snapshot captured.
_vm_snapshot() {
  local target="${1:-}" snapshot="${2:-}"
  _vm_target "$target" || return 1
  if [[ ! "$snapshot" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
    echo "Usage: ppm vm snapshot <target> <name>  (lowercase letters, digits, . _ -)"
    return 1
  fi
  local name="ppm-$target"
  _vm_exists "$name" || { echo "$name does not exist"; return 1; }

  local was_running=false
  _vm_is_running "$name" && was_running=true
  _vm_shutdown "$name"

  tart delete "ppm-$target-$snapshot" >/dev/null 2>&1 || true   # may not exist yet
  tart clone "$name" "ppm-$target-$snapshot" || return 1
  echo "Saved ppm-$target-$snapshot (ppm vm reset $target $snapshot)"

  if $was_running; then
    tart delete "$name" >/dev/null
    _vm_reset_from "$target" "$snapshot"
  fi
}

_vm_reset() {
  local target="${1:-}" snapshot="${2:-}"
  _vm_target "$target" || return 1
  local name="ppm-$target"
  if _vm_exists "$name"; then
    _vm_shutdown "$name"
    tart delete "$name" >/dev/null
  fi
  _vm_reset_from "$target" "$snapshot"
}

# Recreate the box, reusing the source list it was started with
_vm_reset_from() {
  local target="$1" snapshot="${2:-}" sources="" opts=()
  sources=$(cat "$PPM_VM_STATE_DIR/ppm-$target.sources" 2>/dev/null || true)
  [[ -z "$snapshot" ]] || opts+=(--from "$snapshot")
  [[ -z "$sources" ]] || opts+=(--sources "${sources// /,}")
  _vm_start "$target" ${opts[@]+"${opts[@]}"}
}

_vm_stop() {
  _vm_shutdown "ppm-$1"
  echo "Stopped ppm-$1"
}

# rm <target>             the box itself
# rm <target> <snapshot>  one snapshot, since they are a few GB each and otherwise accumulate
# rm <target> --base      the box and the base image it is cloned from
_vm_rm() {
  local target="${1:-}" what="${2:-}"
  _vm_target "$target" || return 1

  if [[ -n "$what" && "$what" != "--base" ]]; then
    local snap="ppm-$target-$what"
    [[ "$what" != "base" ]] || { echo "Use --base to remove the base image"; return 1; }
    _vm_exists "$snap" || { echo "No snapshot '$what' for $target (see: ppm vm list)"; return 1; }
    _vm_shutdown "$snap"
    tart delete "$snap" >/dev/null && echo "Removed $snap"
    return
  fi

  _vm_shutdown "ppm-$target"
  if tart delete "ppm-$target" >/dev/null 2>&1; then
    echo "Removed ppm-$target"
  else
    echo "ppm-$target does not exist"
  fi
  rm -f "$PPM_VM_STATE_DIR/ppm-$target.sources"
  if [[ "$what" == "--base" ]] && tart delete "ppm-$target-base" >/dev/null 2>&1; then
    echo "Removed ppm-$target-base"
  fi
}

_vm_list() {
  local json
  json=$(tart list --format json 2>/dev/null || true)
  echo "VMs:"
  # grep finds nothing when no box has been built yet, and ppm runs under `set -e`
  yq -p json -r '.[] | select(.Source == "local") | .Name + "\t" + .State + "\t" + (.Size|tostring) + " GB"' <<<"$json" |
    { grep '^ppm-' || true; } | awk -F'\t' '{ printf "  %-28s %-9s %s\n", $1, $2, $3 }'
  echo "Images cached:"
  # The tag and the digest are the same pulled image: tart stores it by digest and the tag is a
  # symlink to it, so both are listed but only one copy is on disk.
  yq -p json -r '.[] | select(.Source == "OCI") | .Name' <<<"$json" | sed 's/^/  /'
}
