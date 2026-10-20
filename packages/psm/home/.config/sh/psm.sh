# psm.sh — psm's portable shell integration. Sourced by both the bash and the zsh rc; the
# zsh-only parts live in .config/zsh/psm.zsh.

command -v psm >/dev/null 2>&1 || return 0

# Wrapper to handle `psm cd` through _anfs_cd (anfs.sh): the config directory, as `psm path`
# prints it. It takes no argument.
psm() {
  if [ "${1:-}" = "cd" ]; then
    _anfs_cd psm ""
  else
    command psm "$@"
  fi
}
