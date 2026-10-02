#!/usr/bin/env bash
# anfs: where everything lives, and the toolkit's configuration. The one place that sets ANFS_*
# and each tool's <TOOL>_{CONFIG,DATA,STATE,CACHE}_HOME, so no tool resolves XDG on its own.
#
# Like everything in lib/anfs/ (the libraries every tool sources): functions and variables only,
# nothing from any tool, bash 3.2-safe under `set -euo pipefail`.
#
# Every tool, anfs included, gets <dir>/<tool> and nothing else:
#   ~/.local/bin/<tool>                 the commands
#   ~/.local/lib/<tool>/                their libraries; lib/anfs is this directory
#   ~/.config/anfs/{system,user}.list   the source lists (anfs src)
#   ~/.config/anfs/anfs{,.local}.conf   the toolkit's settings (anfs_load_conf)
#   ~/.local/share/anfs/sources/<alias> one clone per source; each tool reads its own top-level
#                                       dir from it (packages/ containers/ skills/ spaces/)
#   ~/.cache/anfs/updated/<alias>       each source's last clone or pull
#   ~/.local/state/anfs/bootstrap       what install.sh found on the machine and what it added
#   $XDG_{CONFIG,DATA,STATE,CACHE}_HOME/<tool>  each tool's own files

# An XDG variable that is set but empty counts as unset
[[ -n "${XDG_CONFIG_HOME:-}" ]] || XDG_CONFIG_HOME="$HOME/.config"
[[ -n "${XDG_DATA_HOME:-}" ]]   || XDG_DATA_HOME="$HOME/.local/share"
[[ -n "${XDG_STATE_HOME:-}" ]]  || XDG_STATE_HOME="$HOME/.local/state"
[[ -n "${XDG_CACHE_HOME:-}" ]]  || XDG_CACHE_HOME="$HOME/.cache"

: "${ANFS_CONFIG_HOME:=$XDG_CONFIG_HOME/anfs}"
: "${ANFS_DATA_HOME:=$XDG_DATA_HOME/anfs}"
: "${ANFS_CACHE_HOME:=$XDG_CACHE_HOME/anfs}"
: "${ANFS_STATE_HOME:=$XDG_STATE_HOME/anfs}"
ANFS_SOURCES_HOME="$ANFS_DATA_HOME/sources"
ANFS_USER_LIST="$ANFS_CONFIG_HOME/user.list"
ANFS_SYSTEM_LIST="$ANFS_CONFIG_HOME/system.list"
ANFS_LIB_DIR="$HOME/.local/lib/anfs"
ANFS_BIN_DIR="$HOME/.local/bin"
# What install.sh found and what it added (Homebrew, base formulas, ...), for anfs implode --all
ANFS_BOOTSTRAP_RECORD="$ANFS_STATE_HOME/bootstrap"
ANFS_CONF="$ANFS_CONFIG_HOME/anfs.conf"
ANFS_LOCAL_CONF="$ANFS_CONFIG_HOME/anfs.local.conf"

# The tools, in install order: ppm brings the software the others run on, pim's images build after
# the quick container installs, and wsm's spaces come last. Implode runs them in reverse.
ANFS_TOOLS="ppm pcm pim psm wsm"

# The top-level directory of a source each tool reads
anfs_tool_dir() {
  case "$1" in
    ppm) echo packages ;;
    pcm) echo containers ;;
    pim) echo images ;;
    psm) echo skills ;;
    wsm) echo spaces ;;
    *) return 1 ;;
  esac
}

# Set <TOOL>_CONFIG_HOME, _DATA_HOME, _STATE_HOME and _CACHE_HOME, keeping values already set
# Usage: anfs_tool_paths <tool>
anfs_tool_paths() {
  local tool="$1" upper var kind base
  upper=$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')
  for kind in CONFIG DATA STATE CACHE; do
    var="${upper}_${kind}_HOME"
    [[ -n "${!var:-}" ]] && continue
    case "$kind" in
      CONFIG) base="$XDG_CONFIG_HOME" ;;
      DATA)   base="$XDG_DATA_HOME" ;;
      STATE)  base="$XDG_STATE_HOME" ;;
      CACHE)  base="$XDG_CACHE_HOME" ;;
    esac
    printf -v "$var" '%s' "$base/$tool"
  done
}

# Export the settings in anfs.local.conf, then anfs.conf, each only where nothing has set it yet:
# the environment wins over this machine's file, which wins over the shipped one. Lines are
# NAME=value (comments and blanks skipped); a value may be single- or double-quoted. Read, not
# sourced, so a setting can never run code or clobber a variable a tool already set.
anfs_load_conf() {
  local file line name value
  for file in "$ANFS_LOCAL_CONF" "$ANFS_CONF"; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ -z "$line" || "$line" == \#* ]] && continue
      [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
      name="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
      [[ -n "${!name+x}" ]] && continue
      export "$name=$value"
    done < "$file"
  done
}
anfs_load_conf
