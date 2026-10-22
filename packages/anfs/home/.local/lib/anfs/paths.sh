#!/usr/bin/env bash
# anfs: where everything lives, and the tools' settings. The one place that sets ANFS_* and each
# tool's <TOOL>_{CONFIG,DATA,STATE,CACHE}_HOME, so no tool resolves XDG on its own, and the one
# reader of the settings files (anfs_load_conf).
#
# Like everything in lib/anfs/ (the libraries every tool sources): functions and variables only,
# nothing from any tool, safe under `set -euo pipefail`. Written for the bash floor (5.2), which
# bash.sh guarantees: a tool sources that first.
#
# Every tool, anfs included, gets <dir>/<tool> and nothing else:
#   ~/.local/bin/<tool>                 the commands
#   ~/.local/lib/<tool>/                their libraries; lib/anfs is this directory
#   ~/.config/anfs/{system,user}.list   the source lists (anfs src)
#   ~/.config/<tool>/<tool>.env         a tool's settings, shipped (linked) by its package; anfs's
#                                       own (ANFS_*, HOMEBREW_*) are ~/.config/anfs/anfs.env
#   ~/.config/<tool>/<tool>.local.env   this machine's values (yours, never shipped)
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

# The tools, in install order: ppm brings the software the others run on, pmm's images build after
# the quick container installs, and wsm's spaces come last. Implode runs them in reverse.
ANFS_TOOLS="ppm pcm pmm psm wsm"

# The top-level directory of a source each tool reads: one tool, one directory. What a tool keeps
# below it is its own (pmm: machines/images/ and machines/networks/, and the order it installs them)
anfs_tool_dir() {
  case "$1" in
    ppm) echo packages ;;
    pcm) echo containers ;;
    pmm) echo machines ;;
    psm) echo skills ;;
    wsm) echo spaces ;;
    *) return 1 ;;
  esac
}

# The prefix of a tool's variables, into REPLY: pcm is PCM, rpi-imager RPI_IMAGER
_anfs_tool_upper() { REPLY="${1^^}"; REPLY="${REPLY//-/_}"; }

# Set <TOOL>_CONFIG_HOME, _DATA_HOME, _STATE_HOME and _CACHE_HOME, keeping values already set,
# then load the tool's settings (anfs_load_conf <tool>). A tool calls it once, after paths.sh.
# Usage: anfs_tool_paths <tool>
anfs_tool_paths() {
  local tool="$1" upper var kind base
  _anfs_tool_upper "$tool"; upper="$REPLY"
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
  anfs_load_conf "$tool"
}

# --- Settings -------------------------------------------------------------------------------------
# Each tool's settings are two files in its config directory, ${<TOOL>_CONFIG_HOME:-
# $XDG_CONFIG_HOME/<tool>} (anfs's: $ANFS_CONFIG_HOME):
#   <tool>.env        shipped by the tool's package (linked): every setting the tool reads, as a
#                     commented default (#NAME=value) with a line saying what it does; a line the
#                     package wants on is active (NAME=value)
#   <tool>.local.env  this machine's values, beside it: the person's, never shipped
# Precedence: the environment, then <tool>.local.env, then <tool>.env, then the tool's built-in
# default. A tool not installed has no files and contributes nothing.
#
# Format: NAME=value, one per line; blanks and # comments skipped; a leading `export ` allowed; one
# pair of matching quotes around the value stripped. The loader expands one thing: a value that is
# exactly ~, or starts with ~/, has that ~ replaced by $HOME (quoted or not). Nothing else: no
# $VAR, no ~user, no globbing, no ~ past the start. Read, never sourced: a setting cannot run code.
#
# The API (plan 02's `config` command and pcm's per-container settings build on it):
#   anfs_conf_files <tool>     the two paths, local first (they need not exist)
#   anfs_conf_read <file>      NAME<TAB>value per setting line, in file order, as written (~ kept);
#                              nothing exported
#   anfs_conf_expand <value>   the value as the loader exports it (~ and ~/ to $HOME), into REPLY
#   anfs_conf_env_only <name>  0 for a name only the environment may set (anfs_load_conf skips it)
#   anfs_load_conf [tool]      export the tool's settings (no tool, or anfs: anfs's own)

# Into REPLY: the config directory of a tool's settings
_anfs_conf_dir() {
  local var
  _anfs_tool_upper "$1"; var="${REPLY}_CONFIG_HOME"
  REPLY="${!var:-$XDG_CONFIG_HOME/$1}"
}

