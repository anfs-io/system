#!/usr/bin/env bats
# ppm move (lib/ppm/move.sh over lib/anfs/move.sh): an installed package moves to another source;
# its links, tracker, claims, callback registration and backup entries follow it, and no hook
# runs. ppm's libs and anfs's are sourced from this clone; the sources are git repositories made
# here, with $HOME and the state in the temp dir.
# Run: bats packages/ppm/tests/move.bats

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

teardown() { rm -f "${PPM_MSG_FILE:-}" "${PPM_SKIP_FILE:-}"; }

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/ppm"
  local anfs="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"
  T=$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)
  export HOME="$T/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  ANFS_SOURCES_HOME="$HOME/.local/share/anfs/sources"
  GITSRC_USER_LIST="$T/user.list" GITSRC_SYSTEM_LIST="$T/system.list"
  GITSRC_REPOS_DIR="$ANFS_SOURCES_HOME" GITSRC_LINK_LOCAL=false
  : > "$GITSRC_USER_LIST"
  PPM_STATE_HOME="$HOME/.local/state/ppm"
  PPM_INSTALLED_DIR="$PPM_STATE_HOME/installed"
  PPM_REPO_DIR="$ANFS_SOURCES_HOME/core"
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
  source "$anfs/manifest.sh"
  source "$anfs/files.sh"
  source "$anfs/repo.sh"
  source "$anfs/move.sh"
  local bats_exit
  bats_exit=$(trap -p EXIT)
  source "$lib/core.sh"
  eval "$bats_exit"
  source "$anfs/platform.sh"
  source "$lib/platform.sh"
  source "$lib/packages.sh"
  source "$lib/file.sh"
  source "$lib/installer.sh"
  source "$lib/move.sh"
  collect_repos() {
    anfs_sources packages
    REPO_NAMES=(${ANFS_SRC_NAMES[@]+"${ANFS_SRC_NAMES[@]}"})
    REPO_URLS=(${ANFS_SRC_DIRS[@]+"${ANFS_SRC_DIRS[@]}"})
  }
  force=false dry_run=false
  S="$ANFS_SOURCES_HOME"
  MARK="$T/hooks"
  OUT="$T/outside"
  mkdir -p "$OUT"
}

# Sources <alias>..., highest priority first: each a git repository with one commit
src() {
  local a
  for a in "$@"; do
    git init -q -b main "$S/$a"
    git -C "$S/$a" commit -q --allow-empty -m "init $a"
    printf 'file:///x/%s.git  %s\n' "$a" "$a" >> "$GITSRC_USER_LIST"
  done
}
put() { mkdir -p "$(dirname "$S/$1/$2")"; printf '%s\n' "${3:-$2}" > "$S/$1/$2"; }
commit() { git -C "$S/$1" add -A && git -C "$S/$1" commit -q -m "${2:-c}"; }

# a/tool: a file, a directory link, a link out of the tree, and hooks that leave a mark
tool() {
  src a b c
  mkdir -p "$S/a/packages/tool"
  cat > "$S/a/packages/tool/package.yml" <<EOF
version: 0.1.0
links:
  - .local/lib/tool/
  - {src: $OUT, dest: .outside}
EOF
  put a packages/tool/home/.toolrc rc
  put a packages/tool/home/.local/lib/tool/lib.sh lib
  cat > "$S/a/packages/tool/install.sh" <<EOF
pre_install() { echo pre_install >> "$MARK"; }
post_install() { echo post_install >> "$MARK"; }
pre_remove() { echo pre_remove >> "$MARK"; }
post_remove() { echo post_remove >> "$MARK"; }
install_$(os)() { echo install >> "$MARK"; }
EOF
  commit a tool
}

# What ppm install does for the links and the tracker (no hooks)
inst() {
  PPM_SKIP_FILE=""
  _reset_skip_file
  local q
  for q in "$@"; do
    PPM_CURRENT_PACKAGE="$q"
    stow_package "$S/${q%%/*}/packages/${q#*/}"
    meta_mark_installed "${q%%/*}" "${q#*/}" "$S/${q%%/*}/packages/${q#*/}" "$STOWED_FILES" "" "" "$STOWED_SRCS"
  done
  PPM_CURRENT_PACKAGE=""
}

# Everything under $HOME but the sources, with what each link says
home_tree() {
  (cd "$HOME" && find . -path ./.local/share/anfs -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
    if [[ -L "$p" ]]; then echo "$p -> $(readlink "$p")"; else echo "$p"; fi
  done)
}
heads() { local a; for a in "$@"; do git -C "$S/$a" rev-parse HEAD; git -C "$S/$a" status --porcelain; done; }
inode() { ls -id "$1" | awk '{print $1}'; }

