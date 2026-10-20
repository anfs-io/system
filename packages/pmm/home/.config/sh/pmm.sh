# pmm.sh — pmm's portable shell integration. Sourced by both the bash and the zsh rc; the
# completion lives in .config/zsh/pmm.zsh.

command -v pmm >/dev/null 2>&1 || return 0

# Wrapper to handle `pmm cd` and `pmm image cd` through _anfs_cd (anfs.sh); no name: the machines
# directory, or its images directory.
pmm() {
  local _pmm_machines="${PMM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/pmm}/machines"
  if [ "${1:-}" = "cd" ]; then
    shift
    _anfs_cd pmm "$_pmm_machines" "$@"
  elif [ "${1:-}" = "image" ] && [ "${2:-}" = "cd" ]; then
    shift 2
    _anfs_cd -s image pmm "$_pmm_machines/images" "$@"
  else
    command pmm "$@"
  fi
}
