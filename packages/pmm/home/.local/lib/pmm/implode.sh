#!/usr/bin/env bash
# pmm library: implode — stop every machine and delete everything pmm created: machines, their
# snapshots, networks, image builds and keys. Sourced by ~/.local/bin/pmm; functions only.

cmd_implode() {
  local d dir name vm
  {
    echo "pmm implode removes:"
    for d in "$PMM_DATA_HOME"/machines/*/; do
      [[ -f "${d}state.yml" ]] || continue
      name=$(basename "$d")
      echo "  machine      $name$(mach_running "$name" && echo " (stopped first)")"
    done
    for d in "$PMM_DATA_HOME"/networks/*/; do
      [[ -f "${d}state.yml" ]] || continue
      echo "  network      $(basename "$d")"
    done
    for d in "$PMM_DATA_HOME"/images/*/; do
      [[ -d "$d" ]] && echo "  builds       $(basename "$d")"
    done
    command -v tart >/dev/null 2>&1 && [[ -d "${TART_HOME:-$HOME/.tart}" ]] && echo "  tart vms     pmm's machines and builds, in tart's store"
    for dir in "$PMM_DATA_HOME" "$PMM_STATE_HOME" "$PMM_CACHE_HOME" "$PMM_CONFIG_HOME"; do
      [[ -e "$dir" ]] && echo "  directory    $(tilde "$dir")"
    done
  }
  confirm "implode deletes every machine, snapshot and build, and every definition in $(tilde "$PMM_CONFIG_HOME")" "Implode pmm?"
  # each machine's own removal, so that what it reserved on a network goes with it
  for d in "$PMM_DATA_HOME"/machines/*/; do
    [[ -f "${d}state.yml" ]] || continue
    mach_delete "$(basename "$d")"
  done
  # networks after the machines that were on them
  for d in "$PMM_DATA_HOME"/networks/*/; do
    [[ -f "${d}state.yml" ]] || continue
    net_delete "$(basename "$d")"
  done
  [[ -z "$PMM_SSH_CONFIG" ]] || rm -f "$PMM_SSH_CONFIG"
  # tart creates its home on any command; a machine that never ran tart has none to clean
  if command -v tart >/dev/null 2>&1 && [[ -d "${TART_HOME:-$HOME/.tart}" ]]; then
    _tart_names | grep '^pmm-' | while read -r vm; do
      tart stop "$vm" >/dev/null 2>&1 || true
      tart delete "$vm" >/dev/null 2>&1 || true
    done || true
  fi
  local sock
  sock=$(sock_dir_path) || exit 1
  for dir in "$PMM_DATA_HOME" "$PMM_STATE_HOME" "$PMM_CACHE_HOME" "$PMM_CONFIG_HOME" "$sock"; do
    [[ -e "$dir" ]] || continue
    chmod -R u+w "$dir" 2>/dev/null || true
    rm -rf "${dir:?}"
  done
  echo "pmm imploded"
}
