# anfs.sh — anfs's portable shell integration (core/anfs).
# Sourced by both the bash and the zsh rc.

command -v anfs >/dev/null 2>&1 || return 0

# anfs installs packages too (anfs install <source>), and a src update can bring new shell files,
# so both reload the shell like ppm install does. _ppm_shell_reload comes from ppm's per-shell file.
# `anfs <resource> ...` is the tool's line, through the tool's own shell function when it has one
# (ppm's cd and reload, wsm's and pmm's cd); a tool that is not installed goes to anfs, which says
# so. `anfs <name> cd` goes to where `anfs <name> path` says (anfs work cd, from a package).
anfs() {
  local _anfs_tool=""
  case "${1:-}" in
    package|ppm) _anfs_tool=ppm ;;
    container|pcm) _anfs_tool=pcm ;;
    machine|pmm) _anfs_tool=pmm ;;
    skill|psm) _anfs_tool=psm ;;
    space|wsm) _anfs_tool=wsm ;;
    vault|pvm) _anfs_tool=pvm ;;
  esac
  if [ -n "$_anfs_tool" ] && command -v "$_anfs_tool" >/dev/null 2>&1; then
    shift
    "$_anfs_tool" "$@"
    return
  fi
  if [ "${2:-}" = cd ] && [ -n "${1:-}" ] && [ -x "$HOME/.local/bin/anfs-$1" ]; then
    local _anfs_dir _anfs_name="$1"
    shift 2
    _anfs_dir=$(command anfs "$_anfs_name" path "$@") && cd "$_anfs_dir"
    return
  fi
  command anfs "$@"
  local ret=$?
  if [ $ret -eq 0 ] && { [ "${1:-}" = install ] || { [ "${1:-}" = src ] && [ "${2:-}" = update ]; }; }; then
    command -v _ppm_shell_reload >/dev/null 2>&1 && _ppm_shell_reload
  fi
  return $ret
}
