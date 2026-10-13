#!/usr/bin/env bash
# pmm library: what a machine is made of — its machine.yml, profiles, what pim says about its
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

# --- the image, which is pim's ------------------------------------------------------------------

pim_cli() { "$PMM_PIM" "$@"; }

# A value from the image definition's machine: block, which pim carries and never reads (as ppm
# does a package's meta:). Nothing when the image is not defined here.
# Usage: image_machine_get <image> <yq path under .machine>
image_machine_get() {
  local dir
  dir=$(pim_cli path "$1" 2>/dev/null) || return 0
  yq -r "(.machine$2) | select(. != null)" "$dir/image.yml" 2>/dev/null || true
}

# The current build of <image> for <arch>, from `pim builds --json`. Sets B_NAME B_SOURCE B_KEY
# B_DISK B_BACKEND B_USER B_SSHKEY B_BOOT_USER B_BOOT_PW; fails when there is none.
image_build() {
  local image="$1" arch="$2" json line
  B_NAME="" B_SOURCE="" B_KEY="" B_DISK="" B_BACKEND="" B_USER="" B_SSHKEY="" B_BOOT_USER="" B_BOOT_PW=""
  json=$(pim_cli builds --json "$image" 2>/dev/null) || return 1
  line=$(A="$arch" yq -p json -o tsv -r \
    '.[] | select(.arch == strenv(A)) | [.name, .source, .key, .disk, .backend, .user, .sshkey // "-", .boot_user // "-", .boot_password // "-"]' <<< "$json" 2>/dev/null | head -n1)
  [[ -n "$line" ]] || return 1
  IFS=$'\t' read -r B_NAME B_SOURCE B_KEY B_DISK B_BACKEND B_USER B_SSHKEY B_BOOT_USER B_BOOT_PW <<< "$line"
  [[ "$B_SSHKEY" != - ]] || B_SSHKEY=""
  [[ "$B_BOOT_USER" != - ]] || B_BOOT_USER=""
  [[ "$B_BOOT_PW" != - ]] || B_BOOT_PW=""
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

# The pim image name in a machine's record: `source/name` -> name
state_image_name() { local v; v=$(state_get "$1" .image); echo "${v#*/}"; }

mach_holder() { echo "pmm:$1${2:+@$2}"; }

# Hold or release the build a qemu machine (or one of its snapshots) is an overlay on. pim's
# record, by pim's command: pmm writes nothing in pim's directories.
# Usage: mach_hold <hold|release> <name> <state file> [snapshot]
mach_hold() {
  local verb="$1" name="$2" f="$3" snap="${4:-}" image key
  [[ "$(state_get "$name" .backend "$f")" == qemu ]] || return 0
  image=$(state_get "$name" .image "$f") key=$(state_get "$name" .key "$f")
  [[ -n "$image" && -n "$key" ]] || return 0
  pim_cli "$verb" "${image#*/}" "$(state_get "$name" .arch "$f")" "$key" "$(mach_holder "$name" "$snap")" 2>/dev/null ||
    { [[ "$verb" == release ]] || warn "could not hold $image's build $key for $name: pim clean may delete it"; }
}
