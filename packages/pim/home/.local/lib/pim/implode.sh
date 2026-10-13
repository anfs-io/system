#!/usr/bin/env bash
# pim library: implode — delete everything pim created. Sourced by ~/.local/bin/pim; functions
# only. Machines are pmm's, and `anfs implode` runs pmm's implode before this one.

cmd_implode() {
  local yes=${CLI_OPT[yes]:-false} dir
  {
    echo "pim implode removes:"
    command -v tart >/dev/null 2>&1 && [[ -d "${TART_HOME:-$HOME/.tart}" ]] && echo "  tart vms     pim's builds, in tart's store"
    for dir in "$PIM_DATA_HOME" "$PIM_STATE_HOME" "$PIM_CACHE_HOME" "$PIM_CONFIG_HOME"; do
      [[ -e "$dir" ]] && echo "  directory    $(tilde "$dir")"
    done
  }
  $yes || confirm "implode deletes every pim build and definition in $(tilde "$PIM_IMAGES_HOME")" "Implode pim?"
  declare -F tart_implode >/dev/null && tart_implode
  for dir in "$PIM_DATA_HOME" "$PIM_STATE_HOME" "$PIM_CACHE_HOME" "$PIM_CONFIG_HOME" "/tmp/pim-$(id -u)"; do
    [[ -e "$dir" ]] || continue
    chmod -R u+w "$dir" 2>/dev/null || true
    rm -rf "${dir:?}"
  done
  echo "pim imploded"
}
