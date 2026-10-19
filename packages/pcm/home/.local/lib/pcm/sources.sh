#!/usr/bin/env bash
# pcm library: container sources and service resolution; the list, path and install commands
# Sourced by ~/.local/bin/pcm; defines functions only.

# --- sources and service resolution -------------------------------------------
# Inside pcm a service is its id, `source/name`. The name alone is its runtime identity:
# compose project, ${PCM_VOLUMES_HOME}/<name>/, the PCM_<NAME>_* provisioned env.

# Finding definitions across the sources is anfs's (lib/anfs/catalog.sh); these are pcm's names
# for it. A service is a directory with a compose.yml, in a source's containers/ or in
# $PCM_CONTAINERS_HOME, which comes first.
load_sources()  { catalog_load containers compose.yml "$PCM_LOCAL_SOURCE" "$PCM_CONTAINERS_HOME"; }
source_dir()    { catalog_source_dir "$1"; }
svc_name()      { echo "${1#*/}"; }
svc_src()       { echo "${1%%/*}"; }
svc_dir()       { catalog_dir "$1"; }
# Resolve a service spec (name or source/name) to its id. A plain name resolves to the
# highest-priority source that defines it — on the command line and in x-pcm.depends_on alike.
canon()         { catalog_canon "$1"; }
all_ids()       { catalog_all_ids; }
effective_ids() { catalog_effective_ids; }

is_service() {
  canon "$1" >/dev/null
}

# `pcm list`: CONTAINER (source/name) STATUS VERSION, by name then priority. VERSION is
# container.yml's (- without one); --json also has its description, upstream, license, url, memory. STATUS: running or stopped when that
# definition's containers exist (from the io.pcm.id label), shadowed when a higher-priority
# source defines the name. Blank STATUS if podman is unreachable; list never fails on it.
# A tool that wants the names reads `pcm list --json` (lib/anfs/table.sh).
cmd_list() {
  local id winner

  local -a ids=()
  while IFS= read -r id; do ids+=("$id"); done < <(all_ids)
  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "No services found; add a source with: anfs src add <git-url> [alias]" >&2
    ! anfs_json_on || echo '[]'
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
    manifest_fields "$id"
    # sort key: name, then priority index; the manifest's fields joined as the table joins a row
    rows+="$(svc_name "$id")|$(printf '%04d' "$i")|$(svc_src "$id")|$status|$(IFS="$ANFS_US"; echo "${MANIFEST[*]}")"$'\n'
  done

  # The table is anfs's (lib/anfs/table.sh): aligned on a terminal, --json for a tool that reads it
  local name _prio src fields
  while IFS='|' read -r name _prio src status fields; do
    [[ -z "$name" ]] || printf '%s%s%s%s%s\n' "$src/$name" "$ANFS_US" "$status" "$ANFS_US" "$fields"
  done < <(printf '%s' "$rows" | sort -t'|' -k1,1 -k2,2) |
    anfs_table "CONTAINER STATUS VERSION" "container status version description upstream license url memory"
}

cmd_path() {
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
      dir=$(source_dir "$src") || { anfs_warn "'$src' is not a source with containers (see: anfs src list)"; return 1; }
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
