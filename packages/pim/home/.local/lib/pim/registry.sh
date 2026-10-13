#!/usr/bin/env bash
# pim library: what has been built — each build's meta.yml; the show, builds, rm and clean
# commands, and the holds other tools put on a build.
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
    [[ -z "$(holders_of "$name" "$arch")" ]] || echo "    held by   $(holders_of "$name" "$arch" | paste -sd' ' -)"
    if current=$(build_key "$id" "$arch" 2>/dev/null) && [[ "$current" != "$key" ]]; then
      echo "    stale     the definition changed since (pim build $name)"
    fi
  done
}

# `pim rm [-y] [-f] <image>...`: delete every build; the definition stays. Machines are pmm's: a
# build one of them holds is refused like one another image is built on
cmd_remove() {
  local yes=${CLI_OPT[yes]:-false} force=${CLI_OPT[force]:-false} arg name d dep arch
  local -a names=()
  for arg in "$@"; do names+=("$(img_name "$(canon "$arg" || echo "x/$arg")")"); done
  for name in "${names[@]}"; do
    for d in "$PIM_DATA_HOME/images/$name"/*/*.qcow2; do
      [[ -f "$d" ]] || continue
      for dep in $(dependents_of_disk "$d"); do
        [[ "${dep%%/*}" == "$name" ]] && continue
        $force || die "$dep is built on $name; rm it first, or pass -f"
      done
    done
    for d in "$PIM_DATA_HOME/images/$name"/*/; do
      [[ -d "$d" ]] || continue
      arch=$(basename "$d")
      dep=$(holders_of "$name" "$arch" | paste -sd' ' -)
      [[ -z "$dep" ]] || $force || die "$name ($arch) is held by $dep; remove that first, or pass -f"
    done
  done
  $yes || confirm "rm deletes builds" "Delete the builds of ${names[*]}?"
  for name in "${names[@]}"; do
    case "$(meta_get "$name" "$(host_arch)" .backend)" in tart) tart_rm "$name" ;; esac
    rm -rf "${PIM_DATA_HOME:?}/images/$name"
    echo "Removed $name"
  done
}

