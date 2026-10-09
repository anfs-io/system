# ppm.bash — bash-specific ppm integration (core/ppm).
# The `ppm cd` wrapper is portable and lives in .config/sh/ppm.sh.
# `ppm completion bash` is still a stub, so there is no completion to load yet.

command -v ppm >/dev/null 2>&1 || return

# Called by the ppm() and anfs() wrappers after a successful install, remove or src update
_ppm_shell_reload() {
  [ -r "$HOME/.bashrc" ] && . "$HOME/.bashrc"
}
