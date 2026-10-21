# anfs.sh — anfs's portable shell integration (core/anfs).
# Sourced by both the bash and the zsh rc.

# Every tool's `cd` (ppm, pcm, pmm, psm, wsm, `anfs <name> cd`) is a shell function, since a
# subshell can't change the parent's directory, and each goes through this one helper:
#   _anfs_cd [-s WORD] TOOL DEFAULT [ARG...]
# runs `command TOOL [WORD] path ARG...` and cds to the path it prints on exit 0, or on exit 3
# (stale: the path is still printed and the warning is already on stderr, so you can cd in to fix
# it); any other exit is returned and the directory is left alone. With no ARG it cds to DEFAULT,
# or when DEFAULT is empty asks `TOOL [WORD] path` with no arguments. It is defined before the
# guard below and the tools' wrappers look it up at call time, so sourcing order does not matter.
_anfs_cd() {
  local _anfs_sub="" _anfs_tool _anfs_default _anfs_dir _anfs_rc
  if [ "${1:-}" = -s ]; then
    _anfs_sub=$2
    shift 2
  fi
  _anfs_tool=$1
  _anfs_default=$2
  shift 2
  if [ $# -eq 0 ] && [ -n "$_anfs_default" ]; then
    builtin cd -- "$_anfs_default"
    return
  fi
  if [ -n "$_anfs_sub" ]; then
    _anfs_dir=$(command "$_anfs_tool" "$_anfs_sub" path "$@")
  else
    _anfs_dir=$(command "$_anfs_tool" path "$@")
  fi
  _anfs_rc=$?
  [ "$_anfs_rc" -eq 0 ] || [ "$_anfs_rc" -eq 3 ] || return "$_anfs_rc"
  [ -n "$_anfs_dir" ] || return 1
  builtin cd -- "$_anfs_dir"
}

command -v anfs >/dev/null 2>&1 || return 0

# anfs installs packages too (anfs install <stack>, anfs src install <source>), and a src update can bring new shell files,
# so both reload the shell like ppm install does. _ppm_shell_reload comes from ppm's per-shell file.
# `anfs <resource> ...` is the tool's line, through the tool's own shell function when it has one
# (each one's cd, and ppm's reload); a tool that is not installed goes to anfs, which says so.
# `anfs <name> cd` goes to where `anfs <name> path` says (anfs work cd, from a package).
anfs() {
  local _anfs_tool=""
  case "${1:-}" in
    package|ppm) _anfs_tool=ppm ;;
    container|pcm) _anfs_tool=pcm ;;
    machine|pmm) _anfs_tool=pmm ;;
    skill|psm) _anfs_tool=psm ;;
    space|wsm) _anfs_tool=wsm ;;
  esac
  if [ -n "$_anfs_tool" ] && command -v "$_anfs_tool" >/dev/null 2>&1; then
    shift
    "$_anfs_tool" "$@"
    return
  fi
  if [ "${2:-}" = cd ] && [ -n "${1:-}" ] && [ -x "$HOME/.local/bin/anfs-$1" ]; then
    local _anfs_name="$1"
    shift 2
    _anfs_cd -s "$_anfs_name" anfs "" "$@"
    return
  fi
  command anfs "$@"
  local ret=$?
  if [ $ret -eq 0 ] && { [ "${1:-}" = install ] || [ "${1:-}" = remove ] || [ "${1:-}" = rm ] ||
       { [ "${1:-}" = src ] && { [ "${2:-}" = update ] || [ "${2:-}" = install ]; }; }; }; then
    command -v _ppm_shell_reload >/dev/null 2>&1 && _ppm_shell_reload
  fi
  return $ret
}
