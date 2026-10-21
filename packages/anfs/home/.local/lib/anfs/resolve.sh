#!/usr/bin/env bash
# anfs: finding resources in sources, and ordering them by their dependencies
#
# A resource is a directory <source>/<dir>/<name>/, where <dir> is a tool's top-level directory
# (packages, containers, skills, spaces). Every tool names them the same three ways:
#
#   name           every source that has it, in priority order; each match is a layer
#   source/name    that source only
#   source/        every resource of the tool's kind in that source
#
# Sources come from sources.sh (gitsrc_collect, gitsrc_dir), in priority order. Only the ones
# holding <dir>/ count for a tool, and their position in that filtered list is what layering and
# the dependency rule compare: a dependency resolves to the same or a lower-priority source.
#
# Requires sources.sh. Functions only; written for the bash floor (5.2, see bash.sh).

# The word for one resource of a kind, for messages
anfs_kind() {
  case "$1" in
    packages) echo package ;;
    containers) echo container ;;
    machines) echo machine ;;
    skills) echo skill ;;
    spaces) echo space ;;
    *) echo "$1" ;;
  esac
}

# Fill ANFS_SRC_NAMES and ANFS_SRC_DIRS with the sources holding <dir>/, in priority order
# Usage: anfs_sources <dir>
anfs_sources() {
  local tld="$1" i name dir
  ANFS_SRC_NAMES=() ANFS_SRC_DIRS=()
  gitsrc_collect
  for i in "${!GITSRC_NAMES[@]}"; do
    name="${GITSRC_NAMES[$i]}"
    dir=$(gitsrc_dir "$name")
    [[ -d "$dir/$tld" ]] || continue
    ANFS_SRC_NAMES+=("$name")
    ANFS_SRC_DIRS+=("$dir")
  done
}

# True when <name> is a source holding <dir>/ (call anfs_sources first)
# Usage: anfs_is_source <name>
anfs_is_source() {
  local n
  for n in "${ANFS_SRC_NAMES[@]}"; do
    [[ "$n" == "$1" ]] && return 0
  done
  return 1
}

