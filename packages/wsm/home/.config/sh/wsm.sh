# wsm.sh — wsm's portable shell integration.
# Sourced by both the bash and the zsh rc; anything zsh-only lives in .config/zsh/wsm.zsh.

command -v wsm >/dev/null 2>&1 || return 0

# Wrapper to handle `wsm cd` through _anfs_cd (anfs.sh). No argument: what `wsm path` says, the
# root of the workspace containing the current directory. Exit 3 (stale entry) still cds.
wsm() {
  if [ "${1:-}" = "cd" ]; then
    shift
    _anfs_cd wsm "" "$@"
  else
    command wsm "$@"
  fi
}
