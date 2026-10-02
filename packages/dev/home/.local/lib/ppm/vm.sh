#!/usr/bin/env bash
# anfs/dev — adds `ppm vm`: disposable macOS VMs for testing anfs installs on Apple silicon
# Stowed to ~/.local/lib/ppm/ and sourced by ppm, so cmd_vm() is the command `ppm vm`
#
# The sibling of `ppm container`, with the same subcommands and the same contract: two test users
# (owner, an admin with the password 'owner'; other, no admin), and the host's sources mounted
# read-only at /src/<alias>, so a box tests the working tree. What a VM adds over a container is
# everything a container cannot reach: login shells (rc files and chsh are real), launchd, and
# macOS itself, where the most fragile paths live (the Xcode CLT, the Homebrew prefix, casks).
#
# The boxes are pim images, as the containers are pcm services: target <t> is the anfs repo's
# images/anfs-test-<t> (tart backend), and every command but install is pim's own. This command
# only adds what is about testing anfs: linking the mounted sources into a test user's anfs and
# running install.sh from them. A macOS guest gets no nested virtualization, so pcm's podman
# machine cannot start in it.

PPM_VM_INSTALLER_URL=https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh

cli_cmd vm "vm <command> <target> [...]" "Disposable macOS VMs (pim images, tart) for testing anfs installs"

cmd_vm() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  if [[ -n "$subcommand" && "$subcommand" != "help" ]] && ! command -v pim >/dev/null 2>&1; then
    echo "ppm vm needs pim (ppm install anfs/anfs)"
    return 1
  fi

  case "$subcommand" in
    build)    _vm_target "${1:-}" && pim build ${2:+-f} "anfs-test-$1" ;;
    start)    _vm_target "${1:-}" && pim up "${@:2}" "anfs-test-$1" ;;
    shell)    _vm_target "${1:-}" && _vm_user "${2:-owner}" && pim shell "anfs-test-$1" -u "${2:-owner}" ;;
    install)  _vm_install "$@" ;;
    snapshot) _vm_target "${1:-}" && pim snapshot "anfs-test-$1" ${2:+"$2"} ;;
    reset)    _vm_target "${1:-}" && pim reset -y "anfs-test-$1" ${2:+"$2"} ;;
    stop)     _vm_target "${1:-}" && pim down "anfs-test-$1" ;;
    rm)       _vm_target "${1:-}" && pim rm -y "anfs-test-$1" ;;
    list)     pim ps ;;
    ip)       _vm_target "${1:-}" && tart ip "pim-anfs-test-$1" --wait 5 ;;
    *)
      echo "Usage: ppm vm <command> <target> [...]"
      echo "  build <target> [--force]              Build the box's image (pim build; a first pull is ~25GB)"
      echo "  start <target> [--fresh] [--share P]  Start it: pim up anfs-test-<target>"
      echo "  shell <target> [owner|other]          Login shell as a test user"
      echo "  install <target> [owner|other] [--pushed] [installer args]"
      echo "                                        Run install.sh from the mounted sources (--pushed: from GitHub)"
      echo "  snapshot <target> [name]              Save the box (no name lists its snapshots)"
      echo "  reset <target> [snapshot]             Recreate it from a snapshot, or from its build"
      echo "  stop <target> | rm <target>           Shut it down, or remove it, its snapshots and builds"
      echo "  list | ip <target>                    Running boxes, or a box's address"
      echo ""
      echo "Targets: $(_vm_targets)"
      echo "Users: owner (admin, password 'owner'), other (no admin)"
      echo "Sources are mounted read-only, so commands that write into a source (file claim) fail."
      echo "Apple allows two macOS guests running at once, per host."
      [[ -z "$subcommand" || "$subcommand" == "help" ]] || return 1
      ;;
  esac
}

_vm_targets() {
  pim list --names 2>/dev/null | grep -v / | sed -n 's/^anfs-test-//p' | sort -u | paste -sd ' ' -
}

_vm_target() {
  if [[ -z "${1:-}" ]] || ! pim path "anfs-test-$1" >/dev/null 2>&1; then
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
    pim shell "$box" -u "$user" -- bash -s <<GUEST
if [[ -L ~/.local/share/anfs/sources/anfs ]]; then
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
  pim shell "$box" -u "$user" -- bash -s <<GUEST
set -euo pipefail
mkdir -p ~/.local/share/anfs/sources ~/.config/anfs
: > ~/.config/anfs/user.list.new
for src in \$(ls -d /src/* | grep -vx /src/anfs) /src/anfs; do
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
bash /src/anfs/install.sh ${args[*]-}
GUEST
}
