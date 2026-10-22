#!/usr/bin/env bats
# ppm and a package.yml's links:, files: and platforms: (lib/anfs/manifest.sh): directory links,
# per-platform paths, links out of the tree, copies, what mise installs, and the refusals. ppm's
# libs and anfs's are sourced from this clone, with $HOME, the sources and the state in the temp
# dir; platform, brew and mise are stubs.
# Run: bats packages/ppm/tests/manifest.bats

teardown() { rm -f "${PPM_MSG_FILE:-}" "${PPM_SKIP_FILE:-}"; }

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
  source "$anfs/platform.sh"
  source "$anfs/link.sh"
  source "$anfs/manifest.sh"
  source "$anfs/files.sh"
  local bats_exit
  bats_exit=$(trap -p EXIT)
  source "$lib/core.sh"
  eval "$bats_exit"
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
  # no pull, no Homebrew, no real mise: mise's calls are logged
  update_ppm_if_needed() { :; }
  update_brew_if_needed() { :; }
  brew_missing() { :; }
  cask_missing() { :; }
  system_pkg_missing() { :; }
  MISELOG="$BATS_TEST_TMPDIR/mise.log"
  mise() { echo "$*" >> "$MISELOG"; }
  PLATFORM=macos
  platform() { echo "$PLATFORM"; }

  config=false force=false reinstall=false skip_deps=false yes=true dry_run=false
}

pkg() {
  local d="$ANFS_SOURCES_HOME/$1/packages/$2"
  mkdir -p "$d"
  shift 2
  { echo "version: 0.1.0"; printf '%s\n' "$@"; } > "$d/package.yml"
}
file() { mkdir -p "$(dirname "$ANFS_SOURCES_HOME/$1/packages/$2/home/$3")"; printf '%s\n' "$4" > "$ANFS_SOURCES_HOME/$1/packages/$2/home/$3"; }
tracker() { cat "$PPM_INSTALLED_DIR/$1.yml"; }
tracker_files() { yq -r '.files[]' "$PPM_INSTALLED_DIR/$1.yml"; }
src_of() { echo "$ANFS_SOURCES_HOME/$1/packages/$2/home/$3"; }

# --- directory links -------------------------------------------------------------------------

@test "a directory link: one link, one tracker entry; a file added upstream is there with no reinstall" {
  pkg stack lib "links: [.local/lib/x/]"
  file stack lib .local/lib/x/a.sh a
  file stack lib .local/bin/x x
  run cmd_install stack/lib
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/lib/x" ]
  [ "$(readlink "$HOME/.local/lib/x")" = ../../.local/share/anfs/sources/stack/packages/lib/home/.local/lib/x ]
  [ -L "$HOME/.local/bin/x" ]
  [ "$(tracker_files stack/lib | LC_ALL=C sort | tr '\n' ' ')" = ".local/bin/x .local/lib/x " ]
  file stack lib .local/lib/x/new.sh new
  [ "$(cat "$HOME/.local/lib/x/new.sh")" = new ]
  run cmd_install stack/lib
  [ "$status" -eq 0 ]
  dry_run=true run cmd_install stack/lib
  [[ "$output" == *"keep      ~/.local/lib/x"* ]]
}

@test "another package's file inside a directory link is a conflict, either order, and -f does not clear it" {
  pkg stack lib "links: [.local/lib/x/]"
  file stack lib .local/lib/x/a.sh a
  pkg stack other
  file stack other .local/lib/x/y.sh y
  cmd_install stack/lib >/dev/null
  run cmd_install stack/other
  [ "$status" -eq 1 ]
  [[ "$output" == *"inside a directory link: .local/lib/x -> stack/packages/lib/home/.local/lib/x: .local/lib/x/y.sh"* ]]
  force=true run cmd_install stack/other
  [ "$status" -eq 1 ]
  [ ! -e "$(src_of stack lib .local/lib/x/y.sh)" ]
  [ -L "$HOME/.local/lib/x" ]

  # the other order: the directory holds another package's links
  remover stack/lib >/dev/null
  [ ! -e "$HOME/.local/lib/x" ]
  cmd_install stack/other >/dev/null
  [ -L "$HOME/.local/lib/x/y.sh" ]
  run cmd_install stack/lib
  [ "$status" -eq 1 ]
  [[ "$output" == *"a directory, with links into another package: stack/packages/other/home/.local/lib/x/y.sh"* ]]
  force=true run cmd_install stack/lib
  [ "$status" -eq 1 ]
  [ -L "$HOME/.local/lib/x/y.sh" ] && [ ! -e "$PPM_STATE_HOME/backup" ]
}

