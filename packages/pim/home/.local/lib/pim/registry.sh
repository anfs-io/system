#!/usr/bin/env bash
# pim library: what has been built — each build's meta.yml; the show, rm and clean commands.
# Sourced by ~/.local/bin/pim; functions only.
#
# There is no central registry file: $PIM_DATA_HOME/images/<name>/<arch>/meta.yml describes the
# current build of one image for one arch, next to its disk (<key>.qcow2) and UEFI vars. Older
# disks stay until `pim clean`, since another image's build may be an overlay on them.

meta_dir()  { echo "$PIM_DATA_HOME/images/$1/$2"; }
meta_file() { echo "$(meta_dir "$1" "$2")/meta.yml"; }

# A value from a build's meta.yml, or nothing
# Usage: meta_get <name> <arch> <yq path>
meta_get() {
  local f
  f=$(meta_file "$1" "$2")
  [[ -f "$f" ]] || return 0
  yq -r "($3) | select(. != null)" "$f" 2>/dev/null || true
}

# The current build's disk for <name> <arch>; fails when there is none
build_disk() {
  local key d
  key=$(meta_get "$1" "$2" .cache_key)
  d="$(meta_dir "$1" "$2")/$key.qcow2"
  [[ -n "$key" && -f "$d" ]] && echo "$d"
}

# True when the build <key> of <name> <arch> exists: a qcow2, or for tart a VM in tart's store
build_present() {
  case "$4" in
    tart) tart_exists "$(tart_vm_build "$1" "$3")" ;;
    *) [[ -f "$(meta_dir "$1" "$2")/$3.qcow2" ]] ;;
  esac
}

# Record a finished build
# Usage: meta_write_build <id> <arch> <key> <parent id|"">
meta_write_build() {
  local id="$1" arch="$2" key="$3" parent="$4" name pdisk="" pkey=""
  name=$(img_name "$id")
  if [[ -n "$parent" ]]; then
    pdisk=$(build_disk "$(img_name "$parent")" "$arch")
    pkey=$(meta_get "$(img_name "$parent")" "$arch" .cache_key)
  fi
  ID="$id" NAME="$name" ARCH="$arch" KEY="$key" BACKEND="$(img_backend "$id")" \
  PARENT="$parent" PKEY="$pkey" PDISK="$pdisk" USER_="$(img_user "$id")" AT="$(now_iso)" \
  ISO="$( [[ -z "$parent" && "$(img_backend "$id")" == qemu ]] && img_list "$id" ".iso.$arch.url" | head -n1)" \
    yq -n '.id = strenv(ID) | .name = strenv(NAME) | .arch = strenv(ARCH) | .backend = strenv(BACKEND)
           | .cache_key = strenv(KEY) | .disk = strenv(KEY) + ".qcow2" | .user = strenv(USER_)
           | .built_at = strenv(AT)
           | .parent = (strenv(PARENT) | select(. != "") | {"id": ., "cache_key": strenv(PKEY), "disk": strenv(PDISK)})
           | .iso = (strenv(ISO) | select(. != ""))
           | .verified_key = null | .published = []' > "$(meta_file "$name" "$arch").tmp"
  mv "$(meta_file "$name" "$arch").tmp" "$(meta_file "$name" "$arch")"
}

# Set one field of a build's meta.yml: meta_set <name> <arch> <yq assignment using $v> <value>
meta_set() {
  local f
  f=$(meta_file "$1" "$2")
  v="$4" yq -i "$3" "$f"
}

# Every built image name (that has a meta.yml for some arch)
built_names() {
  local d
  for d in "$PIM_DATA_HOME"/images/*/; do
    ls "$d"*/meta.yml >/dev/null 2>&1 && basename "$d"
  done
  return 0
}

# Builds (name/arch) whose meta.yml names <disk> as their parent disk
dependents_of_disk() {
  local f
  for f in "$PIM_DATA_HOME"/images/*/*/meta.yml; do
    [[ -f "$f" ]] || continue
    [[ "$(yq -r '.parent.disk // ""' "$f")" == "$1" ]] && echo "$(yq -r .name "$f")/$(yq -r .arch "$f")"
  done
  return 0
}

