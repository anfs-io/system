#!/usr/bin/env bash
# pmm library: taking over the VMs pim used to run. Sourced by ~/.local/bin/pmm; functions only.
#
# Until machines were pmm's, pim ran one VM per image, named after it: its disk in
# $PIM_DATA_HOME/vms/<image>/, its snapshots in $PIM_DATA_HOME/snapshots/<image>/, a tart VM
# pim-<image>. Each becomes the machine <image>. Nothing is copied: disks are moved and tart VMs
# renamed. One that is running is shut down first, and said so. Run by the package's post_install
# and safe to run again: what is already a machine is left alone.

# A definition for a migrated machine, unless a source already defines the name: the image, and
# the machine settings its image.yml used to carry
_migrate_definition() {
  local name="$1" dir k
  local -a args=(image "$name")
  canon "$name" >/dev/null && return 0
  if dir=$(pim_cli path "$name" 2>/dev/null) && [[ -f "$dir/image.yml" ]]; then
    for k in cpus memory; do
      args+=("$k" "$(yq -r ".$k | select(. != null)" "$dir/image.yml" 2>/dev/null || true)")
    done
    while IFS= read -r k; do [[ -z "$k" ]] || args+=("shares[]" "$k"); done < <(yq -r '[.shares] | flatten | .[] | select(. != null)' "$dir/image.yml" 2>/dev/null || true)
    while IFS= read -r k; do [[ -z "$k" ]] || args+=("ports[]" "$k"); done < <(yq -r '[.ports] | flatten | .[] | select(. != null)' "$dir/image.yml" 2>/dev/null || true)
  fi
  def_write "$name" "${args[@]}"
  load_machines
}

_migrate_qemu() {
  local old="$PIM_DATA_HOME/vms" snaps="$PIM_DATA_HOME/snapshots" run="$PIM_STATE_HOME/run"
  local d name arch key base r f s sdir
  for d in "$old"/*/; do
    [[ -f "${d}disk.qcow2" ]] || continue
    name=$(basename "$d")
    if mach_exists "$name"; then
      warn "$name is already a machine; pim's old VM is left in $(tilde "$d")"
      continue
    fi
    arch=$(cat "${d}arch" 2>/dev/null || host_arch)
    if ! image_build "$name" "$arch"; then
      warn "pim has no $arch build of $name; its old VM is left in $(tilde "$d")"
      continue
    fi
    r="$run/$name"
    if [[ -f "$r/pid" ]] && pid_alive "$(cat "$r/pid")"; then
      echo "Stopping $name (it was running under pim; start it again with: pmm up $name)"
      qemu_stop "$(cat "$r/pid")" "$(sock_dir)/$name.qmp" ssh_poweroff "$(cat "$r/key")" "$(cat "$r/port")" "$(cat "$r/user")"
    fi
    rm -rf "$r" "$(sock_dir)/$name.qmp" "$(sock_dir)/$name.ga"

    # The disk stays an overlay on the build it was made from, which may not be the current one
    key=$(cat "${d}base" 2>/dev/null || echo "$B_KEY")
    base="$(dirname "$B_DISK")/$key.qcow2"
    _migrate_definition "$name"
    mkdir -p "$(mdir "$name")"
    mv "${d}disk.qcow2" "$(mdir "$name")/disk.qcow2"
    [[ ! -f "${d}efivars.fd" ]] || mv "${d}efivars.fd" "$(mdir "$name")/efivars.fd"
    state_write "$(state_file "$name")" "$B_SOURCE/$B_NAME" "$arch" qemu "$key" "$base" "$B_USER" "$B_SSHKEY"
    mach_hold hold "$name" "$(state_file "$name")"
    rm -rf "$d"

    for f in "$snaps/$name"/*.qcow2; do
      [[ -f "$f" ]] || continue
      s=$(basename "$f" .qcow2)
      sdir="$(snap_dir "$name")/$s"
      mkdir -p "$sdir"
      mv "$f" "$sdir/disk.qcow2"
      [[ ! -f "$snaps/$name/$s-efivars.fd" ]] || mv "$snaps/$name/$s-efivars.fd" "$sdir/efivars.fd"
      key=$(cat "$snaps/$name/base" 2>/dev/null || state_get "$name" .key)
      state_write "$sdir/state.yml" "$B_SOURCE/$B_NAME" "$arch" qemu "$key" "$(dirname "$B_DISK")/$key.qcow2" "$B_USER" "$B_SSHKEY"
      mach_hold hold "$name" "$sdir/state.yml" "$s"
    done
    rm -rf "${snaps:?}/$name"
    echo "Migrated $name from pim ($(mach_snapshots "$name" | wc -l | tr -d ' ') snapshots)"
  done
  rmdir "$old" "$snaps" "$run" 2>/dev/null || true
}

_migrate_tart() {
  [[ "$(host_os)" == darwin ]] && command -v tart >/dev/null 2>&1 || return 0
  [[ -d "${TART_HOME:-$HOME/.tart}" ]] || return 0
  local vm name r ip s run="$PIM_STATE_HOME/run"
  while IFS= read -r vm; do
    # pim-<image> only: not a build (-<16 hex>), a build in progress, a verify copy or a snapshot
    [[ "$vm" =~ ^pim-(.+)$ ]] || continue
    name="${BASH_REMATCH[1]}"
    [[ ! "$name" =~ -([0-9a-f]{16}|building|verify)$ && "$name" != *-snap-* ]] || continue
    if tart_exists "$(tart_vm "$name")"; then
      warn "$name is already a machine; pim's old VM $vm is left in tart's store"
      continue
    fi
    if ! image_build "$name" arm64; then
      warn "pim has no build of $name; its old VM $vm is left in tart's store"
      continue
    fi
    r="$run/$name"
    if [[ "$(_tart_state "$vm")" == running ]]; then
      echo "Stopping $name (it was running under pim; start it again with: pmm up $name)"
      BOOT_USER="$B_BOOT_USER" BOOT_PW="$B_BOOT_PW"
      if [[ -f "$r/pid" ]] && pid_alive "$(cat "$r/pid")" && ip=$(tart ip "$vm" --wait 10 2>/dev/null); then
        _tart_shutdown "$vm" "$(cat "$r/pid")" "$B_SSHKEY" "$ip"
      else
        tart stop "$vm" >/dev/null 2>&1 || true
      fi
    fi
    rm -rf "$r"
    _migrate_definition "$name"
    tart rename "$vm" "$(tart_vm "$name")"
    while IFS= read -r s; do
      [[ -z "$s" ]] || tart rename "$vm-snap-$s" "$(tart_vm "$name")-snap-$s"
    done < <(_tart_names | sed -n "s/^$vm-snap-//p")
    state_write "$(state_file "$name")" "$B_SOURCE/$B_NAME" arm64 tart "$B_KEY" "$B_DISK" "$B_USER" "$B_SSHKEY" "$B_BOOT_USER" "$B_BOOT_PW"
    echo "Migrated $name from pim ($(mach_snapshots "$name" | wc -l | tr -d ' ') snapshots)"
  done < <(_tart_names)
  rmdir "$run" 2>/dev/null || true
}

cmd_migrate() {
  _migrate_qemu
  _migrate_tart
}
