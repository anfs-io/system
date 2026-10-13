#!/usr/bin/env bash
# pmm library: what a machine is made of — its machine.yml, profiles, what it needs to know of its
# image, and the record of what it was created from. Sourced by ~/.local/bin/pmm; functions only.

# --- the definition -----------------------------------------------------------------------------

PMM_KEYS="image media profile cpus memory disk shares ports interfaces user arch description"

mach_yml() { echo "$(mach_def_dir "$1")/machine.yml"; }

# A scalar from machine.yml, or <default> when it is missing or null
# Usage: mach_get <id> <yq path> [default]
mach_get() {
  local v
  v=$(yq -r "($2) | select(. != null)" "$(mach_yml "$1")" 2>/dev/null) || v=""
  [[ -n "$v" ]] && echo "$v" || echo "${3:-}"
}

# A list from machine.yml, one item per line (a scalar is a one-item list)
mach_list() {
  yq -r "[($2)] | flatten | .[] | select(. != null)" "$(mach_yml "$1")" 2>/dev/null || true
}

# A share as written, with ~ and ${ANFS_SOURCES_HOME} expanded
share_expand() {
  local s="${1/\$\{ANFS_SOURCES_HOME\}/$ANFS_SOURCES_HOME}"
  [[ "$s" != "~"* ]] || s="$HOME${s#\~}"
  echo "$s"
}

# 8G -> 8192, 512M -> 512, 2048 -> 2048 (MB); fails on anything else
size_mb() {
  case "$1" in
    *[!0-9GM]*|"") return 1 ;;
  esac
  if [[ "$1" =~ ^([0-9]+)G$ ]]; then echo $(( BASH_REMATCH[1] * 1024 ))
  elif [[ "$1" =~ ^([0-9]+)M?$ ]]; then echo "${BASH_REMATCH[1]}"
  else return 1
  fi
}

# --- profiles -----------------------------------------------------------------------------------
# machines/profiles.yml in each source (and in $PMM_MACHINES_HOME): a map of name to
# {cpus, memory, disk}. The first source in priority order that has the name is the profile.

profile_file() {
  local i f
  for i in "${!SRC_DIRS[@]}"; do
    f="${SRC_DIRS[$i]}/profiles.yml"
    [[ -f "$f" ]] || continue
    [[ "$(P="$1" yq -r 'has(strenv(P))' "$f" 2>/dev/null)" == true ]] && { echo "$f"; return 0; }
  done
  return 1
}

# Usage: profile_get <profile> <cpus|memory|disk>
profile_get() {
  local f
  f=$(profile_file "$1") || return 0
  P="$1" K="$2" yq -r '.[strenv(P)][strenv(K)] | select(. != null)' "$f" 2>/dev/null || true
}

# --- the image ----------------------------------------------------------------------------------
# The machines' catalogue is the one loaded while a machine command runs, and there is one per
# process (lib/anfs/catalog.sh). So what a machine needs from its image is asked in a subshell
# that loads the images' catalogue, and comes back as text.

# The definition directory of <image>; fails when nothing defines it
image_def_dir() {
  ( load_images; id=$(canon "$1") && img_dir "$id" )
}

# A value from the image definition's machine: block, which a build never reads (it is left out
# of the build key). Nothing when the image is not defined here.
# Usage: image_machine_get <image> <yq path under .machine>
image_machine_get() {
  local dir
  dir=$(image_def_dir "$1" 2>/dev/null) || return 0
  yq -r "(.machine$2) | select(. != null)" "$dir/image.yml" 2>/dev/null || true
}

