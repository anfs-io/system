# anfs.sh — anfs's portable shell integration (core/anfs).
# Sourced by both the bash and the zsh rc.

command -v anfs >/dev/null 2>&1 || return 0

# anfs installs packages too (anfs install <source>), and a src update can bring new shell files,
# so both reload the shell like ppm install does. _ppm_shell_reload comes from ppm's per-shell file.
# `anfs package ...` is `ppm ...`, through ppm's own function when there is one (its cd, its
# reload); `anfs <name> cd` goes to where `anfs <name> path` says (anfs work cd, from a package).
anfs() {
  case "${1:-}" in
    package|ppm) shift; ppm "$@"; return ;;
  esac
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
