# mise activation for zsh (core/ppm; ppm installs mise as a core component).
# Aliases are in .config/sh/mise.sh. zcomp and load_conf come from pde/zsh;
# ppm doesn't depend on that package.

command -v mise >/dev/null 2>&1 || return

eval "$(mise activate zsh)"
(( $+functions[zcomp] )) && zcomp mise

# Checked at call time, so this doesn't depend on the order ~/.config/zsh/*.zsh is sourced
mconf() {
  (( $+functions[load_conf] )) || { echo "mconf needs load_conf (pde/zsh)" >&2; return 1; }
  local dir=$XDG_CONFIG_HOME/mise/conf.d file="." ext="toml"
  load_conf "$@"
}