# Usage: anfs_conf_files <tool>   (anfs: ~/.config/anfs/anfs.local.env, ~/.config/anfs/anfs.env)
anfs_conf_files() {
  local tool="${1:-anfs}"
  _anfs_conf_dir "$tool"
  printf '%s\n' "$REPLY/$tool.local.env" "$REPLY/$tool.env"
}

# Names a settings file never sets: what locates the files and the trees (every *_HOME of the
# XDG kinds, which paths.sh and anfs_tool_paths set) and the job switch with its two paths
# (ANFS_WORK, ANFS_WORK_HOME, ANFS_WORK_TMP: read before any file is)
anfs_conf_env_only() {
  case "$1" in
    ANFS_WORK|ANFS_WORK_HOME|ANFS_WORK_TMP) return 0 ;;
    *_CONFIG_HOME|*_DATA_HOME|*_STATE_HOME|*_CACHE_HOME) return 0 ;;
  esac
  return 1
}

# Parse one settings file into _ANFS_CONF_NAMES and _ANFS_CONF_VALUES (no fork). A missing file
# is no lines; a line that is not NAME=value is skipped.
_anfs_conf_parse() {
  local line value
  _ANFS_CONF_NAMES=() _ANFS_CONF_VALUES=()
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^export[[:space:]]+(.*)$ ]] && line="${BASH_REMATCH[1]}"
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    value="${BASH_REMATCH[2]}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    _ANFS_CONF_NAMES+=("${BASH_REMATCH[1]}") _ANFS_CONF_VALUES+=("$value")
  done < "$1"
}

# A leading ~ (the whole value, or ~/...) to $HOME; nothing else. Into REPLY (no fork).
# Usage: anfs_conf_expand <value>
anfs_conf_expand() {
  case "$1" in
    "~")   REPLY="$HOME" ;;
    "~/"*) REPLY="$HOME/${1#\~/}" ;;
    *)     REPLY="$1" ;;
  esac
}

# Usage: anfs_conf_read <file>
anfs_conf_read() {
  local i
  _anfs_conf_parse "$1"
  for i in "${!_ANFS_CONF_NAMES[@]}"; do
    printf '%s\t%s\n' "${_ANFS_CONF_NAMES[$i]}" "${_ANFS_CONF_VALUES[$i]}"
  done
}

# Export a tool's settings: <tool>.local.env, then <tool>.env, each name only where nothing has
# set it yet, so the environment wins over this machine's file, which wins over the shipped one;
# a leading ~ expanded (anfs_conf_expand).
# paths.sh runs it for anfs when sourced; anfs_tool_paths <tool> for the tool. A second call loads
# nothing new. A line naming an environment-only variable is skipped with one warning.
# A package hook that needs its tool's setting calls it itself: hooks run inside ppm, which has
# loaded only anfs's and ppm's (stack/tailscale's TSM_AUTOJOIN: anfs_load_conf tsm).
# Usage: anfs_load_conf [tool]
anfs_load_conf() {
  local tool="${1:-anfs}" file name i
  _anfs_conf_dir "$tool"
  for file in "$REPLY/$tool.local.env" "$REPLY/$tool.env"; do
    _anfs_conf_parse "$file"
    for i in "${!_ANFS_CONF_NAMES[@]}"; do
      name="${_ANFS_CONF_NAMES[$i]}"
      if anfs_conf_env_only "$name"; then
        printf 'anfs: %s: %s is read from the environment only; the line is ignored\n' \
          "$(anfs_display "$file")" "$name" >&2
        continue
      fi
      [[ -n "${!name+x}" ]] && continue
      anfs_conf_expand "${_ANFS_CONF_VALUES[$i]}"
      export "$name=$REPLY"
    done
  done
}

# A path as a person reads it: the home directory is ~, whether the path spells it as $HOME or
# as what $HOME resolves to (the tools store canonical paths, and on some machines the two
# differ). For display only; what is stored is always whole.
ANFS_HOME_REAL=$(cd -P -- "$HOME" 2>/dev/null && pwd -P) || ANFS_HOME_REAL="$HOME"
anfs_display() {
  case "$1" in
    "$HOME"|"$ANFS_HOME_REAL") printf '~\n' ;;
    "$HOME"/*)           printf '~/%s\n' "${1#"$HOME"/}" ;;
    "$ANFS_HOME_REAL"/*) printf '~/%s\n' "${1#"$ANFS_HOME_REAL"/}" ;;
    *)                   printf '%s\n' "$1" ;;
  esac
}

# The canonical path of an existing directory: no symlinks, no dots. Returns 1 when there is none.
anfs_canon() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# anfs's own settings, for every tool (ANFS_*, HOMEBREW_*); the tool's own come with anfs_tool_paths
anfs_load_conf
