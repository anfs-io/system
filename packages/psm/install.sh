# psm
#
# Installs psm (~/.local/bin/psm), which syncs the agent skills declared in
# ~/.config/psm/*.yml to every AI agent ppm has installed. The sync logic
# lives in psm so skills can be refreshed without reinstalling: see `psm help`.

# --- marketplace plugin cloning: parked until the skills CLI work settles ---
# PLUGINS_DIR="$XDG_CACHE_HOME/agents/plugins"
#
# REPOS=(
#   "git@github.com:rjayroach/marketplace.git"
#   "git@github.com:cnfs-io/marketplace.git"
#   "git@github.com:anfs-io/marketplace.git"
# )
#
# x_install() {
#   mkdir -p "$PLUGINS_DIR"
#
#   for url in "${REPOS[@]}"; do
#     local owner="${url#*:}"
#     owner="${owner%%/*}"
#     local target="$PLUGINS_DIR/$owner"
#
#     if [[ -d "$target/.git" ]]; then
#       user_message "Pulled $owner into $target"
#       git -C "$target" pull --quiet
#     else
#       user_message "Cloned $owner into $target"
#       git clone --quiet "$url" "$target"
#     fi
#   done
# }

pre_install() {
  local cyan='\033[0;36m' nc='\033[0m'
  echo -e "${cyan}"
  cat << "EOF"
 ____  ____  __  __
|  _ \/ ___||  \/  |
| |_) \___ \| |\/| |
|  __/ ___) | |  | |
|_|   |____/|_|  |_|

EOF
  echo -e "${cyan}Personal Skills Manager${nc}"
}

# The sync happens in psm_ppm_changed at the end of this same run (psm is in its package list),
# so installing psm alongside agents syncs once, after all of them are in place
post_install() {
  ppm_register_callback psm_ppm_changed
}

post_remove() {
  user_message "Installed skills were left in place — list them with: npx skills list -g"
}

# ppm calls this after every install/remove run (see ppm_register_callback)
# Usage: psm_ppm_changed <install|remove> <repo/pkg>...
psm_ppm_changed() {
  local event="$1" qualified sync=false ids="" id kept
  shift

  case "$event" in
    install)
      for qualified in "$@"; do
        if [[ "$qualified" == "$PPM_CURRENT_PACKAGE" ]] || [[ -n "$(_psm_package_agents "$qualified")" ]]; then
          sync=true
        fi
      done
      $sync || return 0
      psm sync || ppm_fail "psm sync reported failures — fix and re-run: psm sync" || true
      ;;
    remove)
      for qualified in "$@"; do
        if [[ ! -f "$(_psm_package_meta "$qualified")" ]]; then
          user_message "$qualified is gone, so its agent is unknown; unlink its skills with: psm agents rm <agent>"
          continue
        fi
        ids="$ids $(_psm_package_agents "$qualified")"
      done
      # An id another installed package still declares keeps its skills
      kept=$(psm agents ls 2>/dev/null || true)
      for id in $ids; do
        grep -qxF -- "$id" <<< "$kept" && continue
        psm agents rm "$id" || ppm_fail "psm agents rm $id failed — re-run it by hand" || true
      done
      ;;
  esac
}

_psm_package_meta() {
  echo "$ANFS_SOURCES_HOME/${1%%/*}/packages/${1#*/}/package.yml"
}

# Agent ids a package declares under meta.agent, one per line
_psm_package_agents() {
  local meta
  meta=$(_psm_package_meta "$1")
  [[ -f "$meta" ]] || return 0
  yq -r '[.meta.agent] | flatten | .[] | select(. != null)' "$meta" 2>/dev/null || true
}
