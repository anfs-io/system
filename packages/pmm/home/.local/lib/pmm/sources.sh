#!/usr/bin/env bash
# pmm library: machine definitions across the sources; the list, path and install commands.
# Sourced by ~/.local/bin/pmm; functions only.

# A definition is its id, `source/name`. The name alone is the machine: its disk, its snapshots,
# its runtime record. So a name is one machine, defined by the highest-priority source that has
# it; a definition a higher one shadows is listed and nothing else. A machine `pmm run` made from
# an image has a name and no definition (settings.sh).

# Finding definitions is anfs's (lib/anfs/catalog.sh); these are pmm's names for it. A machine is
# a directory with a machine.yml, in a source's machines/ or in $PMM_MACHINES_HOME (a person's own, on this host), which is first.
# machines/ also holds images/ and networks/ (image-sources.sh, network.sh), which have no
# machine.yml and so are never taken for machines.
# canon, all_ids and effective_ids answer for the catalogue loaded last: this one, or the images'
# (image-sources.sh).
load_machines() { catalog_load machines machine.yml "$PMM_LOCAL_SOURCE" "$PMM_MACHINES_HOME"; load_networks; }
mach_name()     { echo "${1#*/}"; }
mach_src()      { echo "${1%%/*}"; }
mach_def_dir()  { catalog_dir "$1"; }
canon()         { catalog_canon "$@"; }
all_ids()       { catalog_all_ids; }
effective_ids() { catalog_effective_ids; }

name_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; }
# A machine's name: not `images` or `networks`, which are the directories beside the machines,
# and not `image-...`: a tart machine is the VM pmm-<name>, and pmm-image-... are the builds
mach_name_ok() { name_ok "$1" && [[ "$1" != images && "$1" != networks && "$1" != image-* ]]; }
PMM_NAME_RULE="lowercase letters, digits, . _ - (not 'images' or 'networks': those are machines/'s own directories; not 'image-...': those are the builds' names)"

# Resolve a machine spec. Sets M_NAME, and M_ID to where its settings are: its definition's id,
# `-/<name>` for a machine run from an image (its record has them), or nothing for a machine
# whose definition is gone (it can still be stopped, reached and removed). Dies when there is no
# such machine, or when the spec names a definition a higher-priority source shadows.
mach_find() {
  local spec="$1" id
  M_ID="" M_NAME="${spec#*/}"
  if id=$(canon "$spec"); then
    M_ID=$(canon "$M_NAME")
    [[ "$M_ID" == "$id" ]] || die "$id is shadowed by $M_ID: the machine $M_NAME is $M_ID's"
    return 0
  fi
  [[ "$spec" != */* ]] && mach_exists "$spec" || die "machine '$spec' not found (see: pmm list)"
  [[ "$(state_get "$spec" '.settings | tag')" != '!!map' ]] || M_ID="$PMM_RUN_SOURCE/$spec"
}

# `pmm list`: MACHINE STATUS IMAGE ADDRESS, by name then priority. MACHINE is source/name; a
# machine run from an image, or one whose definition is gone, has no source and is its plain name.
# STATUS: running, stopped, defined (not made yet), shadowed (a higher-priority source defines the
# name). A tool that wants the names reads `pmm list --json` (lib/anfs/table.sh).
cmd_list() {
  local id name d
  local -A seen=()
  {
    while IFS= read -r id; do
      name=$(mach_name "$id")
      if [[ "$(canon "$name")" != "$id" ]]; then
        anfs_row "$name" "$(mach_src "$id")/$name" shadowed "$(mach_get "$id" .image)" ""
        continue
      fi
      seen[$name]=1
      anfs_row "$name" "$(mach_src "$id")/$name" "$(mach_state "$name")" "$(mach_image "$name" "$id")" "$(mach_address "$name")"
    done < <(all_ids)
    for d in "$PMM_DATA_HOME"/machines/*/; do
      [[ -f "${d}state.yml" ]] || continue
      name=$(basename "$d")
      [[ -z "${seen[$name]:-}" ]] || continue
      anfs_row "$name" "$name" "$(mach_state "$name")" "$(state_get "$name" .image)" "$(mach_address "$name")"
    done
  } | anfs_sorted | anfs_table "MACHINE STATUS IMAGE ADDRESS" "machine status image address"
}

cmd_path() {
  mach_find "$1"
  ! mach_is_run "$M_ID" || die "$M_NAME has no definition: it was run from an image (pmm show $M_NAME prints its settings)"
  [[ -n "$M_ID" ]] || die "$M_NAME has no definition any more"
  mach_def_dir "$M_ID"
}

# `pmm install <machine|source/>...`: create and start (PMM_INSTALL=create: only create;
# validate: only validate). source/ is everything that source defines, in the order one needs
# the other: its images are built, its networks installed, then its machines made.
cmd_install() {
  local arg id src
  local -a machines=()
  case "$PMM_INSTALL" in
    up|create|validate) ;;
    *) die "PMM_INSTALL must be up, create or validate, not '$PMM_INSTALL'" ;;
  esac
  for arg in "$@"; do
    if [[ "$arg" == */ ]]; then
      src="${arg%/}"
      # images and networks are directories of the source's machines/: without it, there are none
      catalog_source_dir "$src" >/dev/null || die "'$src' is not a source with machines/ (see: anfs src list)"
      # in a subshell: the images' catalogue is loaded there, the machines' stays loaded here
      if ( load_images; source_dir "$src" >/dev/null ); then
        # not in an || list: errexit must stay on inside a build
        ( load_images; images_install "$src" )
        [[ $? -eq 0 ]] || return 1
      fi
      if net_source_dir "$src" >/dev/null; then
        cli_call "network install" "$arg"
      fi
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
        mach_exists "$M_NAME" || machine_make "$M_NAME" "$M_ID"
      done ;;
    up) cli_call up "${machines[@]}" ;;
  esac
}