cmd_show() {
  [[ $# -gt 0 ]] || die "Usage: pim show <image>"
  local id name arch chain i f key
  id=$(canon_or_die "$1")
  name=$(img_name "$id")
  echo "$id"
  echo "  definition  $(tilde "$(img_dir "$id")")"
  chain=$(img_chain "$id" 2>/dev/null | paste -sd' ' - | sed 's/ / <- /g') || true
  [[ "$(img_chain "$id" 2>/dev/null | wc -l)" -gt 1 ]] && echo "  from        ${chain#* <- }"
  echo "  backend     $(img_backend "$id")"
  echo "  distro      $(img_distro "$id")"
  echo "  arch        $(img_arches "$id" | paste -sd, -)"
  echo "  user        $(img_user "$id")"
  for arch in arm64 amd64; do
    f=$(meta_file "$name" "$arch")
    [[ -f "$f" ]] || continue
    key=$(meta_get "$name" "$arch" .cache_key)
    echo "  build $arch"
    echo "    key       $key$( [[ "$(meta_get "$name" "$arch" .id)" == "$id" ]] || echo " (built from $(meta_get "$name" "$arch" .id))")"
    echo "    built     $(meta_get "$name" "$arch" .built_at)"
    if [[ "$(meta_get "$name" "$arch" .backend)" == tart ]]; then
      echo "    vm        $(meta_get "$name" "$arch" .disk) (tart)"
    else
      echo "    disk      $(tilde "$(meta_dir "$name" "$arch")/$key.qcow2") ($(file_size "$(meta_dir "$name" "$arch")/$key.qcow2"))"
    fi
    [[ "$(meta_get "$name" "$arch" .verified_key)" == "$key" ]] && echo "    verified  yes" || echo "    verified  no"
    [[ -n "$(meta_get "$name" "$arch" .parent.id)" ]] && echo "    parent    $(meta_get "$name" "$arch" .parent.id) ($(meta_get "$name" "$arch" .parent.cache_key))"
    if current=$(build_key "$id" "$arch" 2>/dev/null) && [[ "$current" != "$key" ]]; then
      echo "    stale     the definition changed since (pim build $name)"
    fi
  done
  if [[ -d "$PIM_DATA_HOME/vms/$name" ]]; then
    echo "  vm          $(tilde "$PIM_DATA_HOME/vms/$name")$(vm_running "$name" && echo " (running, ssh 127.0.0.1:$(cat "$(run_dir "$name")/port"))")"
  fi
}

# `pim rm [-y] [-f] <image>...`: stop and delete the VM and every build; the definition stays
cmd_rm() {
  local yes=false force=false arg name d dep
  local -a names=()
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) yes=true ;;
      -f|--force) force=true ;;
      -*) die "rm: unknown option '$arg'" ;;
      *) names+=("$(img_name "$(canon "$arg" || echo "x/$arg")")") ;;
    esac
  done
  [[ ${#names[@]} -gt 0 ]] || die "Usage: pim rm [-y] [-f] <image>..."
  for name in "${names[@]}"; do
    for d in "$PIM_DATA_HOME/images/$name"/*/*.qcow2; do
      [[ -f "$d" ]] || continue
      for dep in $(dependents_of_disk "$d"); do
        [[ "${dep%%/*}" == "$name" ]] && continue
        $force || die "$dep is built on $name; rm it first, or pass -f"
      done
    done
  done
  $yes || confirm "rm deletes VMs and builds" "Delete the VM and builds of ${names[*]}?"
  for name in "${names[@]}"; do
    vm_running "$name" && vm_stop "$name"
    case "$(meta_get "$name" "$(host_arch)" .backend)" in tart) tart_rm "$name" ;; esac
    rm -rf "${PIM_DATA_HOME:?}/vms/$name" "${PIM_DATA_HOME:?}/images/$name" "$(run_dir "$name")" \
      "${PIM_DATA_HOME:?}/snapshots/$name"
    echo "Removed $name"
  done
}

# `pim clean [--isos]`: delete superseded build disks no other build is based on, stale build
# workspaces, and with --isos the ISO cache
cmd_clean() {
  local isos=false f dir key d freed=0
  [[ "${1:-}" == "--isos" ]] && isos=true
  for f in "$PIM_DATA_HOME"/images/*/*/meta.yml; do
    [[ -f "$f" ]] || continue
    dir=$(dirname "$f")
    key=$(yq -r .cache_key "$f")
    for d in "$dir"/*.qcow2 "$dir"/*.qcow2.part; do
      [[ -f "$d" && "$(basename "$d")" != "$key.qcow2" ]] || continue
      [[ -n "$(dependents_of_disk "$d")" ]] && continue
      echo "Deleting $(tilde "$d")"
      rm -f "$d" "${d%.qcow2}-efivars.fd"
      freed=$((freed + 1))
    done
  done
  for d in "$PIM_STATE_HOME"/build/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}pid" ]] && pid_alive "$(cat "${d}pid")" && continue
    rm -rf "$d"
  done
  if $isos && [[ -d "$(iso_dir)" ]]; then
    echo "Deleting $(tilde "$(iso_dir)")"
    rm -rf "$(iso_dir)"
  fi
  echo "Cleaned ($freed superseded disks)"
}
