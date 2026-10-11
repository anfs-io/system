#!/usr/bin/env bats
# Categories: `categories:` in package.yml, `ppm list @category`, and @category expansion for
# install/remove. ppm's libs and anfs's resolver are sourced from this clone, with the sources
# redirected into the temp dir.
# Run: bats packages/ppm/tests/

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/ppm"
  local anfs="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"

  T="$BATS_TEST_TMPDIR"
  ANFS_SOURCES_HOME="$T/sources"
  GITSRC_USER_LIST="$T/user.list"
  GITSRC_SYSTEM_LIST="$T/system.list"
  GITSRC_REPOS_DIR="$ANFS_SOURCES_HOME"
  GITSRC_LINK_LOCAL=false
  # Priority order: user, stack
  printf 'file:///x/user.git  user\nfile:///x/stack.git  stack\n' > "$GITSRC_USER_LIST"

  # shellcheck source=/dev/null
  source "$anfs/sources.sh"
  source "$anfs/resolve.sh"
  source "$lib/core.sh"
  source "$lib/platform.sh"
  source "$lib/packages.sh"

  # sources.sh sources anfs's libs from $HOME; collect_repos is all of it the tests need
  collect_repos() {
    anfs_sources packages
    REPO_NAMES=(${ANFS_SRC_NAMES[@]+"${ANFS_SRC_NAMES[@]}"})
    REPO_URLS=(${ANFS_SRC_DIRS[@]+"${ANFS_SRC_DIRS[@]}"})
  }
  is_repo_name() { [[ -d "$ANFS_SOURCES_HOME/$1/packages" ]]; }

  force=false yes=true
}

# pkg <repo> <name> [package.yml lines...]
pkg() {
  local dir="$ANFS_SOURCES_HOME/$1/packages/$2"
  mkdir -p "$dir"
  shift 2
  { echo "version: 0.1.0"; printf '%s\n' "$@"; } > "$dir/package.yml"
}

@test "list @category: every layer that declares it, in source order" {
  pkg stack claude 'categories: [ai]'
  pkg stack herdr 'categories: [ai, pde]'
  pkg stack git 'categories: [pde]'
  pkg user claude
  pkg user mine 'categories: [ai]'
  run cmd_list @ai
  [ "$output" = "$(printf 'user/mine\nstack/claude\nstack/herdr')" ]
  run cmd_list @pde
  [ "$output" = "$(printf 'stack/git\nstack/herdr')" ]
  run cmd_list @nope
  [ -z "$output" ]
}

@test "list @: each category once, with its number of names" {
  pkg stack claude 'categories: [ai]'
  pkg stack herdr 'categories: [ai, pde]'
  pkg user claude 'categories: [ai]'
  run cmd_list @
  [ "$output" = "$(printf 'ai  2\npde  1')" ]
}

@test "expand @category: bare names once, so layers still apply" {
  pkg stack claude 'categories: [ai]'
  pkg user claude 'categories: [ai]'
  pkg stack herdr 'categories: [ai]'
  pkg stack git
  expand_packages install @ai git
  [ "${EXPANDED_PACKAGES[*]}" = "claude herdr git" ]
}

@test "expand @category: skips packages this platform doesn't support" {
  pkg stack claude 'categories: [ai]'
  pkg stack other 'categories: [ai]' 'platforms: [nowhere]'
  run expand_packages install @ai
  [[ "$output" == *"Skipping other"* ]]
  expand_packages install @ai >/dev/null
  [ "${EXPANDED_PACKAGES[*]}" = "claude" ]
}

@test "expand @category: an empty category is an error" {
  pkg stack claude
  run expand_packages install @ai
  [ "$status" -ne 0 ]
  [[ "$output" == *"No packages found in category 'ai'"* ]]
}

@test "categories is a key ppm owns, not a declared resource" {
  pkg stack claude 'categories: [ai]'
  run meta_extra_keys "$ANFS_SOURCES_HOME/stack/packages/claude"
  [ -z "$output" ]
}

@test "a malformed package.yml is skipped, not the whole category" {
  pkg stack claude 'categories: [ai]'
  pkg stack broken 'categories: [ai'
  pkg stack herdr 'categories: ai'
  run cmd_list @ai
  [[ "$output" == *"stack/claude"* ]]
  [[ "$output" == *"stack/herdr"* ]]
  [[ "$output" == *"skipping unreadable"*"broken"* ]]
}
