#!/usr/bin/env bats
# What -f moves out of stow's way: backed up under the state dir, put back on remove and implode.
# ppm's core libs are sourced from this clone, with $HOME, sources and state in the temp dir.
# Run: bats packages/ppm/tests/

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/ppm"
  local anfs="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"

  command -v stow >/dev/null || skip "stow is not installed"

  export HOME="$BATS_TEST_TMPDIR/home"
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
  source "$lib/core.sh"
  source "$lib/packages.sh"
  source "$lib/installer.sh"

  BACKUP="$PPM_STATE_HOME/backup"
  PKG="$ANFS_SOURCES_HOME/stack/packages/tool"
  mkdir -p "$PKG/home/.config/tool"
  echo "from the package" > "$PKG/home/.config/tool/rc"
  PPM_IGNORE_ARGS=()
  PPM_CURRENT_PACKAGE=stack/tool
}

messages() { cat "$PPM_MSG_FILE" 2>/dev/null; }

# Stow the package's home/ the way `ppm install -f` does
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
  PPM_IGNORE_ARGS=()
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
  PPM_IGNORE_ARGS=("$(_stow_ignore_arg .config/tool/rc)")
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
