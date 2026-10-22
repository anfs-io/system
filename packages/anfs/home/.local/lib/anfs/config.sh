#!/usr/bin/env bash
# anfs: the `config` command group — a tool's settings, listed, read and set by the tool itself
#
# Every tool that ships ~/.config/<tool>/<tool>.env declares the group with one call, among its
# declarations and before cli_standard; the commands are the library's and act on $CLI_TOOL:
#
#   anfs_config_declare
#
#   <tool> config list [--export]    NAME VALUE FROM (--json: name, value, from, file)
#   <tool> config get NAME           the effective value; 1, nothing printed, when it has none
#   <tool> config set NAME=VALUE...  into <tool>.local.env
#   <tool> config unset NAME...      out of <tool>.local.env
#   anfs config list --all           every installed tool's, with a leading TOOL (key tool)
#
# The files are paths.sh's (anfs_conf_files): <tool>.env, shipped and linked by the package, and
# <tool>.local.env beside it, this machine's. A tool's settings are the names its shipped file
# has a line for, active (NAME=value) or commented (#NAME=value, no space after the #: a prose
# comment is not a setting); `get` and `set` refuse any other name (64). A name only in the
# local file is listed too, FROM local, so a stray line is seen (`unset` takes it away).
#
# FROM, the first that applies:
#   env      exported by the environment the tool started in: set, and not by anfs_load_conf
#            (paths.sh records what it exported in ANFS_CONF_LOADED). A tool run by another
#            inherits the parent's settings as environment, and then env is what they are.
#   local    a line in <tool>.local.env
#   shipped  an active line in <tool>.env
#   default  the commented line's value: the tool's documented built-in default
# VALUE is the effective value: a file's with its leading ~ expanded (anfs_conf_expand), as the
# tool gets it. FILE is the file it came from (the shipped one for default; none for env).
# anfs's list has ANFS_WORK when it is set (FROM env: never in a file).
#
# `list --all` is anfs's only: anfs, then each directory of $XDG_CONFIG_HOME holding
# <dir>/<dir>.env (a linked shipped file: an installed tool), and a tool whose
# <TOOL>_CONFIG_HOME the environment sets. It reads their files in this one process, for display:
# nothing of the other tool runs.
#
# `set` writes the line in place (or appends it; a missing file is created with a header line),
# single-quoting a value that is not plain; it refuses a single quote in a value (the reader strips
# one pair of quotes and has no escapes), a malformed name, ANFS_WORK and every *_HOME the reader
# ignores (anfs_conf_env_only). The file is replaced whole (a temp file beside it, then mv), so a
# reader never sees half of it. Nothing writes the shipped file: it is the package's.
#
# Like everything in lib/anfs/ but bash.sh: functions only, no tool's code, the bash floor (5.2).
# Needs paths.sh, log.sh, cli.sh and table.sh.

anfs_config_declare() {
  local t="$CLI_TOOL" all=()
  [[ "$t" != anfs ]] || all=(--opt "--all: Every installed tool's, with a TOOL column")
  cli_group config "Settings in ~/.config/$t: $t.local.env over $t.env (shipped), the environment over both"
  cli_cmd "config list" "Every setting: its value and where it is from (env, local, shipped,
default)" --alias ls \
    --opt "--export: As export lines for eval (what is from the environment left out)" \
    ${all[@]+"${all[@]}"}
  cli_cmd "config get" "Print a setting's value; exit 1 when it has none" --arg "setting"
  cli_cmd "config set" "Set settings in $t.local.env (NAME=VALUE)" --arg "assignment..."
  cli_cmd "config unset" "Take settings out of $t.local.env" --arg "setting..."
}

# --- Reading ----------------------------------------------------------------------------------