@test "an installed package: links relinked from the destination, relative; the tracker, claims, callback and backup follow" {
  tool
  inst a/tool
  local trk srcino
  trk=$(cat "$PPM_INSTALLED_DIR/a/tool.yml")
  srcino=$(inode "$HOME/.outside")
  _claim_set .x a/tool c/other
  _claim_set .y c/z a/tool
  anfs_callback_register ppm a/tool tool_changed
  mkdir -p "$PPM_STATE_HOME/backup"
  printf 'a/tool\t.foo\nc/z\t.bar\n' > "$PPM_STATE_HOME/backup/manifest"

  run cmd_move a/tool b
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved packages/tool: a -> b, 1 commit replayed"* ]]
  [ "$(readlink "$HOME/.toolrc")" = ".local/share/anfs/sources/b/packages/tool/home/.toolrc" ]
  [ "$(readlink "$HOME/.local/lib/tool")" = "../../.local/share/anfs/sources/b/packages/tool/home/.local/lib/tool" ]
  [ "$(cat "$HOME/.local/lib/tool/lib.sh")" = lib ]
  [ "$(inode "$HOME/.outside")" = "$srcino" ]
  [ ! -e "$PPM_INSTALLED_DIR/a" ]
  [ "$(cat "$PPM_INSTALLED_DIR/b/tool.yml")" = "$trk" ]
  [ "$(_claim_get .x claimant)" = b/tool ] && [ "$(_claim_get .x owner)" = c/other ]
  [ "$(_claim_get .y owner)" = b/tool ] && [ "$(_claim_get .y claimant)" = c/z ]
  [ "$(yq -r '."b/tool"' "$(anfs_callbacks_file ppm)")" = tool_changed ]
  [ "$(yq -r 'has("a/tool")' "$(anfs_callbacks_file ppm)")" = false ]
  [ "$(cat "$PPM_STATE_HOME/backup/manifest")" = "b/tool"$'\t'".foo"$'\n'"c/z"$'\t'".bar" ]
  [ ! -e "$MARK" ]
  [ ! -e "$S/a/packages/tool" ]

  PPM_SKIP_FILE=""
  _reset_skip_file
  run plan_package "$S/b/packages/tool"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s\n' "$output" | grep -v '^  keep ' || true)" ]
}

@test "a layered package: only the files its layer had are relinked; the shared one stays with the higher layer" {
  src user stack rws
  put user packages/git/package.yml "version: 0.1.0"
  put user packages/git/home/.gitconfig user
  put stack packages/git/package.yml "version: 0.1.0"
  put stack packages/git/home/.gitconfig stack
  put stack packages/git/home/.gitignore stack
  commit user git && commit stack git
  inst user/git stack/git
  run cmd_move stack/git rws
  [ "$status" -eq 0 ]
  [[ "$(readlink "$HOME/.gitconfig")" == *"/sources/user/packages/git/home/.gitconfig" ]]
  [[ "$(readlink "$HOME/.gitignore")" == *"/sources/rws/packages/git/home/.gitignore" ]]
  [ "$(meta_installed_files rws git)" = ".gitignore" ]
}

@test "a link replaced by a real file: refused before anything changes" {
  tool
  inst a/tool
  rm "$HOME/.toolrc" && echo mine > "$HOME/.toolrc"
  local before trees
  before=$(heads a b) trees=$(home_tree)
  run cmd_move a/tool b
  [ "$status" -eq 1 ]
  [[ "$output" == *"~/.toolrc is not a/tool's link any more (conflict"* ]]
  [[ "$output" == *"ppm install -f a/tool, or ppm file protect them, then move"* ]]
  [ "$(heads a b)" = "$before" ]
  [ "$(home_tree)" = "$trees" ]
  [ -f "$PPM_INSTALLED_DIR/a/tool.yml" ]
}

@test "the tree move fails (the origin's hook refuses): the links back into the origin, the tracker where it was" {
  tool
  inst a/tool
  printf '#!/bin/sh\nexit 1\n' > "$S/a/.git/hooks/pre-commit"
  chmod +x "$S/a/.git/hooks/pre-commit"
  local before trees
  before=$(heads a b) trees=$(home_tree)
  run cmd_move a/tool b
  [ "$status" -eq 1 ]
  [ "$(heads a b)" = "$before" ]
  [ "$(home_tree)" = "$trees" ]
  [ -f "$PPM_INSTALLED_DIR/a/tool.yml" ] && [ ! -e "$PPM_INSTALLED_DIR/b" ]
}

@test "not installed: the tree moves, the claims are renamed, no tracker, and how to install it is said" {
  tool
  _claim_set .x a/tool ""
  run cmd_move a/tool b
  [ "$status" -eq 0 ]
  [[ "$output" == *"a/tool was not installed: ppm install b/tool links it"* ]]
  [ -d "$S/b/packages/tool" ] && [ ! -e "$S/a/packages/tool" ]
  [ "$(_claim_get .x claimant)" = b/tool ]
  [ ! -e "$PPM_INSTALLED_DIR/b" ]
  [ ! -e "$HOME/.toolrc" ]
}

@test "core/ppm is refused without -f" {
  src core b
  put core packages/ppm/package.yml "version: 0.1.0"
  commit core ppm
  run cmd_move core/ppm b
  [ "$status" -eq 1 ]
  [[ "$output" == *"core/ppm is a base package"*"(-f to move it anyway)"* ]]
  [ -d "$S/core/packages/ppm" ]
}

@test "-n: the checks, the commits and ppm's steps; nothing changes" {
  tool
  inst a/tool
  _claim_set .x a/tool ""
  anfs_callback_register ppm a/tool tool_changed
  local before trees claims
  before=$(heads a b) trees=$(home_tree) claims=$(cat "$PPM_CLAIMS_FILE")
  dry_run=true
  run cmd_move a/tool b
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"$'\t'"package"$'\t'"a/packages/tool"* ]]
  [[ "$output" == *"commits"$'\t'"1 to replay from a"* ]]
  [[ "$output" == *"replay"$'\t'"ok"* ]]
  [[ "$output" == *"unlink   2 links into a/packages/tool (no remove hooks)"* ]]
  [[ "$output" == *"relink   2 links from b/packages/tool (no install hooks)"* ]]
  [[ "$output" == *"tracker  installed/a/tool.yml -> installed/b/tool.yml"* ]]
  [[ "$output" == *"claims   1 entry (claimant or owner a/tool)"* ]]
  [[ "$output" == *"callback ppm: a/tool -> b/tool"* ]]
  [ "$(heads a b)" = "$before" ]
  [ "$(home_tree)" = "$trees" ]
  [ "$(cat "$PPM_CLAIMS_FILE")" = "$claims" ]
  [ -f "$PPM_INSTALLED_DIR/a/tool.yml" ]
}
