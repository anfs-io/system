#!/usr/bin/env bash
# anfs: what a tool says, and the log every tool writes
#
#   anfs_info  <msg>...          stdout: the tool's normal output
#   anfs_warn  <msg>...          stderr, "<tool>: <msg>"
#   anfs_die   <msg>...          stderr, then exit 1
#   anfs_fail  <code> <msg>...   stderr, then exit <code>
#   anfs_debug <msg>...          stderr, only when debugging is on
#
# The tool's name is $CLI_TOOL (what cli.sh already needs), else the script's name.
#
# Debugging is on when ANFS_DEBUG is set (every tool) or <TOOL>_DEBUG is (that tool); empty, 0,
# false, no and off count as unset. cli.sh turns ANFS_DEBUG on for -d/--debug and exports it, so a
# tool run by another (a callback) debugs too. ANFS_TRACE (--trace) is `set -x` with a PS4 that
# says where each command is.
#
# The log: $ANFS_STATE_HOME/anfs.log, one file for every tool, so `tail -f` (or `anfs log -f`)
# follows a run across tools. Everything but anfs_info is appended whether or not debugging is on:
# the flag only decides what reaches the terminal. One line each:
#
#   2026-10-11T08:00:00-0400 wsm[4242] warn: not installed: lgat/x
#
# anfs_log_start (cli.sh calls it) caps the file: past ANFS_LOG_MAX bytes (1 MB) it becomes
# anfs.log.1, replacing the last one. ANFS_LOG=off writes no file; test helpers set it.
#
# Like everything in lib/anfs/ but bash.sh: functions only, no tool's code, the bash floor (5.2).

_anfs_truthy() {
  case "${1:-}" in ""|0|false|no|off) return 1 ;; *) return 0 ;; esac
}

anfs_log_tool() {
  ANFS_LOG_TOOL="${CLI_TOOL:-${0##*/}}"
}

anfs_debug_on() {
  _anfs_truthy "${ANFS_DEBUG:-}" && return 0
  local var
  anfs_log_tool
  var="${ANFS_LOG_TOOL^^}_DEBUG"
  var="${var//[^A-Z0-9_]/_}"
  _anfs_truthy "${!var:-}"
}

# The log file, in ANFS_LOG_FILE; returns 1 when logging is off
anfs_log_file() {
  [[ "${ANFS_LOG:-}" != off ]] || return 1
  ANFS_LOG_FILE="${ANFS_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/anfs}/anfs.log"
}

# Usage: _anfs_log <level> <msg>...   Never fails: a log that cannot be written is not an error
_anfs_log() {
  local level="$1"
  shift
  anfs_log_file || return 0
  anfs_log_tool
  {
    [[ -d "${ANFS_LOG_FILE%/*}" ]] || mkdir -p "${ANFS_LOG_FILE%/*}"
    printf '%(%Y-%m-%dT%H:%M:%S%z)T %s[%d] %s: %s\n' -1 "$ANFS_LOG_TOOL" "$$" "$level" "$*" >> "$ANFS_LOG_FILE"
  } 2>/dev/null || true
}

# Once per process: cap the log, record the invocation, turn tracing on. Usage: anfs_log_start "$@"
anfs_log_start() {
  [[ -z "${_ANFS_LOG_STARTED:-}" ]] || return 0
  _ANFS_LOG_STARTED=1
  if anfs_log_file && [[ -f "$ANFS_LOG_FILE" ]]; then
    local size
    size=$(wc -c < "$ANFS_LOG_FILE" 2>/dev/null) || size=0
    if (( size > ${ANFS_LOG_MAX:-1048576} )); then
      mv -f "$ANFS_LOG_FILE" "$ANFS_LOG_FILE.1" 2>/dev/null || true
    fi
  fi
  _anfs_log start "$*"
  if _anfs_truthy "${ANFS_TRACE:-}"; then
    PS4='+ ${BASH_SOURCE[0]##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
    set -x
  fi
}

anfs_info() { printf '%s\n' "$*"; }

anfs_warn() {
  anfs_log_tool
  printf '%s: %s\n' "$ANFS_LOG_TOOL" "$*" >&2
  _anfs_log warn "$*"
}

anfs_die() {
  anfs_log_tool
  printf '%s: %s\n' "$ANFS_LOG_TOOL" "$*" >&2
  _anfs_log error "$*"
  exit 1
}

anfs_fail() {
  local code="$1"
  shift
  anfs_log_tool
  printf '%s: %s\n' "$ANFS_LOG_TOOL" "$*" >&2
  _anfs_log error "$* (exit $code)"
  exit "$code"
}

anfs_debug() {
  _anfs_log debug "$*"
  anfs_debug_on || return 0
  anfs_log_tool
  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    printf '\033[2m%s: debug: %s\033[0m\n' "$ANFS_LOG_TOOL" "$*" >&2
  else
    printf '%s: debug: %s\n' "$ANFS_LOG_TOOL" "$*" >&2
  fi
}

# Stop, with exit 69 (EX_UNAVAILABLE), unless <command> is on PATH.
# Usage: anfs_require <command> [how to get it]
anfs_require() {
  command -v "$1" >/dev/null 2>&1 || anfs_fail 69 "$1 is required${2:+ ($2)}"
}
