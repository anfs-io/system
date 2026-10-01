#!/usr/bin/env bash
# pcm library: working inside a service and saving its state — exec, shell, snapshot, reset
# Sourced by ~/.local/bin/pcm; defines functions only.
#
# A snapshot is what a service is right now: every compose service's container committed to an
# image, and a copy of its data (${PCM_VOLUMES_HOME}/<name>/). `pcm reset <service> <snapshot>`
# brings it back — the data copied in again, the containers recreated from the snapshot's images
# — and the service keeps running from that snapshot until a plain `pcm reset <service>`, which
# recreates it from its definition with fresh data. A dev database before a risky migration, or a
# test box with Homebrew already installed, are both the same thing:
#
#   $PCM_STATE_HOME/snapshots/<name>/<snapshot>   "<compose-service> <image>" lines
#   $PCM_STATE_HOME/snapshots/<name>/active       the snapshot it runs from, if any
#   $PCM_DATA_HOME/snapshots/<name>/<snapshot>/   the data, as it was
# Snapshot images are localhost/pcm-snapshot/<name>-<compose-service>:<snapshot>, labelled
# io.pcm.snapshot=<name>/<snapshot> so remove and implode find them.

PCM_LABEL_SNAPSHOT=io.pcm.snapshot

_snapshot_dir() { echo "$PCM_STATE_HOME/snapshots/$(svc_name "$1")"; }
_snapshot_data() { echo "$PCM_DATA_HOME/snapshots/$(svc_name "$1")/$2"; }

# The image the active snapshot saved for compose service $2 of service $1; false when none
snapshot_active_image() {
  local dir active image
  dir=$(_snapshot_dir "$1")
  [[ -f "$dir/active" ]] || return 1
  active=$(cat "$dir/active")
  image=$(awk -v k="$2" '$1 == k { print $2; exit }' "$dir/$active" 2>/dev/null)
  [[ -n "$image" ]] && echo "$image"
}

# The container of compose service $2 (or the first one) of service $1
_box_container() {
  local filter=()
  [[ -n "${2:-}" ]] && filter=(--filter "label=com.docker.compose.service=$2")
  podman ps --filter "label=$PCM_LABEL_NAME=$(svc_name "$1")" ${filter[@]+"${filter[@]}"} \
    --format '{{.Names}}' | head -n1
}

# Copy a data dir, keeping ownership: rootless podman's subuid-owned files need podman unshare
_copy_data() {
  local from="$1" to="$2"
  mkdir -p "$(dirname "$to")"
  if [[ "$OSTYPE" != darwin* ]]; then
    podman unshare cp -a "$from" "$to"
  else
    cp -a "$from" "$to"
  fi
}

# `pcm exec <service> [-u USER] [-s COMPOSE-SERVICE] [--] <command>...`
cmd_exec() {
  local id user="" csvc="" ctr
  id=$(canon "${1:-}") || { echo "Usage: pcm exec <service> [-u user] [-s compose-service] [--] <command>..." >&2; return 1; }
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--user) user="${2:?--user needs a name}"; shift ;;
      -s|--service) csvc="${2:?--service needs a compose service}"; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
    shift
  done
  [[ $# -gt 0 ]] || { echo "pcm: exec needs a command" >&2; return 1; }
  ctr=$(_box_container "$id" "$csvc")
  [[ -n "$ctr" ]] || { echo "pcm: $id is not running (pcm up $(svc_name "$id"))" >&2; return 1; }
  local tty=() as=()
  [[ -t 0 && -t 1 ]] && tty=(-t)
  [[ -n "$user" ]] && as=(-u "$user" -w "$(_box_home "$ctr" "$user")")
  podman exec -i ${tty[@]+"${tty[@]}"} -e TERM="${TERM:-xterm-256color}" ${as[@]+"${as[@]}"} "$ctr" "$@"
}

_box_home() {
  podman exec "$1" getent passwd "$2" 2>/dev/null | cut -d: -f6 | grep . || echo /
}

# `pcm shell <service> [-u USER] [-s COMPOSE-SERVICE]`: a login shell, the user's own
cmd_shell() {
  local id user="" csvc="" ctr shell
  id=$(canon "${1:-}") || { echo "Usage: pcm shell <service> [-u user] [-s compose-service]" >&2; return 1; }
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--user) user="${2:?--user needs a name}"; shift ;;
      -s|--service) csvc="${2:?--service needs a compose service}"; shift ;;
      *) echo "pcm: shell: unknown option '$1'" >&2; return 1 ;;
    esac
    shift
  done
  ctr=$(_box_container "$id" "$csvc")
  [[ -n "$ctr" ]] || { echo "pcm: $id is not running (pcm up $(svc_name "$id"))" >&2; return 1; }
  shell=$(podman exec "$ctr" getent passwd "${user:-root}" 2>/dev/null | cut -d: -f7)
  local args=()
  [[ -n "$user" ]] && args+=(-u "$user")
  [[ -n "$csvc" ]] && args+=(-s "$csvc")
  cmd_exec "$id" ${args[@]+"${args[@]}"} -- "${shell:-/bin/sh}" -l
}

