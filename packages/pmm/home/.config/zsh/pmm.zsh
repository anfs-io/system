# pmm.zsh — Personal Machine Manager shell function: pmm cd

(( $+functions[zcomp] )) && zcomp pmm

# Wrapper to handle `pmm cd` since subshells can't change parent directory
pmm() {
  if [[ "${1:-}" == "cd" ]]; then
    shift
    if [[ $# -eq 0 ]]; then
      builtin cd "${PMM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/pmm}/machines"
    else
      local machine_path
      machine_path=$(command pmm path "$@") || return $?
      builtin cd "$machine_path"
    fi
  else
    command pmm "$@"
  fi
}
