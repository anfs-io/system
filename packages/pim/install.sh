#!/usr/bin/env bash

pre_install() {
  local cyan='\033[0;36m' nc='\033[0m'
  echo -e "${cyan}"
  cat << "EOF2"
 ____ ___ __  __
|  _ \_ _|  \/  |
| |_) | || |\/| |
|  __/| || |  | |
|_|  |___|_|  |_|

EOF2
  echo -e "${cyan}Personal Image Manager${nc}"
}

post_install() {
  mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/pim/images"
}

# Refuse removal while pim VMs run (override with ppm remove -f)
pre_remove() {
  local run="${XDG_STATE_HOME:-$HOME/.local/state}/pim/run" dir running=""
  for dir in "$run"/*/; do
    [[ -f "${dir}pid" ]] && kill -0 "$(cat "${dir}pid")" 2>/dev/null && running+=" $(basename "$dir")"
  done
  [[ -z "$running" ]] && return 0
  echo "pim has running VMs:$running"
  echo "Stop them first (pim down <image>) or pass -f to remove anyway."
  return 1
}
