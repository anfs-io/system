#!/usr/bin/env bash
# anfs: a catalogue — the definitions of one kind across the sources, and resolving a name to one
#
# pcm's services and pim's images are found the same way: every source may hold a directory of a
# kind (containers/, images/), each definition is a directory in it with a marker file
# (compose.yml, image.yml), and a tool has a place of its own for hand-made ones that comes first.
# A definition's id is `source/name`; a plain name is the highest-priority source that has it.
#
#   catalog_load <kind> <marker> <local alias> <local dir>
#       Collect the sources in priority order into SRC_NAMES and SRC_DIRS (each dir holds
#       <name>/). The local one is first; a source whose alias is the local alias is ignored.
#   catalog_source_dir <source>      its directory of the kind; returns 1 for none
#   catalog_source_index <source>    its priority index (0 is local, the highest); 9999 for none
#   catalog_dir <id>                 a definition's directory
#   catalog_canon <spec> [min]       name or source/name -> id; a plain name is searched from
#                                    priority index <min> (default 0), so a definition can be
#                                    looked up in the same or a lower-priority source than
#                                    another (pim's from:)
#   catalog_all_ids                  every id, in priority order, shadowed ones included
#   catalog_effective_ids            the id each plain name resolves to, one per name
#
# One catalogue per process: catalog_load sets what the others read. A tool with two kinds loads
# one, uses it, then loads the other.
#
# Requires sources.sh (gitsrc_collect, gitsrc_dir) and log.sh. Functions only; written for the
# bash floor (5.2, see bash.sh).

SRC_NAMES=()
SRC_DIRS=()
CATALOG_KIND="" CATALOG_MARKER=""

catalog_load() {
  local kind="$1" marker="$2" local_name="$3" local_dir="$4" i name dir
  CATALOG_KIND="$kind" CATALOG_MARKER="$marker"
  SRC_NAMES=("$local_name")
  SRC_DIRS=("$local_dir")
  gitsrc_collect
  for i in "${!GITSRC_NAMES[@]}"; do
    name="${GITSRC_NAMES[$i]}"
    if [[ "$name" == "$local_name" ]]; then
      anfs_warn "ignoring source alias '$name': reserved for $local_dir"
      continue
    fi
    dir="$(gitsrc_dir "$name")/$kind"
    [[ -d "$dir" ]] || continue
    SRC_NAMES+=("$name")
    SRC_DIRS+=("$dir")
  done
}

catalog_source_dir() {
  local i
  for i in "${!SRC_NAMES[@]}"; do
    [[ "${SRC_NAMES[$i]}" == "$1" ]] && { echo "${SRC_DIRS[$i]}"; return 0; }
  done
  return 1
}

catalog_source_index() {
  local i
  for i in "${!SRC_NAMES[@]}"; do
    [[ "${SRC_NAMES[$i]}" == "$1" ]] && { echo "$i"; return 0; }
  done
  echo 9999
}

catalog_dir() {
  local dir
  dir=$(catalog_source_dir "${1%%/*}") || return 1
  echo "$dir/${1#*/}"
}

catalog_canon() {
  local spec="$1" min="${2:-0}" i
  [[ -n "$spec" && "$spec" != */*/* ]] || return 1
  if [[ "$spec" == */* ]]; then
    [[ -f "$(catalog_dir "$spec" 2>/dev/null)/$CATALOG_MARKER" ]] || return 1
    [[ "$(catalog_source_index "${spec%%/*}")" -ge "$min" ]] || return 1
    echo "$spec"
    return 0
  fi
  for i in "${!SRC_NAMES[@]}"; do
    [[ $i -ge $min ]] || continue
    if [[ -f "${SRC_DIRS[$i]}/$spec/$CATALOG_MARKER" ]]; then
      echo "${SRC_NAMES[$i]}/$spec"
      return 0
    fi
  done
  return 1
}

catalog_all_ids() {
  local i dir
  for i in "${!SRC_NAMES[@]}"; do
    for dir in "${SRC_DIRS[$i]}"/*/; do
      [[ -f "${dir}$CATALOG_MARKER" ]] && echo "${SRC_NAMES[$i]}/$(basename "$dir")"
    done
  done
  return 0
}

catalog_effective_ids() {
  local id name
  local -A seen=()
  while IFS= read -r id; do
    name="${id#*/}"
    [[ -z "${seen[$name]:-}" ]] || continue
    seen[$name]=1
    echo "$id"
  done < <(catalog_all_ids)
}
