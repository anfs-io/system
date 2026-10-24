#!/usr/bin/env bats
# The package.* events (lib/ppm/installer.sh over lib/anfs/events.sh): the real ppm in a temp
# $HOME, its libraries linked from this clone, one local source (t) with a package; PATH is stubs
# (brew, which does nothing) and links to yq and bash 5, then the system dirs. Events go to the
# host scope's log under the temp $HOME.
# Run: bats packages/ppm/tests/events.bats

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

setup() {
  local pkgs
  pkgs="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  PKGS="$pkgs"
  PPM="$pkgs/ppm/home/.local/bin/ppm"
  T=$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)
  export HOME="$T/home"
  mkdir -p "$HOME/.local/lib" "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources" \
    "$HOME/.local/state/ppm/installed" "$T/bin"
  ln -s "$pkgs/anfs/home/.local/lib/anfs" "$HOME/.local/lib/anfs"
  ln -s "$pkgs/ppm/home/.local/lib/ppm" "$HOME/.local/lib/ppm"
  ln -s "$(command -v yq)" "$T/bin/yq"
  ln -s "$(command -v bash)" "$T/bin/bash"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/brew"
  chmod +x "$T/bin/brew"
  # The source t: a local path, linked where anfs keeps its sources
  SRC="$T/srcs/t"
  pkg hello 1.0.0
  ln -s "$SRC" "$HOME/.local/share/anfs/sources/t"
  printf '%s  t\n' "$SRC" > "$HOME/.config/anfs/user.list"
  : > "$HOME/.config/anfs/system.list"
  LOG="$HOME/.local/state/anfs/events/host"
}

# A package <name> at <version> in t, with one file to link
pkg() {
  mkdir -p "$SRC/packages/$1/home/.config/$1"
  printf 'version: %s\n' "$2" > "$SRC/packages/$1/package.yml"
  echo "$1" > "$SRC/packages/$1/home/.config/$1/conf"
}

# ppm in a clean environment (no ANFS_WORK, ANFS_EVENTS_SPOOL or ANFS_EVENTS from the caller)
ppm() {
  env -i HOME="$HOME" PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" USER=tester TMPDIR="$T" \
    ANFS_LOG=off ANFS_ACTOR=shell:t "$PPM" "$@" </dev/null
}

# The log's events, one line each: type subject data (k=v, in order)
events() {
  cat "$LOG"/*.jsonl 2>/dev/null |
    yq -p json -oy -r '.type + " " + .subject + " " + (.data | to_entries | map(.key + "=" + .value) | join(" "))' |
    grep -v '^---$' || true
}

@test "install emits package.installed (from empty), again from the version before, remove package.removed" {
  run ppm install t/hello
  [ "$status" -eq 0 ]
  [ -L "$HOME/.config/hello/conf" ]
  [ "$(events)" = "io.anfs.package.installed t/hello package=hello source=t version=1.0.0 from=" ]
  # the envelope: host scope, the actor, the profile
  run yq -p json -oy -r '[.source, .actor, .specversion, .anfsv] | join(" ")' "$LOG"/*.jsonl
  [ "$output" = "/anfs/host shell:t 1.0 1" ]

  pkg hello 1.1.0
  run ppm install t/hello
  [ "$status" -eq 0 ]
  [ "$(events | sed -n 2p)" = "io.anfs.package.installed t/hello package=hello source=t version=1.1.0 from=1.0.0" ]

  run ppm remove -y t/hello
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/hello/conf" ]
  [ "$(events | sed -n 3p)" = "io.anfs.package.removed t/hello package=hello source=t version=1.1.0" ]
  [ "$(events | wc -l | tr -d ' ')" = 3 ]
}

@test "one event per package, its dependency's included; not per file" {
  pkg dep 0.1.0
  echo more > "$SRC/packages/dep/home/.config/dep/two"
  printf 'version: 2.0.0\ndepends: [dep]\n' > "$SRC/packages/hello/package.yml"
  run ppm install t/hello
  [ "$status" -eq 0 ]
  [ "$(events)" = "io.anfs.package.installed t/dep package=dep source=t version=0.1.0 from=
io.anfs.package.installed t/hello package=hello source=t version=2.0.0 from=" ]
}

@test "-n, list, show and help emit nothing" {
  run ppm install -n t/hello
  [ "$status" -eq 0 ]
  ppm list >/dev/null
  ppm show hello >/dev/null
  ppm --help >/dev/null
  ppm help install >/dev/null
  [ ! -e "$LOG" ]
  # removing what is not installed is no removal
  run ppm remove -y t/hello
  [ ! -e "$LOG" ]
}

@test "something in the way: package.failed (step link), and the run stops" {
  mkdir -p "$HOME/.config/hello"
  echo mine > "$HOME/.config/hello/conf"
  run ppm install t/hello
  [ "$status" -eq 1 ]
  [ "$(events)" = "io.anfs.package.failed t/hello package=hello source=t step=link error=something is in the way" ]
}

@test "a pre_remove that refuses: package.failed (step pre_remove), nothing removed" {
  ppm install t/hello >/dev/null
  printf 'pre_remove() { return 1; }\n' > "$SRC/packages/hello/install.sh"
  run ppm remove -y t/hello
  [ "$status" -eq 1 ]
  [ "$(events | sed -n 2p)" = "io.anfs.package.failed t/hello package=hello source=t step=pre_remove error=pre_remove refused" ]
  [ -L "$HOME/.config/hello/conf" ]
}

@test "implode emits package.removed for each package, a gone package's included" {
  pkg other 0.2.0
  ppm install t/hello t/other >/dev/null
  # other's package is gone: implode undoes its tracker
  rm -rf "$SRC/packages/other"
  run ppm implode -y
  [ "$status" -eq 0 ]
  run events
  [[ "$output" == *"io.anfs.package.removed t/hello package=hello source=t version=1.0.0"* ]]
  [[ "$output" == *"io.anfs.package.removed t/other package=other source=t version=0.2.0"* ]]
  [ "$(events | grep -c package.removed)" = 2 ]
}

@test "ANFS_EVENTS=off, or events.sh not there: installs and removes, and emits nothing" {
  run env -i HOME="$HOME" PATH="$T/bin:/usr/bin:/bin" USER=tester TMPDIR="$T" ANFS_LOG=off ANFS_EVENTS=off \
    "$PPM" install t/hello </dev/null
  [ "$status" -eq 0 ]
  [ ! -e "$LOG" ]
  ppm remove -y t/hello >/dev/null
  rm -rf "$HOME/.local/state/anfs/events"
  # lib/anfs without events.sh
  rm "$HOME/.local/lib/anfs"
  mkdir "$HOME/.local/lib/anfs"
  local f
  for f in "$PKGS"/anfs/home/.local/lib/anfs/*; do
    [[ "${f##*/}" == events.sh ]] || ln -s "$f" "$HOME/.local/lib/anfs/${f##*/}"
  done
  run ppm install t/hello
  [ "$status" -eq 0 ]
  [ -L "$HOME/.config/hello/conf" ]
  run ppm remove -y t/hello
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/hello/conf" ]
  [ ! -e "$HOME/.local/state/anfs/events" ]
}
