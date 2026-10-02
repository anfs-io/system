#!/usr/bin/env bash
# pim library: implode — stop every VM and delete everything pim created. Sourced by
# ~/.local/bin/pim; functions only.

cmd_implode() {
  local yes=false d dir
  [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && yes=true
  {
    echo "pim implode removes:"
    for d in "$PIM_STATE_HOME"/run/*/; do
      [[ -d "$d" ]] && vm_running "$(basename "$d")" && echo "  vm           $(basename "$d") (stopped first)"
    done
    command -v tart >/dev/null 2>&1 && [[ -d "$PIM_DATA_HOME/tart" ]] && echo "  tart vms     pim's, in $(tilde "$PIM_DATA_HOME/tart")"
    for dir in "$PIM_DATA_HOME" "$PIM_STATE_HOME" "$PIM_CACHE_HOME" "$PIM_CONFIG_HOME"; do
      [[ -e "$dir" ]] && echo "  directory    $(tilde "$dir")"
    done
  }
  $yes || confirm "implode deletes every pim VM, build and definition in $(tilde "$PIM_IMAGES_HOME")" "Implode pim?"
  for d in "$PIM_STATE_HOME"/run/*/; do
    [[ -d "$d" ]] && vm_running "$(basename "$d")" && vm_stop "$(basename "$d")"
  done
  declare -F tart_implode >/dev/null && tart_implode
  for dir in "$PIM_DATA_HOME" "$PIM_STATE_HOME" "$PIM_CACHE_HOME" "$PIM_CONFIG_HOME" "/tmp/pim-$(id -u)"; do
    [[ -e "$dir" ]] || continue
    chmod -R u+w "$dir" 2>/dev/null || true
    rm -rf "${dir:?}"
  done
  echo "pim imploded"
}
