#!/usr/bin/env bash
# Source repositories: the source lists, cloning and updating, and the src and package commands
#
# Repos are read from two lists in priority order:
#   user.list   (yours; edited by `ppm src`) — highest priority
#   system.list (shipped by ppm/system) — the batteries-included defaults
# sources.list is the pre-split legacy name; if user.list is absent it is read as the user list.
#
# The machinery lives in shared/sources.sh (gitsrc_*), which other tools (pcm) source too. This
# file configures it for ppm and keeps ppm's own names for the rest of ppm and its extensions.

# shared/ sits next to this file once ppm/system is stowed; right after a pull that added it, only
# the clone has it, so follow this file's link into the clone
_ppm_shared_lib() {
  local self="${BASH_SOURCE[0]}" dir link
  dir="$(cd "$(dirname "$self")" && pwd)"
  while [[ ! -f "$dir/shared/$1" && -L "$self" ]]; do
    link="$(readlink "$self")"
    [[ "$link" == /* ]] || link="$dir/$link"
    self="$link"
    dir="$(cd "$(dirname "$self")" && pwd)"
  done
  echo "$dir/shared/$1"
}
source "$(_ppm_shared_lib sources.sh)"

# Point gitsrc at ppm's lists and directories. Called before each use: the paths and ppm.conf
# settings are only final once the ppm script has set them up.
_ppm_gitsrc_env() {
  GITSRC_TOOL=ppm
  GITSRC_USER_LIST="$PPM_USER_SOURCES"
  GITSRC_SYSTEM_LIST="$PPM_SYSTEM_SOURCES"
  GITSRC_REPOS_DIR="$PPM_DATA_HOME"
  GITSRC_CACHE_DIR="$PPM_CACHE_HOME"
  GITSRC_UPDATE_TTL="${PPM_UPDATE_CACHE_DURATION:-86400}"
  GITSRC_QUIET_SKIPPED="${PPM_QUIET_SKIPPED_REPOS:-false}"
  GITSRC_LINK_LOCAL=false
  GITSRC_SYSTEM_LIST_HINT="run 'ppm file protect ~/.config/ppm/system.list' to edit it here"
}

# The user-managed source list `ppm src` edits. Migrates a plain legacy sources.list to
# user.list once (a symlinked legacy file — a config claimed into a repo — is left in place).
_user_sources_file() {
  if [[ ! -e "$PPM_USER_SOURCES" && -f "$PPM_LEGACY_SOURCES" && ! -L "$PPM_LEGACY_SOURCES" ]]; then
    mv "$PPM_LEGACY_SOURCES" "$PPM_USER_SOURCES"
  fi
  echo "$PPM_USER_SOURCES"
}

# The user list to READ from: user.list if present, else the legacy sources.list
_user_sources_read() {
  if [[ -f "$PPM_USER_SOURCES" ]]; then
    echo "$PPM_USER_SOURCES"
  elif [[ -f "$PPM_LEGACY_SOURCES" ]]; then
    echo "$PPM_LEGACY_SOURCES"
  fi
}

gitsrc_hook_user_list_file() { _user_sources_file; }
gitsrc_hook_user_list_read() { _user_sources_read; }

# src ssh may rewrite system.list only once you have protected it (`ppm file protect`)
gitsrc_hook_system_writable() { _protected_has "${PPM_SYSTEM_SOURCES#$HOME/}"; }

# Read the source lists into REPO_URLS and REPO_NAMES (array order is priority order)
collect_repos() {
  _ppm_gitsrc_env
  gitsrc_collect
  REPO_URLS=(${GITSRC_URLS[@]+"${GITSRC_URLS[@]}"})
  REPO_NAMES=(${GITSRC_NAMES[@]+"${GITSRC_NAMES[@]}"})
}

# Check if argument is a known repo name (exists in PPM_DATA_HOME)
is_repo_name() {
  [[ -d "$PPM_DATA_HOME/$1/packages" ]]
}

# Check if entry is a git URL (not a local path)
is_git_url() {
  gitsrc_is_git_url "$1"
}

# Position of a repo in the collected sources (lower is higher priority)
_repo_index() {
  GITSRC_NAMES=(${REPO_NAMES[@]+"${REPO_NAMES[@]}"})
  gitsrc_index "$1"
}

# Manage sources in the user list (add/remove/ssh); list shows both user and system
src() {
  _ppm_gitsrc_env
  gitsrc_command "$@"
}

# `ppm customize`: start customizing this machine. Creates a local git repo as the "user"
# source with a system package (a layer of ppm/system) that holds user.list, and stows it — so
# from here your source list lives in your own repo. Dispatched through main(): it calls install.
customize() {
  local alias="$PPM_USER_REPO_ALIAS"
  local repo_dir="$PPM_DATA_HOME/$alias"
  local config_dir="$repo_dir/packages/system/home/.config/ppm"
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
  if [[ -L "$PPM_USER_SOURCES" ]]; then
    echo "Error: $PPM_USER_SOURCES is already a link into a package ($(readlink "$PPM_USER_SOURCES"))"
    return 1
  fi
  if _protected_has "${PPM_USER_SOURCES#$HOME/}"; then
    echo "Error: $PPM_USER_SOURCES is protected; run 'ppm file unprotect' on it first"
    return 1
  fi

  # The repo, with a system package that will own user.list
  mkdir -p "$config_dir"
  git -C "$repo_dir" init -q
  printf 'version: 0.1.0\nauthor: %s\n' "${USER:-unknown}" > "$repo_dir/packages/system/package.yml"

  # Register the repo at the top of the user list. A local path: it is never pulled until you
  # give it a remote. The repo's copy of the list must list the repo itself, or once it is
  # stowed nothing registers "user" and the repo drops out of the sources.
  src add --top "$repo_dir" "$alias"
  user_file=$(_user_sources_file)
  cp "$user_file" "$config_dir/user.list"

  # -f swaps the plain user.list for a link into the repo (same content). Only the user layer:
  # it is the top layer so it can't conflict, and -f stays away from ppm/system.
  force=true install "$alias/system"

  echo ""
  echo "ppm is now customizable from $repo_dir (source '$alias', highest priority)."
  echo "  - $PPM_USER_SOURCES lives in that repo now; commit it"
  echo "  - take over any ppm-managed file with: ppm file claim <file>"
  echo "  - to use it on other machines: add a remote and push, change the '$alias' line in"
  echo "    user.list to that git URL, then on a new machine run: install.sh --repo <git-url>"
}

# `ppm src update [alias...]`: clone missing and pull existing repos (see gitsrc_update)
_src_update() {
  _ppm_gitsrc_env
  gitsrc_update "$@"
}

# Auto-update (run by install): pull only the repos that are stale — never updated, or not within
# PPM_UPDATE_CACHE_DURATION seconds. Fresh repos aren't touched.
update_ppm_if_needed() {
  _ppm_gitsrc_env
  gitsrc_update_stale
}
