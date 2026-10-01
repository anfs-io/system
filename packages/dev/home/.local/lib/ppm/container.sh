#!/usr/bin/env bash
# ppm/dev — adds `ppm container`: disposable Linux containers for testing ppm
# Stowed to ~/.local/lib/ppm/ and sourced by ppm, so container() becomes a ppm command
#
# Containers test the working tree: host source repos are mounted read-only at /src/<alias> and
# each test user's ppm data dirs link to them. They complement VMs rather than replace them:
# no systemd services, login sessions (chsh) or kernel features (NFS, KVM).

# containers/<distro>/Containerfile lives in the ppm/dev package, found through the stow link to this file
PPM_CONTAINER_DIR="$(cd "$(_resolve_path "${BASH_SOURCE[0]}")/../../../.." && pwd)/containers"
PPM_CONTAINER_IMAGE=localhost/ppm-test
PPM_CONTAINER_INSTALLER_URL=https://raw.githubusercontent.com/maxcole/ppm/refs/heads/main/install.sh

container() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  if [[ -n "$subcommand" && "$subcommand" != "help" ]] && ! command -v podman >/dev/null 2>&1; then
    echo "ppm container needs podman (ppm install podman)"
    return 1
  fi

  case "$subcommand" in
    build)    _container_build "$@" ;;
    start)    _container_start "$@" ;;
    shell)    _container_shell "$@" ;;
    install)  _container_install "$@" ;;
    snapshot) _container_snapshot "$@" ;;
    reset)    _container_reset "$@" ;;
    stop)     _container_distro "${1:-}" && podman stop "ppm-$1" >/dev/null && echo "Stopped ppm-$1" ;;
    rm)       _container_distro "${1:-}" && podman rm -f "ppm-$1" >/dev/null && echo "Removed ppm-$1" ;;
    list)     _container_list ;;
    *)
      echo "Usage: ppm container <command> <distro> [...]"
      echo "  build <distro> [podman build args]            Build the standard image"
      echo "  start <distro> [--from SNAPSHOT] [--sources a,b|none] [-- podman-run-args]"
      echo "                                                Start ppm-<distro>; host sources mounted ro at /src"
      echo "                                                (--sources none for a clean box; -- passes extra"
      echo "                                                 podman run args, e.g. -- -p 8080:8080 -v ~/s:/s)"
      echo "  shell <distro> [owner|other]                  Login shell as a test user"
      echo "  install <distro> [owner|other] [--pushed] [installer args]"
      echo "                                                Run install.sh from the working tree (--pushed: from GitHub)"
      echo "  snapshot <distro> <name>                      Save the container as a snapshot image"
      echo "  reset <distro> [snapshot]                     Recreate from the base image or a snapshot"
      echo "  stop <distro> | rm <distro>                   Stop or remove the container"
      echo "  list                                          Containers and images"
      echo ""
      echo "Distros: $(_container_distros)"
      echo "Users: owner (sudo, password 'owner'), other (no sudo)"
      echo "Host repos are mounted read-only, so commands that write into a repo (file claim) fail."
      echo "Containers don't replace VMs: no systemd services, login sessions or kernel features."
      [[ -z "$subcommand" || "$subcommand" == "help" ]] || exit 1
      ;;
  esac
}

