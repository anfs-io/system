# ppm.sh — ppm's portable shell integration (core/ppm).
# Sourced by both the bash and the zsh rc. Shell-specific bits live in
# .config/zsh/ppm.zsh and .config/bash/ppm.bash.

command -v ppm >/dev/null 2>&1 || return 0

# Wrapper to handle `ppm cd` through _anfs_cd (anfs.sh); no package: the sources directory.
# After a successful install/remove the shell's own config is reloaded through
# _ppm_shell_reload, which each shell's file defines. It is looked up at call time, so this
# file does not care whether it was sourced before or after that definition.
ppm() {
  if [ "${1:-}" = "cd" ]; then
    shift
    _anfs_cd ppm "${XDG_DATA_HOME:-$HOME/.local/share}/anfs/sources" "$@"
  else
    command ppm "$@"
    local ret=$?
    if [ $ret -eq 0 ] && { [ "${1:-}" = install ] || [ "${1:-}" = remove ]; }; then
      command -v _ppm_shell_reload >/dev/null 2>&1 && _ppm_shell_reload
    fi
    return $ret
  fi
}
