#!/usr/bin/env bash
# core/dev — adds `ppm container`: disposable Linux boxes for testing anfs installs
# Stowed to ~/.local/lib/ppm/ and sourced by ppm, so cmd_container() is the command `ppm container`
#
# The boxes are pcm services, the anfs repo's containers/anfs-test-<distro> definitions: pcm runs
# them (privileged, declared, so podman works inside), mounts every anfs source read-only at
# /src/<alias> (the anfs-sources mount set), and keeps snapshots of them. This command only adds
# what is about testing anfs: linking the mounted sources into a test user's anfs and running
# install.sh from the working tree. Everything else is pcm's own command, named here for
# convenience. They complement VMs rather than replace them: no systemd services, login sessions
# (chsh) or kernel features (NFS, KVM).
#
# The end-to-end round trip (packages/anfs/tests/roundtrip) builds the same boxes without pcm, so
# testing pcm never depends on pcm.

PPM_CONTAINER_INSTALLER_URL=https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh

cli_cmd container "container <command> <distro> [...]" "Disposable Linux boxes for testing anfs installs (pcm services)"

cmd_container() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  if [[ -n "$subcommand" && "$subcommand" != "help" ]] && ! command -v pcm >/dev/null 2>&1; then
    echo "ppm container needs pcm (ppm install core/anfs)"
    return 1
  fi

  case "$subcommand" in
    build)    _container_distro "${1:-}" && podman build -t "localhost/anfs-test-$1" "${@:2}" "$(pcm path "anfs-test-$1")" ;;
    start)    _container_distro "${1:-}" && pcm up "anfs-test-$1" ;;
    shell)    _container_distro "${1:-}" && _container_user "${2:-owner}" && pcm shell "anfs-test-$1" -u "${2:-owner}" ;;
    install)  _container_install "$@" ;;
    snapshot) _container_distro "${1:-}" && pcm snapshot "anfs-test-$1" ${2:+"$2"} ;;
    reset)    _container_distro "${1:-}" && pcm reset -y "anfs-test-$1" ${2:+"$2"} ;;
    stop)     _container_distro "${1:-}" && pcm down "anfs-test-$1" ;;
    rm)       _container_distro "${1:-}" && pcm remove -y "anfs-test-$1" ;;
    list)     _container_list ;;
    *)
      echo "Usage: ppm container <command> <distro> [...]"
      echo "  build <distro> [podman build args]   Build the box's image (start builds it when missing)"
      echo "  start <distro>                       Start it: pcm up anfs-test-<distro>"
      echo "  shell <distro> [owner|other]         Login shell as a test user"
      echo "  install <distro> [owner|other] [--pushed] [installer args]"
      echo "                                       Run install.sh from the working tree (--pushed: from GitHub)"
      echo "  snapshot <distro> [name]             Save the box (no name lists its snapshots)"
      echo "  reset <distro> [snapshot]            Recreate it from a snapshot, or from scratch"
      echo "  stop <distro> | rm <distro>          Stop it, or remove it and its snapshots"
      echo "  list                                 The boxes and their snapshots"
      echo ""
      echo "Distros: $(_container_distros)"
      echo "Users: owner (sudo, password 'owner'), other (no sudo)"
      echo "Sources are mounted read-only, so commands that write into a source (file claim) fail."
      [[ -z "$subcommand" || "$subcommand" == "help" ]] || exit 1
      ;;
  esac
}

_container_distros() {
  pcm list --names 2>/dev/null | sed -n 's/^anfs-test-//p' | sort -u | paste -sd ' ' -
}

_container_distro() {
  if [[ -z "${1:-}" ]] || ! pcm path "anfs-test-$1" >/dev/null 2>&1; then
    echo "Unknown distro '${1:-}'. Available: $(_container_distros)"
    return 1
  fi
}

_container_user() {
  case "${1:-}" in
    owner|other) return 0 ;;
    *) echo "Unknown user '${1:-}'. Test users: owner, other"; return 1 ;;
  esac
}

_container_install() {
  local distro="${1:-}"
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
  _container_distro "$distro" || return 1
  local box="anfs-test-$distro"

  if $pushed; then
    pcm exec "$box" -u "$user" -- bash -c '
      if [[ -L ~/.local/share/anfs/sources/core ]]; then
        echo "the anfs sources are linked to the working tree; ppm container reset '"$distro"' first"
        exit 1
      fi
      if command -v curl >/dev/null 2>&1; then curl -fsSL "$0"; else wget -qO- "$0"; fi | bash -s -- "$@"
    ' "$PPM_CONTAINER_INSTALLER_URL" ${args[@]+"${args[@]}"}
    return
  fi

  # Link the user's anfs sources to the mounted working tree, anfs last as in system.list (a
  # dependency resolves to the same or a lower-priority source). Local-path sources are never
  # pulled. They go in user.list *before* install.sh runs, which would otherwise clone anfs from
  # GitHub and test the pushed repo instead of the mount.
  pcm exec "$box" -u "$user" -- bash -c '
    mkdir -p ~/.local/share/anfs/sources ~/.config/anfs
    : > ~/.config/anfs/user.list.new
    for src in $(ls -d /src/* | grep -vx /src/core) /src/core; do
      [[ -d "$src" ]] || continue
      alias=$(basename "$src")
      target=~/.local/share/anfs/sources/$alias
      if [[ -e $target && ! -L $target ]]; then
        echo "$target is a clone (from --pushed); ppm container reset first"
        exit 1
      fi
      ln -sfn "$src" "$target"
      printf "%s  %s\n" "$src" "$alias" >> ~/.config/anfs/user.list.new
    done
    mv ~/.config/anfs/user.list.new ~/.config/anfs/user.list
  ' || return 1

  pcm exec "$box" -u "$user" -- bash /src/core/install.sh ${args[@]+"${args[@]}"}
}

_container_list() {
  local d
  for d in $(_container_distros); do
    printf 'anfs-test-%s  %s\n' "$d" "$(pcm ps "anfs-test-$d" --format '{{.Status}}' 2>/dev/null | head -n1)"
    pcm snapshot "anfs-test-$d" 2>/dev/null | sed 's/^/  snapshot /'
  done
}
