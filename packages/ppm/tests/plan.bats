#!/usr/bin/env bats
# ppm install -n: the plan for every layer (lib/anfs/link.sh), and nothing changed: no links, no
# hooks, no tracker. ppm's libs and anfs's are sourced from this clone, with $HOME, the sources and
# the state in the temp dir.
# Run: bats packages/ppm/tests/plan.bats

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/ppm"
  local anfs="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"

  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME=$(cd -P "$BATS_TEST_TMPDIR/home" && pwd -P)
  ANFS_SOURCES_HOME="$HOME/.local/share/anfs/sources"
  GITSRC_USER_LIST="$BATS_TEST_TMPDIR/user.list"
  GITSRC_SYSTEM_LIST="$BATS_TEST_TMPDIR/system.list"
  GITSRC_REPOS_DIR="$ANFS_SOURCES_HOME"
  GITSRC_LINK_LOCAL=false
  printf 'file:///x/user.git  user\nfile:///x/stack.git  stack\n' > "$GITSRC_USER_LIST"
  PPM_STATE_HOME="$HOME/.local/state/ppm"
  PPM_INSTALLED_DIR="$PPM_STATE_HOME/installed"
  export ANFS_STATE_HOME="$HOME/.local/state/anfs"
  mkdir -p "$PPM_INSTALLED_DIR"
  export ANFS_LOG=off
  CLI_TOOL=ppm

  # shellcheck source=/dev/null
  source "$anfs/sources.sh"
  source "$anfs/resolve.sh"
  source "$anfs/cli.sh"
  source "$anfs/log.sh"
  source "$anfs/callbacks.sh"
  source "$anfs/link.sh"
  source "$lib/core.sh"
  source "$lib/platform.sh"
  source "$lib/packages.sh"
  source "$lib/file.sh"
  source "$lib/installer.sh"

  collect_repos() {
    anfs_sources packages
    REPO_NAMES=(${ANFS_SRC_NAMES[@]+"${ANFS_SRC_NAMES[@]}"})
    REPO_URLS=(${ANFS_SRC_DIRS[@]+"${ANFS_SRC_DIRS[@]}"})
  }
  is_repo_name() { [[ -d "$ANFS_SOURCES_HOME/$1/packages" ]]; }
  # the real install (one test makes one to plan over) must not pull or touch the real Homebrew
  update_ppm_if_needed() { :; }
  update_brew_if_needed() { :; }
  brew_missing() { :; }
  cask_missing() { :; }
  system_pkg_missing() { :; }

  config=false force=false reinstall=false skip_deps=false yes=true dry_run=true
  MARK="$BATS_TEST_TMPDIR/hooks"

  # stack/tool: two files and hooks that leave a mark; user/tool layers one of them
  pkg stack tool
  file stack tool .config/tool/rc stack
  file stack tool .toolrc stack
  cat > "$ANFS_SOURCES_HOME/stack/packages/tool/install.sh" <<HOOK
pre_install() { echo pre >> "$MARK"; }
post_install() { echo post >> "$MARK"; }
HOOK
}

pkg() { mkdir -p "$ANFS_SOURCES_HOME/$1/packages/$2"; echo "version: 0.1.0" > "$ANFS_SOURCES_HOME/$1/packages/$2/package.yml"; }
file() { mkdir -p "$(dirname "$ANFS_SOURCES_HOME/$1/packages/$2/home/$3")"; echo "$4" > "$ANFS_SOURCES_HOME/$1/packages/$2/home/$3"; }

# Everything under $HOME but the sources, with what each link says: the tree the plan must not change
tree() { (cd "$HOME" && find . -path ./.local/share/anfs -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do printf '%s %s\n' "$p" "$(readlink "$p" 2>/dev/null)"; done); }

@test "a fresh package: every file is link, and nothing changes" {
  local before
  before=$(tree)
  run cmd_install stack/tool
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing is changed (-n)"* ]]
  [[ "$output" == *"Install stack/tool"* ]]
  [[ "$output" == *"link      ~/.config/tool/rc"* ]]
  [[ "$output" == *"link      ~/.toolrc"* ]]
  [ "$(tree)" = "$before" ]
  [ ! -e "$MARK" ]
  [ -z "$(ls -A "$PPM_INSTALLED_DIR")" ]
}

@test "an installed package plans only keep, and the tracker is untouched" {
  dry_run=false
  run cmd_install stack/tool
  [ "$status" -eq 0 ]
  rm -f "$MARK"
  dry_run=true
  local before tracker
  before=$(tree)
  tracker=$(cat "$PPM_INSTALLED_DIR/stack/tool.yml")
  run cmd_install stack/tool
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep      ~/.config/tool/rc"* ]]
  [[ "$output" == *"keep      ~/.toolrc"* ]]
  [[ "$output" != *"link "* ]]
  [ "$(tree)" = "$before" ]
  [ "$(cat "$PPM_INSTALLED_DIR/stack/tool.yml")" = "$tracker" ]
  [ ! -e "$MARK" ]
}

@test "layers: the higher layer's file is linked from it, the lower one's skipped" {
  pkg user tool
  file user tool .toolrc user
  run cmd_install tool
  [ "$status" -eq 0 ]
  [[ "$output" == *"Install user/tool"*"link      ~/.toolrc"*"Install stack/tool"*"skip      ~/.toolrc"* ]]
}

@test "a conflicting package: each file in the way and what -f would do; exit 1, nothing changes" {
  mkdir -p "$HOME/.config/tool"
  echo mine > "$HOME/.config/tool/rc"
  echo mine > "$HOME/.toolrc"
  local before
  before=$(tree)
  run cmd_install stack/tool
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict  ~/.config/tool/rc  (a file; -f moves it aside)"* ]]
  [[ "$output" == *"conflict  ~/.toolrc  (a file; -f moves it aside)"* ]]
  [[ "$output" == *"The install would stop"* ]]
  [ "$(tree)" = "$before" ]
  [ ! -e "$MARK" ]
  [ ! -e "$PPM_STATE_HOME/backup" ]

  force=true run cmd_install stack/tool
  [ "$status" -eq 0 ]
  [ "$(tree)" = "$before" ]
  [ ! -e "$PPM_STATE_HOME/backup" ]
}
