# pmm.zsh — Personal Machine Manager shell function: pmm cd, pmm image cd

(( $+functions[zcomp] )) && zcomp pmm

# Wrapper to handle `pmm cd` and `pmm image cd` since subshells can't change parent directory
pmm() {
  local dir
  if [[ "${1:-}" == "cd" ]]; then
    shift
    if [[ $# -eq 0 ]]; then
      builtin cd "${PMM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/pmm}/machines"
    else
      dir=$(command pmm path "$@") || return $?
      builtin cd "$dir"
    fi
  elif [[ "${1:-}" == "image" && "${2:-}" == "cd" ]]; then
    shift 2
    if [[ $# -eq 0 ]]; then
      builtin cd "${PMM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/pmm}/machines/images"
    else
      dir=$(command pmm image path "$@") || return $?
      builtin cd "$dir"
    fi
  else
    command pmm "$@"
  fi
}