@test "the per-file directory of an older install: -f moves it aside, then one link" {
  pkg stack lib "links: [.local/lib/x/]"
  file stack lib .local/lib/x/a.sh a
  mkdir -p "$HOME/.local/lib/x"
  ln -s ../../../.local/share/anfs/sources/stack/packages/lib/home/.local/lib/x/a.sh "$HOME/.local/lib/x/a.sh"
  run cmd_install stack/lib
  [ "$status" -eq 1 ]
  [[ "$output" == *"existing target is in the way (a directory): .local/lib/x"* ]]
  force=true run cmd_install stack/lib
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/lib/x" ]
  [ -L "$PPM_STATE_HOME/backup/files/.local/lib/x/a.sh" ]
}

@test "ppm file protect and claim refuse a path inside a directory link" {
  pkg stack lib "links: [.local/lib/x/]"
  file stack lib .local/lib/x/a.sh a
  cmd_install stack/lib >/dev/null
  run cmd_file protect "$HOME/.local/lib/x/a.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"~/.local/lib/x/a.sh is inside stack/lib's directory link ~/.local/lib/x"* ]]
  run cmd_file add user/mine "$HOME/.local/lib/x/a.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"inside stack/lib's directory link"* ]]
  [ "$(cat "$(src_of stack lib .local/lib/x/a.sh)")" = a ]
}

@test "remove takes the one link, with the tracker or without it" {
  pkg stack lib "links: [.local/lib/x/]"
  file stack lib .local/lib/x/a.sh a
  cmd_install stack/lib >/dev/null
  remover stack/lib >/dev/null
  [ ! -e "$HOME/.local/lib/x" ] && [ ! -L "$HOME/.local/lib/x" ]
  [ -f "$(src_of stack lib .local/lib/x/a.sh)" ]
  cmd_install stack/lib >/dev/null
  rm "$PPM_INSTALLED_DIR/stack/lib.yml"
  unstow_package "$ANFS_SOURCES_HOME/stack/packages/lib"
  [ ! -L "$HOME/.local/lib/x" ]
}

# --- platforms ---------------------------------------------------------------------------------

op_pkg() {
  pkg stack op "links:" \
    "  - {path: .ssh/config.d/99-op.conf, platforms: [macos]}" \
    "  - {path: .config/mise/conf.d/op.toml, platforms: [linux]}" \
    "  - {path: docs, platforms: [linux]}"
  file stack op .ssh/config.d/99-op.conf "Include x"
  file stack op .config/mise/conf.d/op.toml $'[tools]\n"aqua:1password/cli" = "latest"'
  file stack op docs/a.md a
  file stack op docs/sub/b.md b
  file stack op .local/bin/opm opm
}

@test "platform entries: macOS links the macos file, not the linux ones; -n says off; no mise install" {
  op_pkg
  dry_run=true run cmd_install stack/op
  [ "$status" -eq 0 ]
  [[ "$output" == *"link      ~/.ssh/config.d/99-op.conf"* ]]
  [[ "$output" == *"off       ~/.config/mise/conf.d/op.toml  (linux)"* ]]
  [[ "$output" == *"off       ~/docs  (linux)"* ]]
  run cmd_install stack/op
  [ "$status" -eq 0 ]
  [ -L "$HOME/.ssh/config.d/99-op.conf" ] && [ -L "$HOME/.local/bin/opm" ]
  [ ! -e "$HOME/.config/mise/conf.d/op.toml" ] && [ ! -e "$HOME/docs" ]
  [ ! -e "$MISELOG" ]
}

