#!/usr/bin/env bats
# What -f moves out of the way: backed up under the state dir, put back on remove and implode. And
# how ppm links a package (stow_subdir over lib/anfs/link.sh): layers, conflicts, taking over what
# stow linked. ppm's core libs are sourced from this clone, with $HOME, sources and state in the
# temp dir.
# Run: bats packages/ppm/tests/

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/ppm"
  local anfs="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"

  # canonical, as the paths the linker compares are (macOS: /var is /private/var)
  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME=$(cd -P "$BATS_TEST_TMPDIR/home" && pwd -P)
  ANFS_SOURCES_HOME="$HOME/.local/share/anfs/sources"
  PPM_STATE_HOME="$HOME/.local/state/ppm"
  PPM_INSTALLED_DIR="$PPM_STATE_HOME/installed"
  export ANFS_STATE_HOME="$HOME/.local/state/anfs"
  mkdir -p "$PPM_INSTALLED_DIR"
  export ANFS_LOG=off
  CLI_TOOL=ppm

  # shellcheck source=/dev/null
  source "$anfs/log.sh"
  source "$anfs/callbacks.sh"
  source "$anfs/link.sh"
  source "$lib/core.sh"
  source "$lib/packages.sh"
  source "$lib/file.sh"
  source "$lib/installer.sh"

  BACKUP="$PPM_STATE_HOME/backup"
  PKG="$ANFS_SOURCES_HOME/stack/packages/tool"
  mkdir -p "$PKG/home/.config/tool"
  echo "from the package" > "$PKG/home/.config/tool/rc"
  PPM_SKIP_FILE=""
  _reset_skip_file
  PPM_CURRENT_PACKAGE=stack/tool
}

messages() { cat "$PPM_MSG_FILE" 2>/dev/null; }

# Link the package's home/ the way `ppm install -f` does
force_stow() { force=true stow_subdir "$PKG" home; }

mine() {
  mkdir -p "$HOME/.config/tool"
  echo "${1:-mine}" > "$HOME/.config/tool/rc"
}

@test "-f moves a real file to the backup dir and records it against the package" {
  mine
  force_stow

  [ -L "$HOME/.config/tool/rc" ]
  [ "$(cat "$BACKUP/files/.config/tool/rc")" = "mine" ]
  [ "$(cat "$BACKUP/manifest")" = "stack/tool"$'\t'".config/tool/rc" ]
  [[ "$(messages)" == *"Moved your existing ~/.config/tool/rc aside"* ]]
}

@test "removing the package puts the file back and clears the manifest" {
  mine
  force_stow
  unstow_package "$PKG"
  _backup_restore stack/tool

  [ ! -L "$HOME/.config/tool/rc" ]
  [ "$(cat "$HOME/.config/tool/rc")" = "mine" ]
  [ ! -e "$BACKUP/manifest" ]
  [ ! -e "$BACKUP/files/.config/tool/rc" ]
}

@test "another package's backups are left alone" {
  mine
  force_stow
  unstow_package "$PKG"
  _backup_restore stack/other

  [ ! -e "$HOME/.config/tool/rc" ]
  [ -e "$BACKUP/files/.config/tool/rc" ]
  [ -s "$BACKUP/manifest" ]
}

@test "a second -f keeps the first backup: it is the pre-ppm original" {
  mine original
  force_stow
  unstow_package "$PKG"
  mine later
  _reset_skip_file
  force_stow

  [ "$(cat "$BACKUP/files/.config/tool/rc")" = "original" ]
  [ "$(cat "$BACKUP/files/.config/tool/rc.1")" = "later" ]
  [ "$(wc -l < "$BACKUP/manifest" | tr -d ' ')" = "1" ]
}

@test "a link into the sources is ppm's own: deleted, not backed up" {
  local other="$ANFS_SOURCES_HOME/stack/packages/old/home/.config/tool"
  mkdir -p "$other" "$HOME/.config/tool"
  echo old > "$other/rc"
  ln -s "$other/rc" "$HOME/.config/tool/rc"
  force_stow

  [ "$(cat "$HOME/.config/tool/rc")" = "from the package" ]
  [ ! -e "$BACKUP" ]
}

@test "a link to somewhere else is the user's: backed up as a link" {
  mkdir -p "$HOME/.config/tool" "$HOME/dotfiles"
  echo theirs > "$HOME/dotfiles/rc"
  ln -s "$HOME/dotfiles/rc" "$HOME/.config/tool/rc"
  force_stow

  [ -L "$BACKUP/files/.config/tool/rc" ]
  [ "$(cat "$BACKUP/files/.config/tool/rc")" = "theirs" ]
}

@test "a protected (ignored) file is neither backed up nor replaced" {
  mine
  echo .config/tool/rc > "$PPM_SKIP_FILE"
  force_stow

  [ "$(cat "$HOME/.config/tool/rc")" = "mine" ]
  [ ! -e "$BACKUP" ]
}

@test "a path that is taken keeps its backup, until implode lands it beside as .pre-ppm" {
  mine
  force_stow

  _backup_restore stack/tool
  [ -L "$HOME/.config/tool/rc" ]
  [ -e "$BACKUP/files/.config/tool/rc" ]
  [ -s "$BACKUP/manifest" ]

  _backup_restore "" .pre-ppm
  [ "$(cat "$HOME/.config/tool/rc.pre-ppm")" = "mine" ]
  [ ! -e "$BACKUP/manifest" ]
}

