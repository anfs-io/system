#!/usr/bin/env bash
# pcm library: container sources and service resolution; the list, path and install commands
# Sourced by ~/.local/bin/pcm; defines functions only.

# --- sources and service resolution -------------------------------------------
# Inside pcm a service is its id, `source/name`. The name alone is its runtime identity:
# compose project, ${PCM_VOLUMES_HOME}/<name>/, the PCM_<NAME>_* provisioned env.

SRC_NAMES=()
SRC_DIRS=()

# Load the sources in priority order into SRC_NAMES and SRC_DIRS (each dir holds <name>/)
load_sources() {
  local i name
  SRC_NAMES=("$PCM_LOCAL_SOURCE")
  SRC_DIRS=("$PCM_CONTAINERS_HOME")
  gitsrc_collect
  for i in ${GITSRC_NAMES[@]+"${!GITSRC_NAMES[@]}"}; do
    name="${GITSRC_NAMES[$i]}"
    if [[ "$name" == "$PCM_LOCAL_SOURCE" ]]; then
      echo "pcm: ignoring source alias '$name': reserved for $PCM_CONTAINERS_HOME" >&2
      continue
    fi
    [[ -d "$(gitsrc_dir "$name")/containers" ]] || continue
    SRC_NAMES+=("$name")
    SRC_DIRS+=("$(gitsrc_dir "$name")/containers")
  done
}

# Containers dir of source $1
source_dir() {
  local i
  for i in "${!SRC_NAMES[@]}"; do
    [[ "${SRC_NAMES[$i]}" == "$1" ]] && { echo "${SRC_DIRS[$i]}"; return 0; }
  done
  return 1
}

svc_name() { echo "${1#*/}"; }
svc_src()  { echo "${1%%/*}"; }

# Definition directory of service id $1
svc_dir() {
  local dir
  dir=$(source_dir "$(svc_src "$1")") || return 1
  echo "$dir/$(svc_name "$1")"
}

# Resolve a service spec (name or source/name) to its id. A plain name resolves to the
# highest-priority source that defines it — on the command line and in x-pcm.depends_on alike.
canon() {
  local spec="$1" i
  [[ -n "$spec" && "$spec" != */*/* ]] || return 1
  if [[ "$spec" == */* ]]; then
    [[ -f "$(svc_dir "$spec" 2>/dev/null)/compose.yml" ]] || return 1
    echo "$spec"
    return 0
  fi
  for i in "${!SRC_NAMES[@]}"; do
    if [[ -f "${SRC_DIRS[$i]}/$spec/compose.yml" ]]; then
      echo "${SRC_NAMES[$i]}/$spec"
      return 0
    fi
  done
  return 1
}

is_service() {
  canon "$1" >/dev/null
}

# Every defined service id, in priority order (shadowed ones included)
all_ids() {
  local i dir
  for i in "${!SRC_NAMES[@]}"; do
    for dir in "${SRC_DIRS[$i]}"/*/; do
      [[ -f "${dir}compose.yml" ]] && echo "${SRC_NAMES[$i]}/$(basename "$dir")"
    done
  done
  return 0
}

# The service ids a plain name resolves to (one per name)
effective_ids() {
  local id seen=" "
  while IFS= read -r id; do
    [[ "$seen" == *" $(svc_name "$id") "* ]] && continue
    seen+="$(svc_name "$id") "
    echo "$id"
  done < <(all_ids)
}

# `pcm list`: NAME SOURCE STATUS, by name then priority. STATUS: running or stopped when that
# definition's containers exist (from the io.pcm.id label), shadowed when a higher-priority
# source defines the name. Blank STATUS if podman is unreachable; list never fails on it.
# --names: every id and each effective plain name, one per line (for completion).
cmd_list() {
  local id winner names=false
  [[ "${1:-}" == "--names" ]] && names=true

  local -a ids=()
  while IFS= read -r id; do ids+=("$id"); done < <(all_ids)
  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "No services found; add a source with: anfs src add <git-url> [alias]" >&2
    return 0
  fi

  if $names; then
    for id in "${ids[@]}"; do
      echo "$id"
      [[ "$(canon "$(svc_name "$id")")" == "$id" ]] && svc_name "$id"
    done
    return 0
  fi

  # Container states by pcm id: "id=running" / "id=stopped" words
  local containers="" states=" " _cid _cname state pid _status
  containers=$(pcm_containers 2>/dev/null) || containers=""
  while IFS='|' read -r _cid _cname state pid _status; do
    [[ -n "$pid" ]] || continue
    if [[ "$state" == running ]]; then
      states="${states// $pid=stopped / }"
      [[ "$states" == *" $pid=running "* ]] || states+="$pid=running "
    elif [[ "$states" != *" $pid="* ]]; then
      states+="$pid=stopped "
    fi
  done <<< "$containers"

  local i status rows="" nw=4 sw=6
  local n s
  for id in "${ids[@]}"; do
    n="${id#*/}" s="${id%%/*}"
    (( ${#n} > nw )) && nw=${#n}
    (( ${#s} > sw )) && sw=${#s}
  done
  for i in "${!ids[@]}"; do
    id="${ids[$i]}"
    winner=$(canon "$(svc_name "$id")")
    status=""
    case "$states" in
      *" $id=running "*) status=running ;;
      *" $id=stopped "*) status=stopped ;;
    esac
    [[ "$winner" != "$id" ]] && status="${status:+$status, }shadowed"
    # sort key: name, then priority index
    rows+="$(svc_name "$id")|$(printf '%04d' "$i")|$(svc_src "$id")|$status"$'\n'
  done

  local name _prio src
  printf '%-*s  %-*s  %s\n' "$nw" NAME "$sw" SOURCE STATUS
  while IFS='|' read -r name _prio src status; do
    [[ -n "$name" ]] && printf '%-*s  %-*s  %s\n' "$nw" "$name" "$sw" "$src" "$status"
  done < <(printf '%s' "$rows" | sort -t'|' -k1,1 -k2,2)
}

cmd_path() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: pcm path <service>" >&2
    return 1
  fi

  local id
  if ! id=$(canon "$1"); then
    echo "Service '$1' not found (see: pcm list)" >&2
    return 1
  fi
  svc_dir "$id"
}

# `pcm install <service|source/>...`: validate and start. source/ expands to every service that
# source defines (shadowed or not: naming the source asks for its definitions). Starting is what
# installing a container means: there is nothing else to put in place, and up is idempotent.
cmd_install() {
  local arg id dir src
  local -a services=()
  for arg in "$@"; do
    if [[ "$arg" == */ ]]; then
      src="${arg%/}"
      dir=$(source_dir "$src") || { echo "pcm: '$src' is not a source with containers (see: anfs src list)" >&2; return 1; }
      for id in $(all_ids); do
        [[ "$(svc_src "$id")" == "$src" ]] && services+=("$id")
      done
    else
      services+=("$arg")
    fi
  done
  if [[ ${#services[@]} -eq 0 ]]; then
    echo "Usage: pcm install <service|source/>..." >&2
    return 1
  fi
  cmd_up "${services[@]}"
}