# A shipped file's settings, in file order: _CF_S_NAMES, and per name _CF_S_VALUE (as written,
# unquoted) and _CF_S_KIND (shipped: an active line; default: a commented one). An active line
# wins over a commented one of the same name; otherwise the first line of a name counts.
_anfs_config_shipped() {
  local line kind value name
  _CF_S_NAMES=()
  declare -gA _CF_S_VALUE=() _CF_S_KIND=()
  [[ -f "$1" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    kind=shipped
    if [[ "$line" == \#* ]]; then
      line="${line#\#}"
      kind=default
    else
      [[ "$line" =~ ^export[[:space:]]+(.*)$ ]] && line="${BASH_REMATCH[1]}"
    fi
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    if [[ -z "${_CF_S_KIND[$name]:-}" ]]; then
      _CF_S_NAMES+=("$name")
    elif [[ "${_CF_S_KIND[$name]}" == shipped || "$kind" == default ]]; then
      continue
    fi
    _CF_S_VALUE[$name]="$value" _CF_S_KIND[$name]="$kind"
  done < "$1"
}

# True when <name> came from the environment the tool started in: exported, and not by the loader
_anfs_config_from_env() {
  [[ -v $1 ]] || return 1
  local attrs="${!1@a}"
  [[ "$attrs" == *x* ]] || return 1
  [[ " $ANFS_CONF_LOADED " != *" $1 "* ]]
}

# One tool's rows into _CF_NAMES, _CF_VALUES, _CF_FROM, _CF_FILES, _CF_DECLARED (1: in the
# shipped file, or anfs's ANFS_WORK). Usage: _anfs_config_collect <tool>
_anfs_config_collect() {
  local tool="$1" dir shipped local_file name i
  local -a names=()
  local -A lv=()
  _CF_NAMES=() _CF_VALUES=() _CF_FROM=() _CF_FILES=() _CF_DECLARED=()
  _anfs_conf_dir "$tool"; dir="$REPLY"
  shipped="$dir/$tool.env" local_file="$dir/$tool.local.env"
  _anfs_config_shipped "$shipped"
  names=(${_CF_S_NAMES[@]+"${_CF_S_NAMES[@]}"})
  _anfs_conf_parse "$local_file"
  for i in "${!_ANFS_CONF_NAMES[@]}"; do
    name="${_ANFS_CONF_NAMES[$i]}"
    [[ -z "${lv[$name]+x}" ]] || continue
    lv[$name]="${_ANFS_CONF_VALUES[$i]}"
    [[ -n "${_CF_S_KIND[$name]:-}" ]] || names+=("$name")
  done
  for name in ${names[@]+"${names[@]}"}; do
    anfs_conf_env_only "$name" && continue   # the loader ignores such a line
    _CF_NAMES+=("$name")
    if [[ -n "${_CF_S_KIND[$name]:-}" ]]; then _CF_DECLARED+=(1); else _CF_DECLARED+=(""); fi
    if _anfs_config_from_env "$name"; then
      _CF_VALUES+=("${!name}") _CF_FROM+=(env) _CF_FILES+=("")
    elif [[ -n "${lv[$name]+x}" ]]; then
      anfs_conf_expand "${lv[$name]}"
      _CF_VALUES+=("$REPLY") _CF_FROM+=(local) _CF_FILES+=("$local_file")
    else
      anfs_conf_expand "${_CF_S_VALUE[$name]}"
      _CF_VALUES+=("$REPLY") _CF_FROM+=("${_CF_S_KIND[$name]}") _CF_FILES+=("$shipped")
    fi
  done
  # The job switch: shown, never read from a file (units/config.md, decision 3)
  if [[ "$tool" == anfs ]] && [[ -v ANFS_WORK ]]; then
    _CF_NAMES+=(ANFS_WORK) _CF_VALUES+=("$ANFS_WORK") _CF_FROM+=(env) _CF_FILES+=("") _CF_DECLARED+=(1)
  fi
}

# One row per setting a tool has: name, value, from, file. Usage: anfs_config_rows <tool>
anfs_config_rows() {
  local i
  _anfs_config_collect "$1"
  for i in "${!_CF_NAMES[@]}"; do
    anfs_row "${_CF_NAMES[$i]}" "${_CF_VALUES[$i]}" "${_CF_FROM[$i]}" "${_CF_FILES[$i]}"
  done
}

# The tools `list --all` shows, one per line: anfs, then each installed tool by name
_anfs_config_tools() {
  local d t v dir
  local -A seen=([anfs]=1)
  local -a more=()
  echo anfs
  for d in "$XDG_CONFIG_HOME"/*/; do
    t="${d%/}" t="${t##*/}"
    [[ -f "$d$t.env" && -z "${seen[$t]:-}" ]] || continue
    seen[$t]=1 more+=("$t")
  done
  # a tool whose files the environment moved elsewhere
  while IFS= read -r v; do
    [[ "$v" == *_CONFIG_HOME && "$v" != XDG_CONFIG_HOME && "$v" != ANFS_CONFIG_HOME ]] || continue
    t="${v%_CONFIG_HOME}" t="${t,,}"
    dir="${!v}"
    [[ -f "$dir/$t.env" ]] || { t="${t//_/-}"; [[ -f "$dir/$t.env" ]] || continue; }
    [[ -z "${seen[$t]:-}" ]] || continue
    seen[$t]=1 more+=("$t")
  done < <(compgen -e)
  for t in ${more[@]+"${more[@]}"}; do
    _anfs_conf_dir "$t"
    [[ -f "$REPLY/$t.env" ]] && echo "$t"
  done | LC_ALL=C sort
}

# A value as one shell word: 'value', a ' as '\''
_anfs_config_sq() {
  REPLY="'${1//\'/\'\\\'\'}'"
}

# --- The commands -------------------------------------------------------------------------------

cmd_config_list() {
  local export="${CLI_OPT[export]:-false}" all="${CLI_OPT[all]:-false}" t i
  local -a tools=("$CLI_TOOL")
  if $all; then mapfile -t tools < <(_anfs_config_tools); fi
  if $export; then
    for t in "${tools[@]}"; do
      _anfs_config_collect "$t"
      for i in "${!_CF_NAMES[@]}"; do
        [[ "${_CF_FROM[$i]}" != env ]] || continue
        # an empty default sets nothing: the tool's own default is the same, and unset stays unset
        [[ "${_CF_FROM[$i]}" != default || -n "${_CF_VALUES[$i]}" ]] || continue
        _anfs_config_sq "${_CF_VALUES[$i]}"
        printf 'export %s=%s\n' "${_CF_NAMES[$i]}" "$REPLY"
      done
    done
    return 0
  fi
  if $all; then
    for t in "${tools[@]}"; do
      _anfs_config_collect "$t"
      for i in "${!_CF_NAMES[@]}"; do
        anfs_row "$t" "${_CF_NAMES[$i]}" "${_CF_VALUES[$i]}" "${_CF_FROM[$i]}" "${_CF_FILES[$i]}"
      done
    done | anfs_table "TOOL NAME VALUE FROM" "tool name value from file"
    return 0
  fi
  anfs_config_rows "$CLI_TOOL" | anfs_table "NAME VALUE FROM" "name value from file"
}

# A usage error of the config group, as `<tool> config: <message>`, exit 64
_anfs_config_refuse() {
  local CLI_TOOL="$CLI_TOOL config"
  anfs_fail 64 "$@"
}

# The index of a declared setting in _CF_NAMES (after _anfs_config_collect), into REPLY; refused
# (64) when the tool does not declare it
_anfs_config_declared() {
  local i
  for i in "${!_CF_NAMES[@]}"; do
    [[ "${_CF_NAMES[$i]}" == "$1" && -n "${_CF_DECLARED[$i]}" ]] || continue
    REPLY="$i"
    return 0
  done
  _anfs_config_refuse "$1 is not a $CLI_TOOL setting ($CLI_TOOL config list)"
}

cmd_config_get() {
  _anfs_config_collect "$CLI_TOOL"
  if [[ "$1" == ANFS_WORK && "$CLI_TOOL" == anfs ]] && ! [[ -v ANFS_WORK ]]; then return 1; fi
  _anfs_config_declared "$1"
  # a documented default that is empty is no value
  [[ "${_CF_FROM[$REPLY]}" != default || -n "${_CF_VALUES[$REPLY]}" ]] || return 1
  printf '%s\n' "${_CF_VALUES[$REPLY]}"
}

# Refuse what no settings file may hold
_anfs_config_settable() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || _anfs_config_refuse "'$1' is not a setting's name"
  [[ "$1" != ANFS_WORK ]] ||
    _anfs_config_refuse "ANFS_WORK is read from the environment only: ANFS_WORK=<job> <tool> ... runs a job's tools"
  ! anfs_conf_env_only "$1" ||
    _anfs_config_refuse "$1 is read from the environment only: it says where the files are"
}

# The local file a write goes to, through a link to it, into REPLY
_anfs_config_target() {
  local file="$1" dir link
  while [[ -L "$file" ]]; do
    dir="${file%/*}"
    link=$(readlink -- "$file")
    [[ "$link" == /* ]] || link="$dir/$link"
    file="$link"
  done
  REPLY="$file"
}

# Rewrite <file>: each name in _CF_SET (name -> its line, or "" to drop it) replaces its first
# active line, later ones dropped; a name with a line and none in the file is appended, in
# _CF_ORDER. Names found go into _CF_FOUND. Atomic: a temp file beside it, then mv.
# Usage: _anfs_config_write <file> <header for a new file>
_anfs_config_write() {
  local file="$1" header="$2" dir line trimmed name tmp
  local -a out=()
  _CF_FOUND=()
  _anfs_config_target "$file"; file="$REPLY"
  dir="${file%/*}"
  mkdir -p "$dir"
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      trimmed="${line#"${line%%[![:space:]]*}"}"
      [[ "$trimmed" =~ ^export[[:space:]]+(.*)$ ]] && trimmed="${BASH_REMATCH[1]}"
      if [[ "$trimmed" =~ ^([A-Za-z_][A-Za-z0-9_]*)= && -n "${_CF_SET[${BASH_REMATCH[1]}]+x}" ]]; then
        name="${BASH_REMATCH[1]}"
        if [[ -z "${_CF_FOUND[$name]:-}" ]]; then
          _CF_FOUND[$name]=1
          [[ -z "${_CF_SET[$name]}" ]] || out+=("${_CF_SET[$name]}")
        fi
        continue
      fi
      out+=("$line")
    done < "$file"
  else
    out+=("$header")
  fi
  for name in ${_CF_ORDER[@]+"${_CF_ORDER[@]}"}; do
    [[ -n "${_CF_FOUND[$name]:-}" || -z "${_CF_SET[$name]}" ]] || out+=("${_CF_SET[$name]}")
  done
  tmp=$(mktemp "$dir/.${file##*/}.XXXXXX") || anfs_die "cannot write in $(anfs_display "$dir")"
  if [[ -f "$file" ]]; then
    cp -p -- "$file" "$tmp"
  else
    chmod "$(printf '%o' $(( 0666 & ~0$(umask) )))" "$tmp"
  fi
  if ! { printf '%s\n' ${out[@]+"${out[@]}"} > "$tmp" && mv -f -- "$tmp" "$file"; }; then
    rm -f -- "$tmp"
    anfs_die "could not write $(anfs_display "$file")"
  fi
}

cmd_config_set() {
  local arg name value file shown i
  local -a names=() values=()
  declare -gA _CF_SET=() _CF_FOUND=()
  _CF_ORDER=()
  _anfs_config_collect "$CLI_TOOL"
  for arg in "$@"; do
    [[ "$arg" == *=* ]] || _anfs_config_refuse "'$arg' is not NAME=VALUE"
    name="${arg%%=*}" value="${arg#*=}"
    _anfs_config_settable "$name"
    _anfs_config_declared "$name"
    [[ "$value" != *\'* ]] ||
      _anfs_config_refuse "$name: a value cannot hold a single quote (the file has no escapes)"
    [[ "$value" != *$'\n'* ]] || _anfs_config_refuse "$name: a value is one line"
    if [[ -z "$value" || "$value" =~ ^[A-Za-z0-9_./:@%+,=~-]+$ ]]; then
      _CF_SET[$name]="$name=$value"
    else
      _CF_SET[$name]="$name='$value'"
    fi
    [[ -n "${_CF_FOUND[$name]:-}" ]] || _CF_ORDER+=("$name")
    _CF_FOUND[$name]=1
    names+=("$name") values+=("$value")
  done
  _anfs_conf_dir "$CLI_TOOL"; file="$REPLY/$CLI_TOOL.local.env"
  _anfs_config_write "$file" "# $CLI_TOOL settings for this machine ($CLI_TOOL config set and unset write here; the defaults are in $CLI_TOOL.env)"
  shown=$(anfs_display "$file")
  for i in "${!names[@]}"; do
    name="${names[$i]}"
    if _anfs_config_from_env "$name"; then
      anfs_warn "$name is set in the environment (${!name}), which wins over ${file##*/}"
    fi
    if anfs_json_on; then anfs_result name "$name" value "${values[$i]}" file "$file"
    else anfs_info "$name=${values[$i]} ($shown)"
    fi
  done
}

cmd_config_unset() {
  local name file shown i known
  declare -gA _CF_SET=() _CF_FOUND=()
  _CF_ORDER=()
  _anfs_config_collect "$CLI_TOOL"
  _anfs_conf_dir "$CLI_TOOL"; file="$REPLY/$CLI_TOOL.local.env"
  _anfs_conf_parse "$file"
  for name in "$@"; do
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || _anfs_config_refuse "'$name' is not a setting's name"
    # a declared name, or any line of the local file (a stray one, or one the loader ignores)
    known=""
    for i in "${!_ANFS_CONF_NAMES[@]}"; do
      [[ "${_ANFS_CONF_NAMES[$i]}" != "$name" ]] || known=1
    done
    [[ -n "$known" ]] || _anfs_config_declared "$name"
    _CF_SET[$name]=""
  done
  shown=$(anfs_display "$file")
  if [[ -f "$file" ]]; then
    _anfs_config_write "$file" ""
  fi
  for name in "$@"; do
    if [[ -n "${_CF_FOUND[$name]:-}" ]]; then
      if anfs_json_on; then anfs_result name "$name" removed true file "$file"
      else anfs_info "$name removed ($shown)"
      fi
    else
      if anfs_json_on; then anfs_result name "$name" removed false file "$file"
      else anfs_info "$name is not in $shown: nothing to remove"
      fi
    fi
  done
}

# --- Completion: the shipped file read, no fork -------------------------------------------------

# The settings the tool declares, each followed by <suffix>
_anfs_config_complete() {
  local name
  _anfs_conf_dir "$CLI_TOOL"
  _anfs_config_shipped "$REPLY/$CLI_TOOL.env"
  for name in ${_CF_S_NAMES[@]+"${_CF_S_NAMES[@]}"}; do
    anfs_conf_env_only "$name" || printf '%s%s\n' "$name" "$1"
  done
}
complete_setting() { _anfs_config_complete ""; }
complete_assignment() { _anfs_config_complete "="; }