# `pim clean [--isos]`: delete superseded build disks no other build is based on and nothing
# holds, stale build workspaces, and with --isos the ISOs the images name
cmd_clean() {
  local isos=${CLI_OPT[isos]:-false} f dir key d d_key freed=0
  for f in "$PIM_DATA_HOME"/images/*/*/meta.yml; do
    [[ -f "$f" ]] || continue
    dir=$(dirname "$f")
    key=$(yq -r .cache_key "$f")
    for d in "$dir"/*.qcow2 "$dir"/*.qcow2.part; do
      [[ -f "$d" && "$(basename "$d")" != "$key.qcow2" ]] || continue
      [[ -n "$(dependents_of_disk "$d")" ]] && continue
      d_key=$(basename "${d%%.qcow2*}")
      [[ -n "$(ls -A "$dir/holds/$d_key" 2>/dev/null)" ]] && continue
      echo "Deleting $(tilde "$d")"
      rm -f "$d" "${d%.qcow2}-efivars.fd"
      rm -rf "$dir/holds/$d_key"
      freed=$((freed + 1))
    done
  done
  for d in "$PIM_STATE_HOME"/build/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}pid" ]] && pid_alive "$(cat "${d}pid")" && continue
    rm -rf "$d"
  done
  # the store is shared (lib/anfs/iso.sh): only the ISOs an image names are pim's to delete
  if $isos; then
    while IFS= read -r f; do
      [[ -n "$f" && -f "$(iso_dir)/$f" ]] || continue
      echo "Deleting $(tilde "$(iso_dir)/$f")"
      rm -f "$(iso_dir)/$f" "$(iso_dir)/$f.sha256" "$(iso_dir)/$f.part"
    done < <(iso_names)
  fi
  echo "Cleaned ($freed superseded disks)"
}

# --- holds --------------------------------------------------------------------------------------
# A hold says something outside pim is based on a build: an empty file,
# images/<name>/<arch>/holds/<key>/<holder>. pim does not know who the holders are (pmm's machines
# and their snapshots are, as pmm:<machine>). clean keeps a held disk and remove refuses a held
# image, the same as for a build another image is an overlay on.

hold_dir() { echo "$(meta_dir "$1" "$2")/holds/$3"; }

# The holders of <name> <arch>'s builds (of one <key> when given), one per line
holders_of() {
  local f
  for f in "$(meta_dir "$1" "$2")"/holds/${3:-*}/*; do
    [[ -f "$f" ]] && basename "$f"
  done | sort -u
  return 0
}

_hold_args() {
  [[ $# -eq 4 ]] || cli_usage_err "usage: pim $HOLD_VERB <image> <arch> <key> <holder>"
  [[ "$4" =~ ^[a-z0-9][a-z0-9_.:@-]*$ ]] || die "holder '$4': lowercase letters, digits and . _ : @ -"
  HOLD_NAME=$(img_name "$(canon "$1" || echo "x/$1")")
  HOLD_ARCH=$(arch_norm "$2")
}

# `pim hold <image> <arch> <key> <holder>`: plumbing, for a tool whose things are based on a build
cmd_hold() {
  HOLD_VERB=hold _hold_args "$@"
  [[ -f "$(meta_dir "$HOLD_NAME" "$HOLD_ARCH")/$3.qcow2" ]] || die "$HOLD_NAME has no $HOLD_ARCH build $3"
  mkdir -p "$(hold_dir "$HOLD_NAME" "$HOLD_ARCH" "$3")"
  : > "$(hold_dir "$HOLD_NAME" "$HOLD_ARCH" "$3")/$4"
}

# `pim release <image> <arch> <key> <holder>`: drop a hold; one that is not there is not an error
cmd_release() {
  HOLD_VERB=release _hold_args "$@"
  rm -f "$(hold_dir "$HOLD_NAME" "$HOLD_ARCH" "$3")/$4"
  rmdir "$(hold_dir "$HOLD_NAME" "$HOLD_ARCH" "$3")" "$(meta_dir "$HOLD_NAME" "$HOLD_ARCH")/holds" 2>/dev/null || true
}

# `pim builds [image...]`: the current build of each image and arch, with what a tool that runs
# machines from it needs. Read with --json (lib/anfs/table.sh); the keys are the interface.
cmd_builds() {
  local f name arch backend key disk id root only=" " arg
  for arg in "$@"; do only+="$(img_name "$(canon "$arg" || echo "x/$arg")") "; done
  for f in "$PIM_DATA_HOME"/images/*/*/meta.yml; do
    [[ -f "$f" ]] || continue
    name=$(yq -r .name "$f") arch=$(yq -r .arch "$f")
    [[ "$only" == " " || "$only" == *" $name "* ]] || continue
    backend=$(yq -r .backend "$f") key=$(yq -r .cache_key "$f") id=$(yq -r .id "$f")
    local boot_user="" boot_pw="" sshkey=""
    if [[ "$backend" == tart ]]; then
      disk=$(yq -r .disk "$f")
      tart_exists "$disk" || continue
    else
      disk="$(dirname "$f")/$key.qcow2"
      [[ -f "$disk" ]] || continue
    fi
    # The key and the stock account are the root image's; a build whose definition is gone still
    # lists, without them
    if root=$(img_root "$id" 2>/dev/null) && [[ -n "$root" && -f "$(img_yml "$root")" ]]; then
      sshkey="$PIM_DATA_HOME/keys/$(img_name "$root")/id_ed25519"
      [[ "$backend" != tart ]] || { _tart_boot "$id"; boot_user="$BOOT_USER" boot_pw="$BOOT_PW"; }
    fi
    anfs_row "$name" "${id%%/*}" "$arch" "$backend" "$key" "$disk" "$(yq -r .user "$f")" "$sshkey" \
      "$(holders_of "$name" "$arch" "$key" | paste -sd' ' -)" "$boot_user" "$boot_pw"
  done | anfs_table "NAME SOURCE ARCH BACKEND KEY DISK USER SSHKEY HELD BOOT_USER BOOT_PASSWORD" \
    "name source arch backend key disk user sshkey held[] boot_user boot_password"
}
