#!/usr/bin/env bash
# pim library: image sources and resolution; the list, path and install commands
# Sourced by ~/.local/bin/pim; defines functions only.

# Inside pim an image is its id, `source/name`. The name alone is its runtime identity: the
# build and VM directories, the run state, the ssh key.

# Finding definitions across the sources is anfs's (lib/anfs/catalog.sh); these are pim's names
# for it. An image is a directory with an image.yml, in a source's images/ or in
# $PIM_IMAGES_HOME, which comes first.
load_sources()  { catalog_load images image.yml "$PIM_LOCAL_SOURCE" "$PIM_IMAGES_HOME"; }
source_dir()    { catalog_source_dir "$1"; }
source_index()  { catalog_source_index "$1"; }
img_name()      { echo "${1#*/}"; }
img_src()       { echo "${1%%/*}"; }
img_dir()       { catalog_dir "$1"; }
# Resolve an image spec (name or source/name) to its id. A plain name resolves to the
# highest-priority source defining it, searching from priority index <min> (default 0): from:
# passes its own source's index, so a parent is in the same or a lower-priority source.
canon()         { catalog_canon "$@"; }
all_ids()       { catalog_all_ids; }
effective_ids() { catalog_effective_ids; }

# canon, or die naming the spec
canon_or_die() {
  canon "$1" || die "image '$1' not found (see: pim list)"
}

# `pim list`: NAME SOURCE STATUS. STATUS: the arches built for that definition, running when its
# VM is up, shadowed when a higher-priority source defines the name.
# A tool that wants the names reads `pim list --json` (lib/anfs/table.sh).
cmd_list() {
  local id

  local -a ids=()
  while IFS= read -r id; do ids+=("$id"); done < <(all_ids)
  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "No images found; add a source with: anfs src add <git-url> [alias]" >&2
    ! anfs_json_on || echo '[]'
    return 0
  fi

  local nw=4 sw=6 n s
  for id in "${ids[@]}"; do
    n="${id#*/}" s="${id%%/*}"
    (( ${#n} > nw )) && nw=${#n}
    (( ${#s} > sw )) && sw=${#s}
  done
  local i status rows="" arch built
  for i in "${!ids[@]}"; do
    id="${ids[$i]}"
    status=""
    if [[ "$(canon "$(img_name "$id")")" == "$id" ]]; then
      built=""
      for arch in arm64 amd64; do
        [[ "$(meta_get "$(img_name "$id")" "$arch" .id)" == "$id" ]] && built+="${built:+,}$arch"
      done
      [[ -n "$built" ]] && status="built $built"
      vm_running "$(img_name "$id")" && status="${status:+$status, }running"
    else
      status="shadowed"
    fi
    rows+="$(img_name "$id")|$(printf '%04d' "$i")|$(img_src "$id")|$status"$'\n'
  done

  # The table is anfs's (lib/anfs/table.sh): aligned on a terminal, --json for a tool that reads it
  local name _prio src
  while IFS='|' read -r name _prio src status; do
    [[ -z "$name" ]] || anfs_row "$name" "$src" "$status"
  done < <(printf '%s' "$rows" | sort -t'|' -k1,1 -k2,2) | anfs_table "NAME SOURCE STATUS" "name source status"
}

cmd_path() {
  local disk=${CLI_OPT[disk]:-false} arch="" id
  [[ -z "${CLI_OPT[arch]:-}" ]] || arch=$(arch_norm "${CLI_OPT[arch]}")
  id=$(canon_or_die "$1")
  if $disk; then
    arch="${arch:-$(host_arch)}"
    local d
    d=$(build_disk "$(img_name "$id")" "$arch") || die "$id has no $arch build (pim build $id)"
    echo "$d"
  else
    img_dir "$id"
  fi
}

# `pim install <image|source/>...`: build (or with PIM_INSTALL=validate, only validate).
# source/ expands to every image that source defines.
cmd_install() {
  local arg id src
  local -a images=()
  for arg in "$@"; do
    if [[ "$arg" == */ ]]; then
      src="${arg%/}"
      source_dir "$src" >/dev/null || die "'$src' is not a source with images (see: anfs src list)"
      for id in $(all_ids); do
        [[ "$(img_src "$id")" == "$src" ]] && images+=("$id")
      done
    else
      images+=("$arg")
    fi
  done
  [[ ${#images[@]} -gt 0 ]] || die "Usage: pim install <image|source/>..."
  case "$PIM_INSTALL" in
    validate) cli_call validate "${images[@]}" ;;
    build) cli_call build "${images[@]}" ;;
    *) die "PIM_INSTALL must be build or validate, not '$PIM_INSTALL'" ;;
  esac
}
