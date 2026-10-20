#!/usr/bin/env bash
# pmm library: snapshots of a machine, and reset. Sourced by ~/.local/bin/pmm; functions only.
#
# A qemu snapshot is a copy of the machine's disk, its UEFI vars and its record, in
# $PMM_DATA_HOME/snapshots/<name>/<snapshot>/. The copy is still an overlay on the build the
# machine was on, and its copy of the record says which: that keeps the build (holders_of,
# registry.sh, lists it as <name>@<snapshot>). A tart snapshot is a clone,
# pmm-<name>-snap-<snapshot>.

snap_ok() { [[ "$1" =~ ^[a-z0-9][a-z0-9_.-]*$ ]]; }

# The snapshots of <name>, one per line
mach_snapshots() {
  local d
  if [[ "$(state_get "$1" .backend)" == tart ]]; then
    command -v tart >/dev/null 2>&1 || return 0
    _tart_names | sed -n "s/^$(tart_vm "$1")-snap-//p" || true
    return 0
  fi
  for d in "$(snap_dir "$1")"/*/; do
    [[ -f "${d}disk.qcow2" ]] && basename "$d"
  done
  return 0
}

# `pmm snapshot list <machine>`: NAME BUILD (the build the snapshot is on; a tart one has none)
cmd_snapshot_list() {
  local name snap
  mach_find "$1"
  name="$M_NAME"
  while IFS= read -r snap; do
    [[ -n "$snap" ]] || continue
    anfs_row "$snap" "$(state_get "$name" .key "$(snap_dir "$name")/$snap/state.yml")"
  done < <(mach_snapshots "$name") | anfs_table "NAME BUILD" "name build"
}

# `pmm snapshot create <machine> [name]`: save the machine's disk (shut down first, restarted
# after). With no name it is named for the time.
cmd_snapshot_create() {
  local name snap="${2:-}" was=false d s vm
  mach_find "$1"
  name="$M_NAME"
  [[ -n "$snap" ]] || snap=$(date +%Y%m%d-%H%M%S)
  snap_ok "$snap" || die "snapshot names are lowercase letters, digits, . _ -"
  mach_exists "$name" || die "$name is not made yet (pmm up $name)"
  [[ ! -d "$(snap_dir "$name")/$snap" ]] || confirm "snapshot $snap of $name exists; this replaces it" "Replace snapshot $snap?"
  mach_running "$name" && { was=true; mach_stop "$name"; }
  if [[ "$(state_get "$name" .backend)" == tart ]]; then
    vm=$(tart_vm "$name")
    tart delete "$vm-snap-$snap" >/dev/null 2>&1 || true
    tart clone "$vm" "$vm-snap-$snap"
    # Recreated from the snapshot rather than restarted: a restarted original has been seen to
    # come back without the writes the clone captured
    if $was; then
      tart delete "$vm" >/dev/null
      tart clone "$vm-snap-$snap" "$vm"
    fi
  else
    d=$(mdir "$name") s="$(snap_dir "$name")/$snap"
    rm -rf "$s"
    mkdir -p "$s"
    cp "$d/disk.qcow2" "$d/state.yml" "$s/"
    [[ ! -f "$d/efivars.fd" ]] || cp "$d/efivars.fd" "$s/"
  fi
  echo "Saved snapshot $snap of $name (pmm reset $name $snap)"
  ! $was || cli_call up "$name"
}

# `pmm snapshot remove [-y] <machine> <snapshot>`: delete one; with it goes what it kept of its
# image's build
cmd_snapshot_remove() {
  local name snap="$2"
  mach_find "$1"
  name="$M_NAME"
  grep -qx "$snap" <<< "$(mach_snapshots "$name")" || die "$name has no snapshot '$snap' (pmm snapshot list $name)"
  confirm "remove deletes the snapshot" "Delete $name's snapshot $snap?"
  if [[ "$(state_get "$name" .backend)" == tart ]]; then
    tart delete "$(tart_vm "$name")-snap-$snap" >/dev/null 2>&1 || true
  else
    rm -rf "$(snap_dir "$name")/$snap"
    rmdir "$(snap_dir "$name")" 2>/dev/null || true
  fi
  echo "Removed snapshot $snap of $name"
}

# `pmm reset [-y] <machine> [snapshot]`: recreate the machine from a snapshot, or from its
# image's current build
cmd_reset() {
  local name id snap="${2:-}" was=false d s vm
  mach_find "$1"
  name="$M_NAME" id="$M_ID"
  [[ -z "$snap" ]] || grep -qx "$snap" <<< "$(mach_snapshots "$name")" || die "$name has no snapshot '$snap' (pmm snapshot list $name)"
  [[ -n "$snap" || -n "$id" ]] || die "$name's definition is gone: it can only be reset to a snapshot"
  confirm "reset replaces the machine's disk" "Reset $name${snap:+ to $snap}?"
  mach_running "$name" && { was=true; mach_stop "$name"; }
  if [[ "$(state_get "$name" .backend)" == tart ]]; then
    vm=$(tart_vm "$name")
    if [[ -n "$snap" ]]; then
      tart delete "$vm" >/dev/null 2>&1 || true
      tart clone "$vm-snap-$snap" "$vm"
    else
      machine_create "$name" "$id"
    fi
  elif [[ -n "$snap" ]]; then
    d=$(mdir "$name") s="$(snap_dir "$name")/$snap"
    rm -rf "$d"
    mkdir -p "$d"
    cp "$s/disk.qcow2" "$s/state.yml" "$d/"
    [[ ! -f "$s/efivars.fd" ]] || cp "$s/efivars.fd" "$d/"
  else
    machine_create "$name" "$id"
  fi
  echo "Reset $name${snap:+ to $snap}"
  ! $was || cli_call up "$name"
}
