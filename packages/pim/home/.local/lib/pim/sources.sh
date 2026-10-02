#!/usr/bin/env bash
# pim library: image sources and resolution; the list, path and install commands
# Sourced by ~/.local/bin/pim; defines functions only.

# Inside pim an image is its id, `source/name`. The name alone is its runtime identity: the
# build and VM directories, the run state, the ssh key.

SRC_NAMES=()
SRC_DIRS=()

# Load the sources in priority order into SRC_NAMES and SRC_DIRS (each dir holds <name>/)
load_sources() {
  local i name
  SRC_NAMES=("$PIM_LOCAL_SOURCE")
  SRC_DIRS=("$PIM_IMAGES_HOME")
  gitsrc_collect
  for i in ${GITSRC_NAMES[@]+"${!GITSRC_NAMES[@]}"}; do
    name="${GITSRC_NAMES[$i]}"
    if [[ "$name" == "$PIM_LOCAL_SOURCE" ]]; then
      warn "ignoring source alias '$name': reserved for $PIM_IMAGES_HOME"
      continue
    fi
    [[ -d "$(gitsrc_dir "$name")/images" ]] || continue
    SRC_NAMES+=("$name")
    SRC_DIRS+=("$(gitsrc_dir "$name")/images")
  done
}

# Images dir of source $1
source_dir() {
  local i
  for i in "${!SRC_NAMES[@]}"; do
    [[ "${SRC_NAMES[$i]}" == "$1" ]] && { echo "${SRC_DIRS[$i]}"; return 0; }
  done
  return 1
}

# Priority index of source $1 (0 is local, the highest)
source_index() {
  local i
  for i in "${!SRC_NAMES[@]}"; do
    [[ "${SRC_NAMES[$i]}" == "$1" ]] && { echo "$i"; return 0; }
  done
  echo 9999
}

img_name() { echo "${1#*/}"; }
img_src()  { echo "${1%%/*}"; }

# Definition directory of image id $1
img_dir() {
  local dir
  dir=$(source_dir "$(img_src "$1")") || return 1
  echo "$dir/$(img_name "$1")"
}

# Resolve an image spec (name or source/name) to its id. A plain name resolves to the
# highest-priority source defining it, searching from priority index <min> (default 0): from:
# passes its own source's index, so a parent is in the same or a lower-priority source.
canon() {
  local spec="$1" min="${2:-0}" i
  [[ -n "$spec" && "$spec" != */*/* ]] || return 1
  if [[ "$spec" == */* ]]; then
    [[ -f "$(img_dir "$spec" 2>/dev/null)/image.yml" ]] || return 1
    [[ "$(source_index "$(img_src "$spec")")" -ge "$min" ]] || return 1
    echo "$spec"
    return 0
  fi
  for i in "${!SRC_NAMES[@]}"; do
    [[ $i -ge $min ]] || continue
    if [[ -f "${SRC_DIRS[$i]}/$spec/image.yml" ]]; then
      echo "${SRC_NAMES[$i]}/$spec"
      return 0
    fi
  done
  return 1
}

# canon, or die naming the spec
canon_or_die() {
  canon "$1" || die "image '$1' not found (see: pim list)"
}

# Every defined image id, in priority order (shadowed ones included)
all_ids() {
  local i dir
  for i in "${!SRC_NAMES[@]}"; do
    for dir in "${SRC_DIRS[$i]}"/*/; do
      [[ -f "${dir}image.yml" ]] && echo "${SRC_NAMES[$i]}/$(basename "$dir")"
    done
  done
  return 0
}

# The image ids plain names resolve to (one per name)
effective_ids() {
  local id seen=" "
  while IFS= read -r id; do
    [[ "$seen" == *" $(img_name "$id") "* ]] && continue
    seen+="$(img_name "$id") "
    echo "$id"
  done < <(all_ids)
}

# `pim list`: NAME SOURCE STATUS. STATUS: the arches built for that definition, running when its
# VM is up, shadowed when a higher-priority source defines the name.
# --names: every id and each effective plain name, one per line (for completion).
cmd_list() {
  local id names=false
  [[ "${1:-}" == "--names" ]] && names=true

  local -a ids=()
  while IFS= read -r id; do ids+=("$id"); done < <(all_ids)
  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "No images found; add a source with: anfs src add <git-url> [alias]" >&2
    return 0
  fi

  if $names; then
    for id in "${ids[@]}"; do
      echo "$id"
      [[ "$(canon "$(img_name "$id")")" == "$id" ]] && img_name "$id"
    done
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

  local name _prio src
  printf '%-*s  %-*s  %s\n' "$nw" NAME "$sw" SOURCE STATUS
  while IFS='|' read -r name _prio src status; do
    [[ -n "$name" ]] && printf '%-*s  %-*s  %s\n' "$nw" "$name" "$sw" "$src" "$status"
  done < <(printf '%s' "$rows" | sort -t'|' -k1,1 -k2,2)
}

cmd_path() {
  local disk=false arch="" id
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk) disk=true ;;
      --arch) arch=$(arch_norm "${2:?--arch needs a value}"); shift ;;
      -*) die "path: unknown option '$1'" ;;
      *) break ;;
    esac
    shift
  done
  [[ $# -gt 0 ]] || die "Usage: pim path [--disk] [--arch A] <image>"
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
    validate) cmd_validate "${images[@]}" ;;
    build) cmd_build "${images[@]}" ;;
    *) die "PIM_INSTALL must be build or validate, not '$PIM_INSTALL'" ;;
  esac
}