# `pcm snapshot <service> [name]`: save one; with no name, list them (* marks the active one)
cmd_snapshot() {
  local id snap dir key ctr image
  id=$(canon "${1:-}") || { echo "Usage: pcm snapshot <service> [name]" >&2; return 1; }
  snap="${2:-}"
  dir=$(_snapshot_dir "$id")

  if [[ -z "$snap" ]]; then
    local active="" f
    [[ -f "$dir/active" ]] && active=$(cat "$dir/active")
    for f in "$dir"/*; do
      [[ -f "$f" && "$(basename "$f")" != active ]] || continue
      printf '%s %s\n' "$([[ "$(basename "$f")" == "$active" ]] && echo '*' || echo ' ')" "$(basename "$f")"
    done
    return 0
  fi
  [[ "$snap" =~ ^[a-z0-9][a-z0-9_.-]*$ && "$snap" != active ]] ||
    { echo "pcm: snapshot names are lowercase letters, digits, . _ - (and not 'active')" >&2; return 1; }
  [[ -n "$(project_containers "$id" -a)" ]] || { echo "pcm: $id has no containers to snapshot (pcm up $(svc_name "$id"))" >&2; return 1; }

  mkdir -p "$dir"
  : > "$dir/$snap.new"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    ctr=$(podman ps -a --filter "label=$PCM_LABEL_NAME=$(svc_name "$id")" \
      --filter "label=com.docker.compose.service=$key" --format '{{.Names}}' | head -n1)
    [[ -n "$ctr" ]] || continue
    image="localhost/pcm-snapshot/$(svc_name "$id")-$key:$snap"
    echo "pcm: committing $ctr -> $image" >&2
    podman commit -q --change "LABEL $PCM_LABEL_SNAPSHOT=$(svc_name "$id")/$snap" "$ctr" "$image" >/dev/null ||
      { rm -f "$dir/$snap.new"; echo "pcm: commit of $ctr failed" >&2; return 1; }
    echo "$key $image" >> "$dir/$snap.new"
  done < <(yq eval '.services | keys | .[]' "$(compose_file "$id")")
  mv "$dir/$snap.new" "$dir/$snap"

  local data="$PCM_VOLUMES_HOME/$(svc_name "$id")" saved
  saved=$(_snapshot_data "$id" "$snap")
  remove_data_dir "$saved"
  if [[ -d "$data" ]]; then
    echo "pcm: saving $(tilde "$data")" >&2
    _copy_data "$data" "$saved"
  fi
  echo "Saved snapshot $snap of $id"
}

# `pcm reset [-y] <service> [snapshot]`: recreate the service from a snapshot, or (with none)
# from its definition with fresh data. The data it has now is replaced, so it asks unless -y.
cmd_reset() {
  local yes=false arg id="" snap=""
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) yes=true ;;
      -*) echo "pcm: reset: unknown option '$arg'" >&2; return 1 ;;
      *) if [[ -z "$id" ]]; then id="$arg"; else snap="$arg"; fi ;;
    esac
  done
  id=$(canon "$id") || { echo "Usage: pcm reset [-y] <service> [snapshot]" >&2; return 1; }
  local dir data
  dir=$(_snapshot_dir "$id")
  data="$PCM_VOLUMES_HOME/$(svc_name "$id")"
  if [[ -n "$snap" && ! -f "$dir/$snap" ]]; then
    echo "pcm: no snapshot '$snap' of $id (pcm snapshot $(svc_name "$id"))" >&2
    return 1
  fi
  if ! $yes; then
    [[ -t 0 ]] || { echo "pcm: reset replaces $id's data; pass -y to confirm without a terminal" >&2; return 1; }
    local answer
    read -r -p "Reset $id to ${snap:-its definition, with fresh data}? [y/N] " answer
    [[ "$answer" == [yY]* ]] || { echo "pcm: nothing reset" >&2; return 1; }
  fi

  if [[ -n "$(project_containers "$id" -a)" ]]; then
    compose_flags "$id" || return 1
    compose_run "$id" "${FLAGS[@]}" down >&2 || { echo "pcm: could not stop $id" >&2; return 1; }
  fi
  remove_data_dir "$data"
  if [[ -n "$snap" ]]; then
    [[ -d "$(_snapshot_data "$id" "$snap")" ]] && _copy_data "$(_snapshot_data "$id" "$snap")" "$data"
    echo "$snap" > "$dir/active"
  else
    rm -f "$dir/active"
  fi
  cmd_up "$id"
}

# Delete service $1's snapshots: images, data and records (remove and implode)
snapshot_forget() {
  local name images
  name=$(svc_name "$1")
  images=$(podman images --filter "label=$PCM_LABEL_SNAPSHOT" --format '{{.Repository}}:{{.Tag}} {{.Labels}}' 2>/dev/null |
    awk -v n="$PCM_LABEL_SNAPSHOT:$name/" 'index($0, n) { print $1 }') || true
  [[ -z "$images" ]] || podman rmi -f $images >/dev/null 2>&1 || true
  remove_data_dir "$PCM_DATA_HOME/snapshots/$name"
  rm -rf "${PCM_STATE_HOME:?}/snapshots/$name"
}