@test "platform entries: Debian and Fedora link the linux ones (a directory per file) and mise installs" {
  op_pkg
  PLATFORM=debian
  run cmd_install stack/op
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.ssh/config.d/99-op.conf" ]
  [ -L "$HOME/.config/mise/conf.d/op.toml" ]
  [ -d "$HOME/docs/sub" ] && [ ! -L "$HOME/docs" ] && [ -L "$HOME/docs/sub/b.md" ]
  [ "$(cat "$MISELOG")" = "install aqua:1password/cli" ]
  remover stack/op >/dev/null
  rm -f "$MISELOG"
  PLATFORM=fedora
  cmd_install stack/op >/dev/null
  [ -L "$HOME/.config/mise/conf.d/op.toml" ]
  [ "$(cat "$MISELOG")" = "install aqua:1password/cli" ]
}

@test "mise: a higher layer's toml replacing a lower one's: only the higher one's tools" {
  pkg user tool
  pkg stack tool
  file user tool .config/mise/conf.d/tool.toml $'[tools]\nmine = "1"'
  file stack tool .config/mise/conf.d/tool.toml $'[tools]\ntheirs = "1"'
  file stack tool .config/mise/conf.d/extra.toml $'[tools]\nextra = "1"'
  run cmd_install tool
  [ "$status" -eq 0 ]
  [ "$(cat "$MISELOG")" = "install mine extra" ]
}

@test "a macos/ directory beside home/ is never linked, and PPM_GROUP_ID changes nothing; no warning" {
  pkg stack host
  file stack host .hostrc h
  mkdir -p "$ANFS_SOURCES_HOME/stack/packages/host/macos/.config"
  echo old > "$ANFS_SOURCES_HOME/stack/packages/host/macos/.config/old"
  PPM_GROUP_ID=macos run cmd_install stack/host
  [ "$status" -eq 0 ]
  [[ "$output" != *"macos/"* && "$output" != *arning* ]]
  [ -L "$HOME/.hostrc" ] && [ ! -e "$HOME/.config/old" ]
  [ "$(tracker_files stack/host)" = .hostrc ]
}

# --- links out of the tree ---------------------------------------------------------------------

