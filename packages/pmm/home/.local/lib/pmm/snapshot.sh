#!/usr/bin/env bash
# pmm library: snapshots of a machine, and reset. Sourced by ~/.local/bin/pmm; functions only.
#
# A qemu snapshot is a copy of the machine's disk, its UEFI vars and its record, in
# $PMM_DATA_HOME/snapshots/<name>/<snapshot>/. The copy is still an overlay on the build the
# machine was on, so each snapshot holds that build too (pmm:<name>@<snapshot>). A tart snapshot
# is a clone, pmm-<name>-snap-<snapshot>.

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

# `pmm snapshot <machine> [name]`: save the machine's disk (shut down first, restarted after); no
# name lists the snapshots
cmd_snapshot() {
  local name snap="${2:-}" was=false d s vm
  mach_find "$1"
  name="$M_NAME"
  if [[ -z "$snap" ]]; then
    mach_snapshots "$name"
    return 0
  fi
  snap_ok "$snap" || die "snapshot names are lowercase letters, digits, . _ -"
  mach_exists "$name" || die "$name is not made yet (pmm up $name)"
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
    [[ ! -d "$s" ]] || mach_hold release "$name" "$s/state.yml" "$snap"
    rm -rf "$s"
    mkdir -p "$s"
    cp "$d/disk.qcow2" "$d/state.yml" "$s/"
    [[ ! -f "$d/efivars.fd" ]] || cp "$d/efivars.fd" "$s/"
    mach_hold hold "$name" "$s/state.yml" "$snap"
  fi
  echo "Saved snapshot $snap of $name (pmm reset $name $snap)"
  ! $was || cli_call up "$name"
}

# `pmm reset [-y] <machine> [snapshot]`: recreate the machine from a snapshot, or from its
# image's current build
cmd_reset() {
  local name id snap="${2:-}" was=false d s vm
  mach_find "$1"
  name="$M_NAME" id="$M_ID"
  [[ -z "$snap" ]] || grep -qx "$snap" <<< "$(mach_snapshots "$name")" || die "$name has no snapshot '$snap' (pmm snapshot $name)"
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
    mach_exists "$name" && mach_hold release "$name" "$d/state.yml"
    rm -rf "$d"
    mkdir -p "$d"
    cp "$s/disk.qcow2" "$s/state.yml" "$d/"
    [[ ! -f "$s/efivars.fd" ]] || cp "$s/efivars.fd" "$d/"
    mach_hold hold "$name" "$d/state.yml"
  else
    mach_exists "$name" && mach_hold release "$name" "$(state_file "$name")"
    machine_create "$name" "$id"
  fi
  echo "Reset $name${snap:+ to $snap}"
  ! $was || cli_call up "$name"
}
