# anfs.sh — anfs's portable shell integration (anfs/anfs).
# Sourced by both the bash and the zsh rc.

command -v anfs >/dev/null 2>&1 || return 0

# anfs installs packages too (anfs install <source>), and a src update can bring new shell files,
# so both reload the shell like ppm install does. _ppm_shell_reload comes from ppm's per-shell file.
anfs() {
  command anfs "$@"
  local ret=$?
  if [ $ret -eq 0 ] && { [ "${1:-}" = install ] || { [ "${1:-}" = src ] && [ "${2:-}" = update ]; }; }; then
    command -v _ppm_shell_reload >/dev/null 2>&1 && _ppm_shell_reload
  fi
  return $ret
}