@test "src: a link out of the tree, relative, in the tracker's links; removed only while it points at src" {
  local vault="$BATS_TEST_TMPDIR/outside/apex"
  mkdir -p "$vault"
  pkg user obsidian "links: [{src: '$vault', dest: vaults/apex, platforms: [macos]}]"
  run cmd_install user/obsidian
  [ "$status" -eq 0 ]
  [ -L "$HOME/vaults/apex" ] && [[ "$(readlink "$HOME/vaults/apex")" == ../* ]]
  [ "$(cd -P "$HOME/vaults/apex" && pwd -P)" = "$(cd -P "$vault" && pwd -P)" ]
  [ "$(yq -r '.links[0].dest + " " + .links[0].src' "$PPM_INSTALLED_DIR/user/obsidian.yml")" = "vaults/apex $vault" ]
  dry_run=true run cmd_install user/obsidian
  [[ "$output" == *"keep      ~/vaults/apex  (-> $vault)"* ]]
  remover user/obsidian >/dev/null
  [ ! -L "$HOME/vaults/apex" ] && [ -d "$vault" ]

  # repointed by the user: left
  cmd_install user/obsidian >/dev/null
  rm "$HOME/vaults/apex"; ln -s "$BATS_TEST_TMPDIR" "$HOME/vaults/apex"
  remover user/obsidian >/dev/null
  [ -L "$HOME/vaults/apex" ]
}

@test "src: a missing src is said and not made; on another platform it is off" {
  pkg user obsidian "links: [{src: '$BATS_TEST_TMPDIR/nowhere', dest: vaults/apex}]"
  run cmd_install user/obsidian
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing src ~/vaults/apex -> $BATS_TEST_TMPDIR/nowhere (not linked)"* ]]
  [ ! -e "$HOME/vaults/apex" ] && [ ! -L "$HOME/vaults/apex" ]
  pkg user obsidian "links: [{src: '$BATS_TEST_TMPDIR/nowhere', dest: vaults/apex, platforms: [linux]}]"
  dry_run=true run cmd_install user/obsidian
  [[ "$output" == *"off       ~/vaults/apex  (linux)"* ]]
}

@test "src: a relative src is refused in a package.yml" {
  pkg user obsidian "links: [{src: ../vault}]"
  run cmd_install user/obsidian
  [[ "$output" == *"invalid package.yml, not installed"*"a src: here is absolute"* ]]
  [ ! -e "$PPM_INSTALLED_DIR/user/obsidian.yml" ]
}

# --- files: ------------------------------------------------------------------------------------

@test "files: copied once; edited: left, -n says differs; deleted: copied again; remove leaves it" {
  pkg stack conf "files: [.config/conf/defaults.conf]"
  file stack conf .config/conf/defaults.conf defaults
  file stack conf .confrc rc
  cmd_install stack/conf >/dev/null
  [ -f "$HOME/.config/conf/defaults.conf" ] && [ ! -L "$HOME/.config/conf/defaults.conf" ]
  [ "$(tracker_files stack/conf)" = .confrc ]
  echo mine > "$HOME/.config/conf/defaults.conf"
  cmd_install stack/conf >/dev/null
  [ "$(cat "$HOME/.config/conf/defaults.conf")" = mine ]
  dry_run=true run cmd_install stack/conf
  [[ "$output" == *"differs   ~/.config/conf/defaults.conf  (yours; left as is)"* ]]
  rm "$HOME/.config/conf/defaults.conf"
  dry_run=true run cmd_install stack/conf
  [[ "$output" == *"copy      ~/.config/conf/defaults.conf"* ]]
  cmd_install stack/conf >/dev/null
  [ "$(cat "$HOME/.config/conf/defaults.conf")" = defaults ]
  remover stack/conf >/dev/null
  [ "$(cat "$HOME/.config/conf/defaults.conf")" = defaults ] && [ ! -e "$HOME/.confrc" ]
}

@test "files: in the way stops the install in the same block as the links' conflicts; -f moves it aside and copies" {
  pkg stack conf "files: [.config/conf/defaults.conf]"
  file stack conf .config/conf/defaults.conf defaults
  file stack conf .confrc rc
  mkdir -p "$HOME/.config/conf/defaults.conf"
  echo mine > "$HOME/.confrc"
  run cmd_install stack/conf
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING! stowing stack/conf would cause conflicts:"*"(a file): .confrc"*"(a directory): .config/conf/defaults.conf"*"All operations aborted."* ]]
  [ ! -L "$HOME/.confrc" ]
  force=true run cmd_install stack/conf
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.config/conf/defaults.conf")" = defaults ]
  [ -d "$PPM_STATE_HOME/backup/files/.config/conf/defaults.conf" ]
}

@test "files: a protected path is skipped" {
  pkg stack conf "files: [.config/conf/defaults.conf]"
  file stack conf .config/conf/defaults.conf defaults
  _protected_add .config/conf/defaults.conf
  _reset_skip_file
  run cmd_install stack/conf
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/conf/defaults.conf" ]
}

# --- validation --------------------------------------------------------------------------------

@test "an invalid links: stops that package's install with every error; the others in the run install" {
  pkg stack bad "links: [.badrc, {path: nowhere, platforms: [beos]}]"
  file stack bad .badrc b
  pkg stack good "depends: [bad]"
  file stack good .goodrc g
  run cmd_install stack/good
  [ "$status" -eq 0 ]
  [[ "$output" == *"[stack/bad] ERROR: invalid package.yml, not installed:"* ]]
  [[ "$output" == *"says nothing the default does not: .badrc"* ]]
  [[ "$output" == *"unknown platform (beos)"* ]]
  [ ! -e "$HOME/.badrc" ] && [ ! -e "$PPM_INSTALLED_DIR/stack/bad.yml" ]
  [ -L "$HOME/.goodrc" ]
  dry_run=true run cmd_install stack/bad
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid package.yml: not installed"* ]]
}

@test "ppm show: the entries, their platforms and state" {
  op_pkg
  cmd_install stack/op >/dev/null
  run cmd_show stack/op
  [ "$status" -eq 0 ]
  [[ "$output" == *"Placed:"* ]]
  [[ "$output" == *"link     ~/.ssh/config.d/99-op.conf  [macos]  (ok)"* ]]
  [[ "$output" == *"link     ~/.config/mise/conf.d/op.toml  [linux]  (off here)"* ]]
}
