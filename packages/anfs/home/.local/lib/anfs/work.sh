#!/usr/bin/env bash
# anfs: ANFS_WORK=<job>, a job's code on live data
#
# BOOTSTRAP SET: this file must parse and run under bash 3.2, the version macOS ships. Every entry
# script sources it before bash.sh, so it runs under whatever bash started the tool.
#
# With ANFS_WORK naming a job (~/work/<job>/, anfs-dev's `anfs work`), a tool installed from the
# sources runs the job's copy of itself instead, against the live install's sources, settings and
# data. Every entry script's first line after `set -euo pipefail` is the preamble:
#
#   [ -z "${ANFS_WORK:-}" ] || [ ! -f "$HOME/.local/lib/anfs/work.sh" ] || . "$HOME/.local/lib/anfs/work.sh"
#
# The rules (anfs_work_handover):
#   - Only the installed copy hands over: the one run as ~/.local/bin/<tool>. A job's copy, a
#     test's copy and a checkout run by path never do, so there is no loop and no marker.
#   - The job is ${ANFS_WORK_HOME:-~/work}/$ANFS_WORK, and has a .job.yml. A missing job, or a name
#     with a / or starting with a dot: `anfs: no job <job> in <dir> (anfs work list)`, exit 64.
#   - `anfs: running job <job>` on stderr, once per run: ANFS_WORK_SAID is exported, so the tools
#     this one runs stay quiet. Said whether or not this tool has a copy: its libraries may still
#     be the job's (paths.sh).
#   - The job's copy (anfs_work_map): the link at ~/.local/bin/<tool> reads
#     .../sources/<alias>/<rest>; the copy is <job>/<alias>/<rest>, when the job has that worktree
#     and the file. Then exec, arguments intact. No copy: the installed tool goes on.
# ANFS_WORK, ANFS_WORK_HOME and ANFS_WORK_TMP come from the environment only (paths.sh's
# anfs_conf_env_only): this runs before any settings file is read.
#
# paths.sh sources this file for the functions alone (_ANFS_WORK_LOAD_ONLY=1), to map the library
# directories (anfs_lib_dir, anfs_lib_files) and to hand over to the job's paths.sh.

# The job's directory into REPLY, and ANFS_WORK_DIR when it is a job. Returns 1 when ANFS_WORK is
# not a job's name or there is no such job; REPLY is then the directory jobs are in.
anfs_work_job() {
  local home="${ANFS_WORK_HOME:-$HOME/work}"
  case "$home" in
    "~")   home="$HOME" ;;
    "~/"*) home="$HOME/${home#\~/}" ;;
  esac
  REPLY="$home"
  case "${ANFS_WORK:-}" in
    ""|*/*|.*) return 1 ;;
  esac
  [ -f "$home/$ANFS_WORK/.job.yml" ] || return 1
  REPLY="$home/$ANFS_WORK"
  ANFS_WORK_DIR="$REPLY"
  return 0
}

# Where the job's copy of an installed link would be, into REPLY: the link's text holds
# .../sources/<alias>/<rest> (relative or absolute; read once, never resolved further), and the
# copy is $ANFS_WORK_DIR/<alias>/<rest> when the job has the worktree <alias>. Returns 1 when the
# path is no link into the sources, or the job lacks that repo; the copy itself may not exist.
anfs_work_where() {
  local text rest alias
  REPLY=""
  [ -n "${ANFS_WORK_DIR:-}" ] && [ -L "$1" ] || return 1
  text=$(readlink "$1") || return 1
  case "$text" in
    sources/*)   rest="${text#sources/}" ;;
    */sources/*) rest="${text#*/sources/}" ;;
    *) return 1 ;;
  esac
  alias="${rest%%/*}"
  rest="${rest#*/}"
  [ -n "$alias" ] && [ -n "$rest" ] && [ "$rest" != "$alias" ] || return 1
  [ -d "$ANFS_WORK_DIR/$alias" ] || return 1
  REPLY="$ANFS_WORK_DIR/$alias/$rest"
  return 0
}

# The job's copy of an installed link (a tool, a library directory, a library file), into REPLY.
# Returns 1 when there is none (no link into the sources, no such worktree, no such file in it).
# Usage: anfs_work_map <path>
anfs_work_map() {
  anfs_work_where "$1" || return 1
  [ -e "$REPLY" ] && return 0
  REPLY=""
  return 1
}

# Run by the preamble with the tool's arguments: exec the job's copy, or return
anfs_work_handover() {
  local bin="${0%/*}" home
  if [ "$bin" != "$HOME/.local/bin" ]; then
    home=$(cd -P -- "$HOME" 2>/dev/null && pwd -P) || return 0
    [ "$bin" = "$home/.local/bin" ] || return 0
  fi
  if ! anfs_work_job; then
    case "$REPLY" in
      "$HOME")   home="~" ;;
      "$HOME"/*) home="~/${REPLY#"$HOME"/}" ;;
      *)         home="$REPLY" ;;
    esac
    echo "anfs: no job $ANFS_WORK in $home (anfs work list)" >&2
    exit 64
  fi
  if [ "${ANFS_WORK_SAID:-}" != "$ANFS_WORK" ]; then
    echo "anfs: running job $ANFS_WORK" >&2
    ANFS_WORK_SAID="$ANFS_WORK"
    export ANFS_WORK_SAID
  fi
  anfs_work_map "$0" || return 0
  exec "$REPLY" "$@"
}

[ -n "${_ANFS_WORK_LOAD_ONLY:-}" ] || anfs_work_handover "$@"
# A sourced file's status is the preamble's: never fail it under set -e
true
