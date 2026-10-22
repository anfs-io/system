#!/usr/bin/env bash
# Sources: the source repos that hold packages/
#
# Sources belong to anfs (`anfs src`): one list, one clone per source under $ANFS_SOURCES_HOME.
# ppm sees the ones that have a packages/ directory, in priority order; the machinery is
# lib/anfs/sources.sh (gitsrc_*) and lib/anfs/resolve.sh (anfs_sources), which every anfs tool uses.

source "$ANFS_LIB_DIR/sources.sh"
source "$ANFS_LIB_DIR/resolve.sh"

# Point gitsrc at anfs's lists and directories
_ppm_gitsrc_env() {
  anfs_gitsrc_env
}

# Read the sources holding packages/ into REPO_URLS and REPO_NAMES (array order is priority
# order). REPO_URLS is kept only as the index set the package lookups iterate.
collect_repos() {
  _ppm_gitsrc_env
  anfs_sources packages
  REPO_NAMES=(${ANFS_SRC_NAMES[@]+"${ANFS_SRC_NAMES[@]}"})
  REPO_URLS=(${ANFS_SRC_DIRS[@]+"${ANFS_SRC_DIRS[@]}"})
}

# Check if argument is a source holding packages
is_repo_name() {
  [[ -d "$ANFS_SOURCES_HOME/$1/packages" ]]
}

# Check if entry is a git URL (not a local path)
is_git_url() {
  gitsrc_is_git_url "$1"
}

# Position of a repo among the package sources (lower is higher priority)
_repo_index() {
  local i
  for i in ${REPO_NAMES[@]+"${!REPO_NAMES[@]}"}; do
    [[ "${REPO_NAMES[$i]}" == "$1" ]] && { echo "$i"; return; }
  done
  echo 9999
}

# Auto-update (run by install): pull only the repos that are stale — never updated, or not within
# ANFS_UPDATE_CACHE_DURATION seconds. Fresh repos aren't touched.
update_ppm_if_needed() {
  _ppm_gitsrc_env
  gitsrc_update_stale
}
