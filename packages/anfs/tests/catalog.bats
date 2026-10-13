#!/usr/bin/env bats
# lib/anfs/catalog.sh: the definitions of one kind across the sources, and resolving a name to
# one. pcm (services) and pmm (images, machines) are its users; their own suites cover it through them.
# Run: bats packages/anfs/tests/

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  export ANFS_LOG=off
  CLI_TOOL=tool
  # shellcheck source=/dev/null
  source "$lib/log.sh"
  source "$lib/sources.sh"
  source "$lib/catalog.sh"

  T="$BATS_TEST_TMPDIR"
  GITSRC_USER_LIST="$T/user.list"
  GITSRC_SYSTEM_LIST="$T/system.list"
  GITSRC_REPOS_DIR="$T/sources"
  GITSRC_LINK_LOCAL=false
  # Priority order: hi, lo; `plain` has no things/ at all
  printf 'file:///x/hi.git  hi\nfile:///x/lo.git  lo\nfile:///x/plain.git  plain\n' > "$GITSRC_USER_LIST"
  mkdir -p "$T/sources/plain"
  thing mine "$T/local"
  thing web "$T/sources/hi/things"
  thing web "$T/sources/lo/things"
  thing db "$T/sources/lo/things"
  mkdir -p "$T/sources/lo/things/not-one"
  catalog_load things thing.yml local "$T/local"
}

# thing <name> <dir>: a definition, a directory with the marker file
thing() { mkdir -p "$2/$1"; : > "$2/$1/thing.yml"; }

@test "load: the local place first, then the sources that hold the kind, in priority order" {
  [ "${SRC_NAMES[*]}" = "local hi lo" ]
  [ "$(catalog_source_dir lo)" = "$T/sources/lo/things" ]
  [ "$(catalog_source_index local)" = 0 ]
  [ "$(catalog_source_index lo)" = 2 ]
  [ "$(catalog_source_index plain)" = 9999 ]
  run catalog_source_dir plain
  [ "$status" -eq 1 ]
}

@test "a source whose alias is the local one is ignored, and said so" {
  printf 'file:///x/local.git  local\n' >> "$GITSRC_USER_LIST"
  mkdir -p "$T/sources/local/things"
  run catalog_load things thing.yml local "$T/local"
  [[ "$output" == *"ignoring source alias 'local'"* ]]
}

@test "canon: a plain name is the highest-priority source that has it; source/name is itself" {
  [ "$(catalog_canon web)" = hi/web ]
  [ "$(catalog_canon lo/web)" = lo/web ]
  [ "$(catalog_canon mine)" = local/mine ]
  [ "$(catalog_canon db)" = lo/db ]
  [ "$(catalog_dir lo/db)" = "$T/sources/lo/things/db" ]
}

@test "canon refuses what is not a definition: unknown, without the marker, or too deep" {
  run catalog_canon nope
  [ "$status" -eq 1 ]
  run catalog_canon lo/not-one
  [ "$status" -eq 1 ]
  run catalog_canon hi/db
  [ "$status" -eq 1 ]
  run catalog_canon a/b/c
  [ "$status" -eq 1 ]
  run catalog_canon ""
  [ "$status" -eq 1 ]
}

@test "canon from a priority index: only that source or lower ones" {
  [ "$(catalog_canon web 2)" = lo/web ]
  run catalog_canon hi/web 2
  [ "$status" -eq 1 ]
  run catalog_canon mine 1
  [ "$status" -eq 1 ]
}

@test "all_ids has every definition, shadowed ones too; effective_ids one per name" {
  run catalog_all_ids
  [ "${lines[*]}" = "local/mine hi/web lo/db lo/web" ]
  run catalog_effective_ids
  [ "${lines[*]}" = "local/mine hi/web lo/db" ]
}