_container_distros() {
  local dir names=""
  for dir in "$PPM_CONTAINER_DIR"/*/; do
    [[ -f "$dir/Containerfile" ]] && names="$names $(basename "$dir")"
  done
  echo "${names# }"
}

_container_distro() {
  local distro="${1:-}"
  if [[ -z "$distro" || ! -f "$PPM_CONTAINER_DIR/$distro/Containerfile" ]]; then
    echo "Unknown distro '${distro}'. Available: $(_container_distros)"
    return 1
  fi
}

_container_user() {
  case "${1:-}" in
    owner|other) return 0 ;;
    *) echo "Unknown user '${1:-}'. Test users: owner, other"; return 1 ;;
  esac
}

_container_running() {
  if [[ "$(podman inspect -f '{{.State.Running}}' "ppm-$1" 2>/dev/null)" != "true" ]]; then
    echo "ppm-$1 is not running (ppm container start $1)"
    return 1
  fi
}

# podman exec as a test user; a TTY only when we have one, so sudo can prompt interactively
_container_exec() {
  local distro="$1" user="$2"
  shift 2
  local tty=()
  [[ -t 0 && -t 1 ]] && tty=(-t)
  podman exec -i ${tty[@]+"${tty[@]}"} -e TERM="${PPM_CONTAINER_TERM:-xterm-256color}" \
    -u "$user" -w "/home/$user" "ppm-$distro" "$@"
}

_container_build() {
  local distro="${1:-}"
  shift 2>/dev/null || true
  _container_distro "$distro" || return 1
  podman build -t "$PPM_CONTAINER_IMAGE:$distro" "$@" "$PPM_CONTAINER_DIR/$distro"
}

_container_start() {
  local distro="${1:-}"
  shift 2>/dev/null || true
  _container_distro "$distro" || return 1

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

  local name="ppm-$distro" image="$PPM_CONTAINER_IMAGE:$distro"
  [[ -z "$from" ]] || image="$image-$from"

  if podman container exists "$name"; then
    echo "$name already exists (ppm container reset $distro to recreate it)"
    return 1
  fi
  if ! podman image exists "$image"; then
    if [[ -n "$from" ]]; then
      echo "No snapshot '$from' for $distro (see: ppm container list)"
      return 1
    fi
    _container_build "$distro"
  fi

  # Mount host sources in source-list order; the label records the order for install and reset.
  # --sources none mounts nothing (a clean box for general use).
  collect_repos
  local mounts=() aliases="" i alias host_dir
  if [[ "$sources" != "none" ]]; then
    for i in "${!REPO_NAMES[@]}"; do
      alias="${REPO_NAMES[$i]}"
      [[ -z "$sources" || ",$sources," == *",$alias,"* ]] || continue
      if [[ ! -d "$PPM_DATA_HOME/$alias" ]]; then
        echo "Skipping $alias: not cloned on this host"
        continue
      fi
      host_dir=$(cd "$PPM_DATA_HOME/$alias" && pwd -P)
      mounts+=(-v "$host_dir:/src/$alias:ro")
      aliases="$aliases $alias"
    done
  fi
  aliases="${aliases# }"

  # ppm/dev's own commands (container install) need the ppm source mounted; warn but allow,
  # so the box is usable for general experimentation too.
  if [[ " $aliases " != *" ppm "* ]]; then
    echo "Note: ppm source not mounted; 'ppm container install $distro' won't work here" >&2
  fi

  podman run -d --name "$name" --hostname "$distro" --label "ppm.sources=$aliases" \
    ${mounts[@]+"${mounts[@]}"} ${extra[@]+"${extra[@]}"} "$image" >/dev/null
  echo "Started $name from $image with sources: ${aliases:-none}"
  [[ ${#extra[@]} -gt 0 ]] && echo "  extra podman args: ${extra[*]}"
}

_container_shell() {
  local distro="${1:-}" user="${2:-owner}"
  _container_distro "$distro" && _container_user "$user" && _container_running "$distro" || return 1

  local login_shell
  login_shell=$(podman exec "ppm-$distro" getent passwd "$user" | cut -d: -f7)
  _container_exec "$distro" "$user" "${login_shell:-/bin/bash}" -l
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

  _container_distro "$distro" && _container_running "$distro" || return 1

  if $pushed; then
    _container_exec "$distro" "$user" bash -c '
      if [[ -L ~/.local/share/ppm/ppm ]]; then
        echo "~/.local/share/ppm is linked to the working tree; ppm container reset '"$distro"' first"
        exit 1
      fi
      if command -v curl >/dev/null 2>&1; then curl -fsSL "$0"; else wget -qO- "$0"; fi | bash -s -- "$@"
    ' "$PPM_CONTAINER_INSTALLER_URL" ${args[@]+"${args[@]}"}
    return
  fi

  # Link the user's ppm data dirs to the mounted working tree; local-path sources are never pulled.
  #
  # The list goes in user.list, NOT the legacy sources.list: install.sh seeds an empty user.list on
  # a fresh box, and _user_sources_read prefers user.list whenever it exists, so a sources.list
  # would be shadowed and the whole run would test the pushed repos rather than the mount.
  local sources
  sources=$(podman inspect -f '{{index .Config.Labels "ppm.sources"}}' "ppm-$distro")
  _container_exec "$distro" "$user" bash -c '
    mkdir -p ~/.local/share/ppm ~/.config/ppm
    : > ~/.config/ppm/user.list.new
    for alias in $0; do
      target=~/.local/share/ppm/$alias
      if [[ -e $target && ! -L $target ]]; then
        echo "$target is a clone (from --pushed); ppm container reset first"
        exit 1
      fi
      ln -sfn "/src/$alias" "$target"
      printf "/src/%s  %s\n" "$alias" "$alias" >> ~/.config/ppm/user.list.new
    done
    rm -f ~/.config/ppm/sources.list
    mv ~/.config/ppm/user.list.new ~/.config/ppm/user.list
  ' "$sources" || return 1

  _container_exec "$distro" "$user" bash /src/ppm/install.sh ${args[@]+"${args[@]}"}
}

_container_snapshot() {
  local distro="${1:-}" snapshot="${2:-}"
  _container_distro "$distro" || return 1
  if [[ ! "$snapshot" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; then
    echo "Usage: ppm container snapshot <distro> <name>  (lowercase letters, digits, . _ -)"
    return 1
  fi
  podman container exists "ppm-$distro" || { echo "ppm-$distro does not exist"; return 1; }
  podman commit -q "ppm-$distro" "$PPM_CONTAINER_IMAGE:$distro-$snapshot" >/dev/null
  echo "Saved $PPM_CONTAINER_IMAGE:$distro-$snapshot (ppm container reset $distro $snapshot)"
}

_container_reset() {
  local distro="${1:-}" snapshot="${2:-}"
  _container_distro "$distro" || return 1

  local sources="" opts=()
  if podman container exists "ppm-$distro"; then
    sources=$(podman inspect -f '{{index .Config.Labels "ppm.sources"}}' "ppm-$distro")
    podman rm -f "ppm-$distro" >/dev/null
  fi
  [[ -z "$snapshot" ]] || opts+=(--from "$snapshot")
  [[ -z "$sources" ]] || opts+=(--sources "${sources// /,}")
  _container_start "$distro" ${opts[@]+"${opts[@]}"}
}

_container_list() {
  echo "Containers:"
  podman ps -a --filter 'name=^ppm-' --format '  {{.Names}}  {{.Status}}  {{.Image}}'
  echo "Images:"
  podman images "$PPM_CONTAINER_IMAGE" --format '  {{.Repository}}:{{.Tag}}  {{.CreatedSince}}'
}
