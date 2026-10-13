#!/usr/bin/env bash
# core/dev — adds `ppm vm`: disposable macOS VMs for testing anfs installs on Apple silicon
# Stowed to ~/.local/lib/ppm/ and sourced by ppm: the `ppm vm` commands are declared below
#
# The sibling of `ppm container`, with the same subcommands and the same contract: two test users
# (owner, an admin with the password 'owner'; other, no admin), and the host's sources mounted
# read-only at /src/<alias>, so a box tests the working tree. What a VM adds over a container is
# everything a container cannot reach: login shells (rc files and chsh are real), launchd, and
# macOS itself, where the most fragile paths live (the Xcode CLT, the Homebrew prefix, casks).
#
# The boxes are pmm machines, as the containers are pcm services: target <t> is the anfs repo's
# machines/anfs-test-<t>, from the image of the same name (tart backend). Every command but
# install is pmm's own. This command only adds what is about testing
# anfs: linking the mounted sources into a test user's anfs and running install.sh from them. A macOS guest gets no nested virtualization, so pcm's podman
# machine cannot start in it.

PPM_VM_INSTALLER_URL=https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh

cli_group vm "Disposable macOS VMs (pmm machines, tart) for testing anfs installs.
Users: owner (admin, password 'owner'), other (no admin). Sources are
mounted read-only. Apple allows two macOS guests running at once."
cli_cmd "vm list" "Running boxes" --alias ls
cli_cmd "vm build" "Build the box's image (pmm image build; a first pull is ~25GB)" \
  --opt "-f --force: Rebuild" --arg "target"
cli_cmd "vm up" "Start it: pmm up anfs-test-<target>; options go to pmm up (--share P)" \
  --alias start --passthrough --arg "target"
cli_cmd "vm down" "Shut it down" --alias stop --arg "target"
cli_cmd "vm shell" "Login shell as a test user (owner or other)" --arg "target" --arg "[user]"
cli_cmd "vm install" "Run install.sh from the mounted sources: [owner|other] [--pushed] [installer args]
(--pushed: from GitHub)" --passthrough --arg "target" --arg "[word...]"
cli_cmd "vm snapshot" "Save the box (no name lists its snapshots)" --arg "target" --arg "[snapshot]"
cli_cmd "vm reset" "Recreate it from a snapshot, or from its image's current build" --arg "target" --arg "[snapshot]"
cli_cmd "vm remove" "Remove it and its snapshots (the image's build stays: pmm image remove)" --alias rm --arg "target"
cli_cmd "vm ip" "The box's address" --arg "target"

_vm_pmm() {
  command -v pmm >/dev/null 2>&1 ||
    { echo "ppm vm needs pmm (ppm install core/anfs)" >&2; exit 1; }
}
cmd_vm_list()     { _vm_pmm; pmm ps; }
cmd_vm_build() {
  _vm_pmm
  _vm_target "$1" || return 1
  if ${CLI_OPT[force]:-false}; then pmm image build -f "anfs-test-$1"; else pmm image build "anfs-test-$1"; fi
}
cmd_vm_up()       { _vm_pmm; _vm_target "$1" && pmm up "${@:2}" "anfs-test-$1"; }
cmd_vm_down()     { _vm_pmm; _vm_target "$1" && pmm down "anfs-test-$1"; }
cmd_vm_shell()    { _vm_pmm; _vm_target "$1" && _vm_user "${2:-owner}" && pmm shell "anfs-test-$1" -u "${2:-owner}"; }
cmd_vm_install()  { _vm_pmm; _vm_install "$@"; }
cmd_vm_snapshot() {
  _vm_pmm
  _vm_target "$1" || return 1
  if [[ -n "${2:-}" ]]; then pmm snapshot create "anfs-test-$1" "$2"; else pmm snapshot list "anfs-test-$1"; fi
}
cmd_vm_reset()    { _vm_pmm; _vm_target "$1" && pmm reset -y "anfs-test-$1" ${2:+"$2"}; }
cmd_vm_remove()   { _vm_pmm; _vm_target "$1" && pmm remove -y "anfs-test-$1"; }
# A tool reads another's list with --json: the address is pmm list's, null while the box is down
cmd_vm_ip() {
  _vm_pmm
  _vm_target "$1" || return 1
  local ip
  ip=$(N="anfs-test-$1" pmm list --json | N="anfs-test-$1" yq -p json -r '.[] | select(.name == strenv(N) and .state == "running") | .address')
  [[ -n "$ip" ]] || { echo "anfs-test-$1 is not running (ppm vm up $1)" >&2; return 1; }
  echo "$ip"
}

# What cli.sh asks for on a tab press: the boxes, from the definitions' names
complete_target() {
  local d
  for d in "$ANFS_SOURCES_HOME"/*/machines/anfs-test-*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    printf '%s\n' "${d##*/anfs-test-}"
  done | sort -u
}

_vm_targets() {
  pmm list --json 2>/dev/null | yq -p json -r '.[].name' 2>/dev/null | sed -n 's/^anfs-test-//p' | sort -u | paste -sd ' ' -
}

_vm_target() {
  if [[ -z "${1:-}" ]] || ! pmm path "anfs-test-$1" >/dev/null 2>&1; then
    echo "Unknown target '${1:-}'. Available: $(_vm_targets)"
    return 1
  fi
}

_vm_user() {
  case "${1:-}" in
    owner|other) return 0 ;;
    *) echo "Unknown user '${1:-}'. Test users: owner, other"; return 1 ;;
  esac
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
  _vm_target "$target" || return 1
  local box="anfs-test-$target"

  # install.sh's _system_sudo primes the credential cache and then uses `sudo -n`; over ssh there
  # is no tty for it to prompt on, so owner's password is fed once first (the image relaxes sudo's
  # timestamp so the cache lasts a cold run). ssh re-parses the command line, so values travel in
  # the script, not as arguments.
  local prime=""
  [[ "$user" == owner ]] && prime="echo owner | sudo -S -p '' -v"

  if $pushed; then
    pmm shell "$box" -u "$user" -- bash -s <<GUEST
if [[ -L ~/.local/share/anfs/sources/core ]]; then
  echo "the anfs sources are linked to /src; ppm vm reset $target first"
  exit 1
fi
$prime
curl -fsSL '$PPM_VM_INSTALLER_URL' | bash -s -- ${args[*]-}
GUEST
    return
  fi

  # Link the user's anfs sources to the mounted ones, anfs last as in system.list (a dependency
  # resolves to the same or a lower-priority source), before install.sh runs: it would otherwise
  # clone anfs from GitHub and test the pushed repo instead of the mount.
  pmm shell "$box" -u "$user" -- bash -s <<GUEST
set -euo pipefail
mkdir -p ~/.local/share/anfs/sources ~/.config/anfs
: > ~/.config/anfs/user.list.new
for src in \$(ls -d /src/* | grep -vx /src/core) /src/core; do
  [[ -d "\$src" ]] || continue
  alias=\$(basename "\$src")
  dest=~/.local/share/anfs/sources/\$alias
  if [[ -e \$dest && ! -L \$dest ]]; then
    echo "\$dest is a clone (from --pushed); ppm vm reset $target first"
    exit 1
  fi
  ln -sfn "\$src" "\$dest"
  printf "%s  %s\n" "\$src" "\$alias" >> ~/.config/anfs/user.list.new
done
mv ~/.config/anfs/user.list.new ~/.config/anfs/user.list
$prime
bash /src/core/install.sh ${args[*]-}
GUEST
}
