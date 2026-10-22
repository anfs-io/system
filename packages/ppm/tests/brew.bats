#!/usr/bin/env bats
# update_brew_if_needed (lib/ppm/platform.sh): `brew update` at most every
# PPM_BREW_UPDATE_CACHE_DURATION seconds (ppm.env; default 86400). brew is a stub that logs.
# Run: bats packages/ppm/tests/brew.bats

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/ppm"
  local anfs="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"
  mkdir -p "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/bin"
  export HOME=$(cd -P "$BATS_TEST_TMPDIR/home" && pwd -P)
  export ANFS_LOG=off
  unset PPM_BREW_UPDATE_CACHE_DURATION HOMEBREW_UPDATE_CACHE_DURATION
  PPM_CACHE_HOME="$HOME/.cache/ppm"
  LOG="$BATS_TEST_TMPDIR/brew.log"
  printf '#!/bin/sh\necho "brew $*" >> "%s"\n' "$LOG" > "$BATS_TEST_TMPDIR/bin/brew"
  chmod +x "$BATS_TEST_TMPDIR/bin/brew"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  source "$anfs/log.sh"
  local bats_exit
  bats_exit=$(trap -p EXIT)
  source "$lib/core.sh"
  eval "$bats_exit"
  source "$anfs/platform.sh"
  source "$lib/platform.sh"
  brew_is_owner() { return 0; }
  mkdir -p "$PPM_CACHE_HOME"
}

teardown() { rm -f "${PPM_MSG_FILE:-}"; }

stamp() { echo $(( $(date +%s) - $1 )) > "$PPM_CACHE_HOME/brew_last_update"; }

@test "no stamp: brew update runs and the stamp is written" {
  update_brew_if_needed
  [ "$(cat "$LOG")" = "brew update" ]
  [ -s "$PPM_CACHE_HOME/brew_last_update" ]
}

@test "the default is a day: an hour-old stamp runs nothing, a two-day-old one updates" {
  stamp 3600
  update_brew_if_needed
  [ ! -e "$LOG" ]
  stamp 172800
  update_brew_if_needed
  [ "$(cat "$LOG")" = "brew update" ]
}

@test "PPM_BREW_UPDATE_CACHE_DURATION sets the interval; HOMEBREW_UPDATE_CACHE_DURATION is not read" {
  stamp 120
  PPM_BREW_UPDATE_CACHE_DURATION=60 update_brew_if_needed
  [ "$(cat "$LOG")" = "brew update" ]
  rm -f "$LOG"
  stamp 120
  HOMEBREW_UPDATE_CACHE_DURATION=60 update_brew_if_needed
  [ ! -e "$LOG" ]
}
