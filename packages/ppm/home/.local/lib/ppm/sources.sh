#!/usr/bin/env bash
# Sources: the source repos that hold packages/, and the customize command
#
# Sources belong to anfs (`anfs src`): one list, one clone per source under $ANFS_SOURCES_HOME.
# ppm sees the ones that have a packages/ directory, in priority order; the machinery is
# lib/anfs/sources.sh (gitsrc_*) and lib/anfs/resolve.sh (anfs_sources), which every anfs tool uses.

source "$HOME/.local/lib/anfs/sources.sh"
source "$HOME/.local/lib/anfs/resolve.sh"

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

# `ppm customize`: start customizing this machine. Creates a local git repo as the "user"
# source with an anfs package (a layer of anfs/anfs) that holds user.list, and stows it — so from
# here your source list, and any anfs.conf you add next to it, live in your own repo.
# Dispatched through main(): it calls install.
cmd_customize() {
  local alias="$PPM_USER_REPO_ALIAS"
  local repo_dir="$ANFS_SOURCES_HOME/$alias"
  local config_dir="$repo_dir/packages/anfs/home/.config/anfs"
  local user_file

  collect_repos
  if [[ " ${REPO_NAMES[*]:-} " == *" $alias "* ]]; then
    echo "Error: a '$alias' source already exists; this machine is already customized"
    return 1
  fi
  if [[ -e "$repo_dir" ]]; then
    echo "Error: $repo_dir already exists"
    return 1
  fi
  if [[ -L "$ANFS_USER_LIST" ]]; then
    echo "Error: $ANFS_USER_LIST is already a link into a package ($(readlink "$ANFS_USER_LIST"))"
    return 1
  fi
  if _protected_has "${ANFS_USER_LIST#$HOME/}"; then
    echo "Error: $ANFS_USER_LIST is protected; run 'ppm file unprotect' on it first"
    return 1
  fi

  # The repo, with an anfs package that will own user.list
  mkdir -p "$config_dir"
  git -C "$repo_dir" init -q
  printf 'version: 0.1.0\nauthor: %s\n' "${USER:-unknown}" > "$repo_dir/packages/anfs/package.yml"

  # Register the repo at the top of the user list. A local path: it is never pulled until you
  # give it a remote. The repo's copy of the list must list the repo itself, or once it is
  # stowed nothing registers "user" and the repo drops out of the sources.
  _ppm_gitsrc_env
  gitsrc_add --top "$repo_dir" "$alias"
  user_file="$ANFS_USER_LIST"
  cp "$user_file" "$config_dir/user.list"

  # -f swaps the plain user.list for a link into the repo (same content). Only the user layer:
  # it is the top layer so it can't conflict, and -f stays away from anfs/anfs.
  force=true cmd_install "$alias/anfs"

  echo ""
  echo "ppm is now customizable from $repo_dir (source '$alias', highest priority)."
  echo "  - $ANFS_USER_LIST lives in that repo now; commit it"
  echo "  - settings: add packages/anfs/home/.config/anfs/anfs.conf there (it layers over anfs's)"
  echo "  - take over any ppm-managed file with: ppm file claim <file>"
  echo "  - to use it on other machines: add a remote and push, change the '$alias' line in"
  echo "    user.list to that git URL, then on a new machine run: install.sh --repo <git-url>"
}

# Auto-update (run by install): pull only the repos that are stale — never updated, or not within
# ANFS_UPDATE_CACHE_DURATION seconds. Fresh repos aren't touched.
update_ppm_if_needed() {
  _ppm_gitsrc_env
  gitsrc_update_stale
}
