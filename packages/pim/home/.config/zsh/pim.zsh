# pim.zsh — Personal Image Manager shell function: pim cd

(( $+functions[zcomp] )) && zcomp pim

# Wrapper to handle `pim cd` since subshells can't change parent directory
pim() {
  if [[ "${1:-}" == "cd" ]]; then
    shift
    if [[ $# -eq 0 ]]; then
      builtin cd "${PIM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/pim}/images"
    else
      local image_path
      image_path=$(command pim path "$@") || return $?
      builtin cd "$image_path"
    fi
  else
    command pim "$@"
  fi
}
