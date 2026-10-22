#!/usr/bin/env bats
# ppm list: PACKAGE STATUS VERSION, the three statuses, --installed and the --json keys. ppm's
# libs and anfs's are sourced from this clone, sources and trackers redirected into the temp dir.
# Run: bats packages/ppm/tests/list.bats

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
  # cmd_list reads its options from cli.sh's CLI_OPT
  source "$anfs/cli.sh"
  source "$anfs/log.sh"
  source "$anfs/table.sh"
  export ANFS_LOG=off
  CLI_TOOL=ppm
  source "$lib/core.sh"
  source "$anfs/platform.sh"
  source "$lib/platform.sh"
  source "$lib/packages.sh"

  # sources.sh sources anfs's libs from $HOME; collect_repos is all of it the tests need
  collect_repos() {
    anfs_sources packages
    REPO_NAMES=(${ANFS_SRC_NAMES[@]+"${ANFS_SRC_NAMES[@]}"})
    REPO_URLS=(${ANFS_SRC_DIRS[@]+"${ANFS_SRC_DIRS[@]}"})
  }
  is_repo_name() { [[ -d "$ANFS_SOURCES_HOME/$1/packages" ]]; }

  PPM_INSTALLED_DIR="$T/state/installed"
  mkdir -p "$PPM_INSTALLED_DIR"
  force=false yes=true
}

# pkg <repo> <name> <version>: a package in a source
pkg() {
  mkdir -p "$ANFS_SOURCES_HOME/$1/packages/$2"
  echo "version: $3" > "$ANFS_SOURCES_HOME/$1/packages/$2/package.yml"
}

# installed <repo> <name> <version>: its install tracker
installed() {
  mkdir -p "$PPM_INSTALLED_DIR/$1"
  echo "version: \"$3\"" > "$PPM_INSTALLED_DIR/$1/$2.yml"
}

fixture() {
  pkg stack git 0.2.0; installed stack git 0.2.0      # installed
  pkg stack zsh 0.10.0; installed stack zsh 0.9.0     # outdated: the source was bumped
  pkg stack nvim 1.0.0                                # not installed
}

@test "list: the header is PACKAGE STATUS VERSION" {
  fixture
  ANFS_TABLE=aligned run cmd_list
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^PACKAGE\ +STATUS\ +VERSION$ ]]
}

@test "list: installed, outdated and -, with the installed version, else the source's" {
  fixture
  ANFS_TABLE=tsv run cmd_list
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'stack/git\tinstalled\t0.2.0\nstack/nvim\t-\t1.0.0\nstack/zsh\toutdated\t0.9.0')" ]
}

@test "list: a source older than the tracker is still installed" {
  pkg stack git 0.1.0; installed stack git 0.2.0
  ANFS_TABLE=tsv run cmd_list
  [ "$output" = "$(printf 'stack/git\tinstalled\t0.2.0')" ]
}

@test "list --installed: only what is installed, with its status" {
  fixture
  CLI_OPT[installed]=true
  ANFS_TABLE=tsv run cmd_list
  [ "$output" = "$(printf 'stack/git\tinstalled\t0.2.0\nstack/zsh\toutdated\t0.9.0')" ]
}

@test "list --json: package, status (null when not installed), version; no installed key" {
  fixture
  ANFS_TABLE=json run cmd_list
  [ "$status" -eq 0 ]
  [ "$(yq -p json -o json -I0 '[.[] | keys] | unique' <<< "$output")" = '[["package","status","version"]]' ]
  [ "$(yq -p json -r '.[] | select(.package == "stack/nvim") | .status' <<< "$output")" = "null" ]
  [ "$(yq -p json -r '.[] | select(.package == "stack/zsh") | .status + " " + .version' <<< "$output")" = "outdated 0.9.0" ]
  [ "$(yq -p json -r '.[] | select(.package == "stack/git") | .status + " " + .version' <<< "$output")" = "installed 0.2.0" ]
}
