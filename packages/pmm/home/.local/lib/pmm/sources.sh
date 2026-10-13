#!/usr/bin/env bash
# pmm library: machine definitions across the sources; the list, path and install commands.
# Sourced by ~/.local/bin/pmm; functions only.

# A definition is its id, `source/name`. The name alone is the machine: its disk, its snapshots,
# its runtime record. So a name is one machine, defined by the highest-priority source that has
# it; a definition a higher one shadows is listed and nothing else.

# Finding definitions is anfs's (lib/anfs/catalog.sh); these are pmm's names for it. A machine is
# a directory with a machine.yml, in a source's machines/ or in $PMM_MACHINES_HOME, which is first.
load_machines() { catalog_load machines machine.yml "$PMM_LOCAL_SOURCE" "$PMM_MACHINES_HOME"; load_networks; }
mach_name()     { echo "${1#*/}"; }
mach_src()      { echo "${1%%/*}"; }
mach_def_dir()  { catalog_dir "$1"; }
canon()         { catalog_canon "$@"; }
all_ids()       { catalog_all_ids; }
effective_ids() { catalog_effective_ids; }

name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; }

# Resolve a machine spec. Sets M_NAME, and M_ID to its definition's id, or to nothing for a
# machine whose definition is gone (it can still be stopped, reached and removed). Dies when
# there is neither, or when the spec names a definition a higher-priority source shadows.
mach_find() {
  local spec="$1" id
  M_ID="" M_NAME="${spec#*/}"
  if id=$(canon "$spec"); then
    M_ID=$(canon "$M_NAME")
    [[ "$M_ID" == "$id" ]] || die "$id is shadowed by $M_ID: the machine $M_NAME is $M_ID's"
    return 0
  fi
  [[ "$spec" != */* ]] && mach_exists "$spec" && return 0
  die "machine '$spec' not found (see: pmm list)"
}

# Write a local definition: def_write <name> <key> <value>... (a key ending in [] takes its value
# as one item of a list; an empty value is left out)
def_write() {
  local name="$1" dir k v
  shift
  dir="$PMM_MACHINES_HOME/$name"
  mkdir -p "$dir"
  : > "$dir/machine.yml.tmp"
  while [[ $# -ge 2 ]]; do
    k="$1" v="$2"
    shift 2
    [[ -n "$v" ]] || continue
    if [[ "$k" == *"[]" ]]; then K="${k%\[\]}" V="$v" yq -i '.[strenv(K)] += [strenv(V)]' "$dir/machine.yml.tmp"
    elif [[ "$v" =~ ^[0-9]+$ ]]; then K="$k" V="$v" yq -i '.[strenv(K)] = (strenv(V) | tonumber)' "$dir/machine.yml.tmp"
    else K="$k" V="$v" yq -i '.[strenv(K)] = strenv(V)' "$dir/machine.yml.tmp"
    fi
  done
  mv "$dir/machine.yml.tmp" "$dir/machine.yml"
}

# `pmm list`: NAME SOURCE IMAGE STATE ADDRESS. STATE: running, stopped, defined (not made yet),
# shadowed (a higher-priority source defines the name). A machine whose definition is gone has no
# source. A tool that wants the names reads `pmm list --json` (lib/anfs/table.sh).
cmd_list() {
  local id name d
  local -A seen=()
  {
    while IFS= read -r id; do
      name=$(mach_name "$id")
      if [[ "$(canon "$name")" != "$id" ]]; then
        anfs_row "$name" "$(mach_src "$id")" "$(mach_get "$id" .image)" shadowed ""
        continue
      fi
      seen[$name]=1
      anfs_row "$name" "$(mach_src "$id")" "$(mach_image "$name" "$id")" "$(mach_state "$name")" "$(mach_address "$name")"
    done < <(all_ids)
    for d in "$PMM_DATA_HOME"/machines/*/; do
      [[ -f "${d}state.yml" ]] || continue
      name=$(basename "$d")
      [[ -z "${seen[$name]:-}" ]] || continue
      anfs_row "$name" "" "$(state_get "$name" .image)" "$(mach_state "$name")" "$(mach_address "$name")"
    done
  } | LC_ALL=C sort -s -t$'\t' -k1,1 | anfs_table "NAME SOURCE IMAGE STATE ADDRESS" "name source image state address"
}

cmd_path() {
  mach_find "$1"
  [[ -n "$M_ID" ]] || die "$M_NAME has no definition any more"
  mach_def_dir "$M_ID"
}

# `pmm install <machine|source/>...`: create and start (PMM_INSTALL=create: only create;
# validate: only validate). source/ expands to every network and machine that source defines.
cmd_install() {
  local arg id src
  local -a machines=()
  for arg in "$@"; do
    if [[ "$arg" == */ ]]; then
      src="${arg%/}"
      # a source's networks first: its machines are on them
      if net_source_dir "$src" >/dev/null; then
        cli_call "network install" "$arg"
        catalog_source_dir "$src" >/dev/null || continue
      fi
      catalog_source_dir "$src" >/dev/null || die "'$src' is not a source with machines or networks (see: anfs src list)"
      for id in $(all_ids); do
        [[ "$(mach_src "$id")" == "$src" ]] && machines+=("$id")
      done
    else
      machines+=("$arg")
    fi
  done
  [[ ${#machines[@]} -gt 0 ]] || { echo "No machines to install"; return 0; }
  case "$PMM_INSTALL" in
    validate) cli_call validate "${machines[@]}" ;;
    create)
      for arg in "${machines[@]}"; do
        mach_find "$arg"
        mach_exists "$M_NAME" || cli_call create "$M_NAME"
      done ;;
    up) cli_call up "${machines[@]}" ;;
    *) die "PMM_INSTALL must be up, create or validate, not '$PMM_INSTALL'" ;;
  esac
}
