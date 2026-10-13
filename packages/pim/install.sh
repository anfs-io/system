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
