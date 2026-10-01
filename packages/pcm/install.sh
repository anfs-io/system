#!/usr/bin/env bash

pre_install() {
  local cyan='\033[0;36m' nc='\033[0m'
  echo -e "${cyan}"
  cat << "EOF"
 ____   ____ __  __
|  _ \ / ___|  \/  |
| |_) | |   | |\/| |
|  __/| |___| |  | |
|_|    \____|_|  |_|

EOF
  echo -e "${cyan}Personal Container Manager${nc}"
}

post_install() {
  local pcm_config="${XDG_CONFIG_HOME:-$HOME/.config}/pcm"
  local pcm_data="${XDG_DATA_HOME:-$HOME/.local/share}/pcm"

  # Create PCM config directory
  mkdir -p "$pcm_config/containers"

  # Create PCM data directory (sources are anfs's: anfs src update)
  mkdir -p "$pcm_data/volumes"
}

# Refuse removal while compose containers are running (override with ppm remove -f)
pre_remove() {
  command -v podman &>/dev/null || return 0
  local running
  running=$(podman ps --filter label=com.docker.compose.project --format '{{.Names}}' 2>/dev/null) || return 0
  [[ -z "$running" ]] && return 0
  echo "pcm has running containers:"
  printf '  %s\n' $running
  echo "Stop them first (pcm down <service>) or pass -f to remove anyway."
  return 1
}
