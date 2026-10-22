#!/usr/bin/env bash

pre_install() {
  local cyan='\033[0;36m' nc='\033[0m'
  echo -e "${cyan}"
  cat << "EOF2"
 ____  __  __ __  __
|  _ \|  \/  |  \/  |
| |_) | |\/| | |\/| |
|  __/| |  | | |  | |
|_|   |_|  |_|_|  |_|

EOF2
  echo -e "${cyan}Personal Machine Manager${nc}"
}

# Refuse removal while machines run (override with ppm remove -f)
pre_remove() {
  local run="${XDG_STATE_HOME:-$HOME/.local/state}/pmm/run" dir running=""
  for dir in "$run"/*/; do
    [[ -f "${dir}pid" ]] && kill -0 "$(cat "${dir}pid")" 2>/dev/null && running+=" $(basename "$dir")"
  done
  [[ -z "$running" ]] && return 0
  echo "pmm has running machines:$running"
  echo "Stop them first (pmm down <machine>) or pass -f to remove anyway."
  return 1
}
