# psm.zsh

export PSM_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/psm"

zcomp psm

sconf() {
  local dir=$PSM_CONFIG_HOME file="example.yml" ext="yml"
  load_conf "$@"
}

# Wrapper to handle `psm cd` since subshells can't change parent directory
psm() {
  if [[ "${1:-}" == "cd" ]]; then
    shift
    builtin cd "$(command psm path)"
  else
    command psm "$@"
  fi
}