# Every resource of <dir> as source/name, in priority order, optionally only from the named
# sources (call anfs_sources first)
# Usage: anfs_list <dir> [source...]
anfs_list() {
  local tld="$1" i name want entry
  shift
  want=" $* "
  for i in "${!ANFS_SRC_NAMES[@]}"; do
    name="${ANFS_SRC_NAMES[$i]}"
    [[ $# -eq 0 || "$want" == *" $name "* ]] || continue
    for entry in "${ANFS_SRC_DIRS[$i]}/$tld"/*/; do
      [[ -d "$entry" ]] && echo "$name/$(basename "$entry")"
    done
  done
  return 0
}

# Split a spec into _ANFS_SRC (empty when unqualified) and _ANFS_NAME. A name is one path segment,
# so a spec with a / is source-qualified. ANFS_NAME_NEST=true is for a kind whose names nest to
# any depth (spaces: lgat/tech/web): the first segment is the source when it is one
# (anfs_is_source), and the rest, possibly empty, is the name; otherwise the whole spec is a name.
_anfs_split() {
  local spec="$1"
  if [[ "${ANFS_NAME_NEST:-false}" == true ]]; then
    if anfs_is_source "${spec%%/*}"; then
      _ANFS_SRC="${spec%%/*}" _ANFS_NAME=""
      [[ "$spec" != */* ]] || _ANFS_NAME="${spec#*/}"
    else
      _ANFS_SRC="" _ANFS_NAME="$spec"
    fi
  elif [[ "$spec" == */* ]]; then
    _ANFS_SRC="${spec%%/*}" _ANFS_NAME="${spec#*/}"
  else
    _ANFS_SRC="" _ANFS_NAME="$spec"
  fi
}

# Every match for a spec: one "index<TAB>source<TAB>dir" line per layer; false if none.
# min_index skips higher-priority sources (the dependency rule). Call anfs_sources first.
# ANFS_RESOLVE_MARKER names a file the resource directory must hold (wsm: space.yml), so a plain
# directory on the way to a nested one is not a resource. With it, a source and an empty name
# (ANFS_NAME_NEST: the spec is the source alone) is <source>/<dir>/ itself.
# Usage: anfs_find <dir> <spec> [min_index]
anfs_find() {
  local tld="$1" spec="$2" min="${3:-0}" src name i d found=false marker="${ANFS_RESOLVE_MARKER:-}"
  _anfs_split "$spec"
  src="$_ANFS_SRC" name="$_ANFS_NAME"
  [[ -n "$name" || ( -n "$src" && -n "$marker" ) ]] || return 1
  for i in "${!ANFS_SRC_NAMES[@]}"; do
    [[ $i -lt $min ]] && continue
    [[ -n "$src" && "${ANFS_SRC_NAMES[$i]}" != "$src" ]] && continue
    d="${ANFS_SRC_DIRS[$i]}/$tld${name:+/$name}"
    [[ -d "$d" ]] || continue
    [[ -z "$marker" || -f "$d/$marker" ]] || continue
    printf '%s\t%s\t%s\n' "$i" "${ANFS_SRC_NAMES[$i]}" "$d"
    found=true
  done
  $found
}

# --- dependency order ----------------------------------------------------------------------------
#
# anfs_resolve <dir> <deps_fn> <spec>... fills, deps first:
#   ANFS_ORDER       source/name
#   ANFS_ORDER_DIRS  the resource directories
# <deps_fn> <resource_dir> prints the names that resource depends on, one per line. Every layer of
# a name is resolved together and the layers land next to each other, highest priority first, so
# a tool installing them in order can let higher layers win (ppm's shared skip list).
# A dependency on a sibling layer (user/git depends on stack/git) is satisfied by the group itself.
# Unknown names and cycles are fatal: a half-ordered install is worse than none.
#
# ANFS_RESOLVE_FIRST=true takes only the highest-priority match of each name instead of every
# layer. Layers are how packages override each other file by file; for a kind that does not
# merge (spaces), every match would install every source's resource of that name.
#
# ANFS_NAME_NEST=true and ANFS_RESOLVE_MARKER (see _anfs_split, anfs_find) are for wsm, whose
# names are paths of any depth: a resource is then source/path, or the source alone (its root).

anfs_resolve() {
  local tld="$1" deps_fn="$2" spec
  shift 2
  ANFS_ORDER=() ANFS_ORDER_DIRS=()
  # source/name -> 1: what is already ordered, and what is on the current dependency path
  declare -gA _ANFS_RESOLVED=() _ANFS_RESOLVING=()
  for spec in "$@"; do
    _anfs_resolve_one "$tld" "$deps_fn" "$spec" 0
  done
}

_anfs_resolve_one() {
  local tld="$1" deps_fn="$2" spec="$3" min="$4" name
  local matches idx src dir qualified
  _anfs_split "$spec"
  name="$_ANFS_NAME"
  matches=$(anfs_find "$tld" "$spec" "$min") || {
    echo "Error: $(anfs_kind "$tld") '$spec' not found" >&2
    exit 1
  }

  [[ "${ANFS_RESOLVE_FIRST:-false}" == true ]] && matches="${matches%%$'\n'*}"

  local -a names=() dirs=() idxs=()
  local -A group=()
  while IFS=$'\t' read -r idx src dir; do
    [[ -n "$idx" ]] || continue
    qualified="$src${name:+/$name}"
    [[ -n "${_ANFS_RESOLVED[$qualified]:-}" ]] && continue
    if [[ -n "${_ANFS_RESOLVING[$qualified]:-}" ]]; then
      echo "Error: circular dependency: $qualified" >&2
      exit 1
    fi
    _ANFS_RESOLVING[$qualified]=1 group[$qualified]=1
    names+=("$qualified") dirs+=("$dir") idxs+=("$idx")
  done <<< "$matches"
  [[ ${#names[@]} -gt 0 ]] || return 0

  local i dep
  local -a deps
  for i in "${!names[@]}"; do
    mapfile -t deps < <("$deps_fn" "${dirs[$i]}")
    for dep in "${deps[@]}"; do
      [[ -n "$dep" ]] || continue
      [[ "$dep" == "$name" ]] && continue
      [[ -n "${group[$dep]:-}" ]] && continue
      _anfs_resolve_one "$tld" "$deps_fn" "$dep" "${idxs[$i]}"
    done
  done

  for i in "${!names[@]}"; do
    _ANFS_RESOLVED[${names[$i]}]=1
    ANFS_ORDER+=("${names[$i]}")
    ANFS_ORDER_DIRS+=("${dirs[$i]}")
  done
}
