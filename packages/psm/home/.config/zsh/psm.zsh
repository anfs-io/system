# psm.zsh — psm's zsh-only integration: export, completion and sconf. The `psm cd` wrapper is
# portable and lives in ~/.config/sh/psm.sh.

export PSM_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/psm"

zcomp psm

sconf() {
  local dir=$PSM_CONFIG_HOME file="example.yml" ext="yml"
  load_conf "$@"
}
