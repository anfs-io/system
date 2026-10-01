# ppm.sh — ppm's portable shell integration (anfs/ppm).
# Sourced by both the bash and the zsh rc. Shell-specific bits live in
# .config/zsh/ppm.zsh and .config/bash/ppm.bash.

command -v ppm >/dev/null 2>&1 || return 0

# Wrapper to handle `ppm cd`: a subshell can't change the parent's directory.
# After a successful install/remove the shell's own config is reloaded through
# _ppm_shell_reload, which each shell's file defines. It is looked up at call time, so this
# file does not care whether it was sourced before or after that definition.
ppm() {
  if [ "${1:-}" = "cd" ]; then
    shift
    local verbose_flag=""
    [ "${1:-}" = "-v" ] && { verbose_flag="-v"; shift; }
    if [ $# -eq 0 ]; then
      cd "${XDG_DATA_HOME:-$HOME/.local/share}/anfs/sources"
    else
      local pkg_path
      pkg_path=$(command ppm path $verbose_flag "$@") || return $?
      cd "$pkg_path"
    fi
  else
    command ppm "$@"
    local ret=$?
    if [ $ret -eq 0 ] && { [ "${1:-}" = install ] || [ "${1:-}" = remove ]; }; then
      command -v _ppm_shell_reload >/dev/null 2>&1 && _ppm_shell_reload
    fi
    return $ret
  fi
}
