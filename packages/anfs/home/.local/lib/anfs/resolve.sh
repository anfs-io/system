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
# Requires sources.sh. Functions only; bash 3.2-safe.

# The word for one resource of a kind, for messages
anfs_kind() {
  case "$1" in
    packages) echo package ;;
    containers) echo container ;;
    images) echo image ;;
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
  for i in ${GITSRC_NAMES[@]+"${!GITSRC_NAMES[@]}"}; do
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
  for n in ${ANFS_SRC_NAMES[@]+"${ANFS_SRC_NAMES[@]}"}; do
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
  for i in ${ANFS_SRC_NAMES[@]+"${!ANFS_SRC_NAMES[@]}"}; do
    name="${ANFS_SRC_NAMES[$i]}"
    [[ $# -eq 0 || "$want" == *" $name "* ]] || continue
    for entry in "${ANFS_SRC_DIRS[$i]}/$tld"/*/; do
      [[ -d "$entry" ]] && echo "$name/$(basename "$entry")"
    done
  done
  return 0
}

# Every match for a spec: one "index<TAB>source<TAB>dir" line per layer; false if none.
# min_index skips higher-priority sources (the dependency rule). Call anfs_sources first.
# Usage: anfs_find <dir> <spec> [min_index]
anfs_find() {
  local tld="$1" spec="$2" min="${3:-0}" src="" name i found=false
  if [[ "$spec" == */* ]]; then
    src="${spec%%/*}" name="${spec#*/}"
  else
    name="$spec"
  fi
  [[ -n "$name" ]] || return 1
  for i in ${ANFS_SRC_NAMES[@]+"${!ANFS_SRC_NAMES[@]}"}; do
    [[ $i -lt $min ]] && continue
    [[ -n "$src" && "${ANFS_SRC_NAMES[$i]}" != "$src" ]] && continue
    if [[ -d "${ANFS_SRC_DIRS[$i]}/$tld/$name" ]]; then
      printf '%s\t%s\t%s\n' "$i" "${ANFS_SRC_NAMES[$i]}" "${ANFS_SRC_DIRS[$i]}/$tld/$name"
      found=true
    fi
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
# a tool installing them in order can let higher layers win (ppm's shared stow ignore list).
# A dependency on a sibling layer (user/git depends on pde/git) is satisfied by the group itself.
# Unknown names and cycles are fatal: a half-ordered install is worse than none.
#
# ANFS_RESOLVE_FIRST=true takes only the highest-priority match of each name instead of every
# layer. Layers are how packages override each other file by file; for a kind that does not
# merge (spaces), every match would install every source's resource of that name.

anfs_resolve() {
  local tld="$1" deps_fn="$2" spec
  shift 2
  ANFS_ORDER=() ANFS_ORDER_DIRS=()
  _ANFS_RESOLVED=$'\n' _ANFS_RESOLVING=$'\n'
  for spec in "$@"; do
    _anfs_resolve_one "$tld" "$deps_fn" "$spec" 0
  done
}

_anfs_resolve_one() {
  local tld="$1" deps_fn="$2" spec="$3" min="$4" name="${3##*/}"
  local matches idx src dir qualified
  matches=$(anfs_find "$tld" "$spec" "$min") || {
    echo "Error: $(anfs_kind "$tld") '$spec' not found" >&2
    exit 1
  }

  [[ "${ANFS_RESOLVE_FIRST:-false}" == true ]] && matches="${matches%%$'\n'*}"

  local -a names=() dirs=() idxs=()
  while IFS=$'\t' read -r idx src dir; do
    [[ -n "$idx" ]] || continue
    qualified="$src/$name"
    [[ "$_ANFS_RESOLVED" == *$'\n'"$qualified"$'\n'* ]] && continue
    if [[ "$_ANFS_RESOLVING" == *$'\n'"$qualified"$'\n'* ]]; then
      echo "Error: circular dependency: $qualified" >&2
      exit 1
    fi
    _ANFS_RESOLVING="$_ANFS_RESOLVING$qualified"$'\n'
    names+=("$qualified") dirs+=("$dir") idxs+=("$idx")
  done <<< "$matches"
  [[ ${#names[@]} -gt 0 ]] || return 0

  local i dep
  for i in "${!names[@]}"; do
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      [[ "$dep" == "$name" ]] && continue
      printf '%s\n' "${names[@]}" | grep -qxF -- "$dep" && continue
      _anfs_resolve_one "$tld" "$deps_fn" "$dep" "${idxs[$i]}"
    done < <("$deps_fn" "${dirs[$i]}")
  done

  for i in "${!names[@]}"; do
    _ANFS_RESOLVED="$_ANFS_RESOLVED${names[$i]}"$'\n'
    ANFS_ORDER+=("${names[$i]}")
    ANFS_ORDER_DIRS+=("${dirs[$i]}")
  done
}