@test "restore with nothing backed up does nothing" {
  run _backup_restore stack/tool
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "without -f, every file in the way is named and nothing is linked" {
  echo two > "$PKG/home/.config/tool/two"
  echo free > "$PKG/home/.config/tool/free"
  mine
  echo mine > "$HOME/.config/tool/two"
  force=false run stow_subdir "$PKG" home
  [ "$status" -eq 1 ]
  [[ "$output" == *"WARNING! stowing stack/tool would cause conflicts:"* ]]
  [[ "$output" == *"existing target is in the way (a file): .config/tool/rc"* ]]
  [[ "$output" == *"existing target is in the way (a file): .config/tool/two"* ]]
  [ ! -e "$HOME/.config/tool/free" ]
  [ ! -e "$BACKUP" ]
}

@test "a dangling link into the sources is replaced without -f (a file moved between packages)" {
  mkdir -p "$HOME/.config/tool"
  ln -s ../../.local/share/anfs/sources/stack/packages/gone/home/.config/tool/rc "$HOME/.config/tool/rc"
  force=false stow_subdir "$PKG" home
  [ "$(cat "$HOME/.config/tool/rc")" = "from the package" ]
}

@test "layers: the higher layer's files are skipped by exact name, + and . included" {
  local user="$ANFS_SOURCES_HOME/user/packages/tool"
  mkdir -p "$user/home/.config/tool"
  echo user > "$user/home/.config/tool/rc"
  echo user > "$user/home/.config/tool/a+b.c"
  echo stack > "$PKG/home/.config/tool/a+b.c"
  echo stack > "$PKG/home/.config/tool/aab.c"
  echo stack > "$PKG/home/.config/tool/a+bxc"
  force=false stow_package "$user"
  [ "$(sort <<< "$STOWED_FILES")" = "$(printf '%s\n' .config/tool/a+b.c .config/tool/rc)" ]
  force=false stow_package "$PKG"
  [ "$(sort <<< "$STOWED_FILES")" = "$(printf '%s\n' .config/tool/a+bxc .config/tool/aab.c)" ]
  [ "$(cat "$HOME/.config/tool/rc")" = user ]
  [ "$(cat "$HOME/.config/tool/a+b.c")" = user ]
  [ "$(cat "$HOME/.config/tool/aab.c")" = stack ]
  [ "$(cat "$HOME/.config/tool/a+bxc")" = stack ]
}

@test "README.md and .gitignore under home/ are linked; .DS_Store is not" {
  echo readme > "$PKG/home/README.md"
  echo ignore > "$PKG/home/.config/tool/.gitignore"
  echo junk > "$PKG/home/.config/tool/.DS_Store"
  force=false stow_package "$PKG"
  [ -L "$HOME/README.md" ] && [ -L "$HOME/.config/tool/.gitignore" ]
  [ ! -e "$HOME/.config/tool/.DS_Store" ]
  [[ "$STOWED_FILES" == *README.md* ]] && [[ "$STOWED_FILES" != *.DS_Store* ]]
}

@test "an install stow made is taken over with no link rewritten" {
  command -v stow >/dev/null || skip "stow is not installed"
  mkdir -p "$PKG/home/.local/bin"
  echo bin > "$PKG/home/.local/bin/tool"
  stow --no-folding -d "$PKG" -t "$HOME" home
  local before after
  before=$(ls -li "$HOME/.config/tool/rc" "$HOME/.local/bin/tool" | awk '{print $1}')
  force=false stow_package "$PKG"
  after=$(ls -li "$HOME/.config/tool/rc" "$HOME/.local/bin/tool" | awk '{print $1}')
  [ "$before" = "$after" ]
}

@test "unstow_package takes the tracker's files, or the package's tree with no tracker" {
  echo x > "$PKG/home/.config/tool/extra"
  force=false stow_package "$PKG"
  # a tracker that lists rc only: extra stays
  mkdir -p "$PPM_INSTALLED_DIR/stack"
  printf 'version: 1\nfiles:\n  - .config/tool/rc\n' > "$PPM_INSTALLED_DIR/stack/tool.yml"
  unstow_package "$PKG"
  [ ! -e "$HOME/.config/tool/rc" ] && [ -L "$HOME/.config/tool/extra" ]
  rm "$PPM_INSTALLED_DIR/stack/tool.yml"
  unstow_package "$PKG"
  [ ! -L "$HOME/.config/tool/extra" ]
}

@test "meta_cleanup_stale unlinks what the tracker had and the package no longer ships" {
  echo x > "$PKG/home/.config/tool/old"
  force=false stow_package "$PKG"
  mkdir -p "$PPM_INSTALLED_DIR/stack"
  printf 'version: 1\nfiles:\n  - .config/tool/rc\n  - .config/tool/old\n' > "$PPM_INSTALLED_DIR/stack/tool.yml"
  rm "$PKG/home/.config/tool/old"
  meta_cleanup_stale stack tool "$PKG" ".config/tool/rc"
  [ ! -L "$HOME/.config/tool/old" ] && [ -L "$HOME/.config/tool/rc" ]
}