# The current build of <image> for <arch> (build_read, registry.sh). Sets B_NAME B_SOURCE B_KEY
# B_DISK B_BACKEND B_USER B_SSHKEY B_BOOT_USER B_BOOT_PW; fails when there is none.
image_build() {
  local -a v=()
  B_NAME="" B_SOURCE="" B_KEY="" B_DISK="" B_BACKEND="" B_USER="" B_SSHKEY="" B_BOOT_USER="" B_BOOT_PW=""
  mapfile -t v < <(
    load_images
    build_read "$(img_name "$(canon "$1" || echo "x/$1")")" "$2" 2>/dev/null || exit 0
    printf '%s\n' "$B_NAME" "${B_ID%%/*}" "$B_KEY" "$B_DISK" "$B_BACKEND" "$B_USER" "$B_SSHKEY" "$B_BOOT_USER" "$B_BOOT_PW")
  [[ ${#v[@]} -ge 9 ]] || return 1
  B_NAME="${v[0]}" B_SOURCE="${v[1]}" B_KEY="${v[2]}" B_DISK="${v[3]}" B_BACKEND="${v[4]}" B_USER="${v[5]}"
  B_SSHKEY="${v[6]}" B_BOOT_USER="${v[7]}" B_BOOT_PW="${v[8]}"
}

# Build <image> for <arch> unless its build is current (`pmm image build`, a no-op then)
image_ensure_built() {
  ( load_images; cli_call "image build" --arch "$2" "$1" )
}

# --- settings -----------------------------------------------------------------------------------

# The profile a definition gets: its own, else the one its image names
mach_profile() {
  local p
  p=$(mach_get "$1" .profile)
  [[ -n "$p" ]] || p=$(image_machine_get "$(mach_get "$1" .image)" .profile)
  echo "$p"
}

# cpus, memory or disk: the machine's own value, else its profile's; nothing when neither says
# Usage: mach_setting <id> <cpus|memory|disk>
mach_setting() {
  local v p
  v=$(mach_get "$1" ".$2")
  if [[ -z "$v" ]]; then
    p=$(mach_profile "$1")
    [[ -z "$p" ]] || v=$(profile_get "$p" "$2")
  fi
  echo "$v"
}

# --- the machine --------------------------------------------------------------------------------
# state.yml is what a machine was created from. Everything after create reads it, so a machine
# does not depend on its image's definition, or its own, still being there.

mdir()       { echo "$PMM_DATA_HOME/machines/$1"; }
state_file() { echo "$(mdir "$1")/state.yml"; }
run_dir()    { echo "$PMM_STATE_HOME/run/$1"; }
snap_dir()   { echo "$PMM_DATA_HOME/snapshots/$1"; }
tart_vm()    { echo "pmm-$1"; }

mach_exists() { [[ -f "$(state_file "$1")" ]]; }

state_get() {
  local f="${3:-$(state_file "$1")}"
  [[ -f "$f" ]] || return 0
  yq -r "($2) | select(. != null)" "$f" 2>/dev/null || true
}

# Usage: state_write <file> <image id> <arch> <backend> <key> <base disk> <user> <sshkey> [boot user] [boot password]
state_write() {
  local f="$1"
  mkdir -p "$(dirname "$f")"
  IMAGE="$2" ARCH="$3" BACKEND="$4" KEY="$5" DISK="$6" USER_="$7" SSHKEY="$8" BU="${9:-}" BP="${10:-}" AT="$(now_iso)" \
    yq -n '.image = strenv(IMAGE) | .arch = strenv(ARCH) | .backend = strenv(BACKEND) | .key = strenv(KEY)
           | .base = strenv(DISK) | .user = strenv(USER_) | .sshkey = strenv(SSHKEY) | .created_at = strenv(AT)
           | .boot = (strenv(BU) | select(. != "") | {"user": ., "password": strenv(BP)})' > "$f.tmp"
  chmod 600 "$f.tmp"
  mv "$f.tmp" "$f"
}

# The image a machine is on (once made), or the one its definition names
mach_image() {
  local v
  v=$(state_get "$1" .image)
  [[ -n "$v" || -z "${2:-}" ]] || v=$(mach_get "$2" .image)
  echo "$v"
}

# The image's name in a machine's record: `source/name` -> name
state_image_name() { local v; v=$(state_get "$1" .image); echo "${v#*/}"; }
