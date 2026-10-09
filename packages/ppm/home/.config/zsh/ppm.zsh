# ppm.zsh — zsh-specific ppm integration (core/ppm).
# The `ppm cd` wrapper is portable and lives in .config/sh/ppm.sh.
# zcomp and zsrc come from pde/zsh; ppm doesn't depend on that package.

command -v ppm >/dev/null 2>&1 || return

(( $+functions[zcomp] )) && zcomp ppm

# Called by the ppm() and anfs() wrappers after a successful install, remove or src update
_ppm_shell_reload() {
  (( $+functions[zsrc] )) && zsrc
  (( $+functions[compinit] )) && compinit
}
