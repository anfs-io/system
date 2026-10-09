#!/usr/bin/env bats
# lib/anfs/resolve.sh: finding resources in the sources that hold a tool's directory, and ordering
# them by dependency. One tool's directory stands in for all: the code never looks at which.
# Run: bats packages/anfs/tests/

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  # shellcheck source=/dev/null
  source "$lib/sources.sh"
  source "$lib/resolve.sh"

  T="$BATS_TEST_TMPDIR"
  GITSRC_USER_LIST="$T/user.list"
  GITSRC_SYSTEM_LIST="$T/system.list"
  GITSRC_REPOS_DIR="$T/sources"
  GITSRC_LINK_LOCAL=false
  # Priority order: hi, mid, lo
  printf 'file:///x/hi.git  hi\nfile:///x/mid.git  mid\nfile:///x/lo.git  lo\n' > "$GITSRC_USER_LIST"
}

# res <source> <name> [dep...]: a resource under things/, with its deps
res() {
  local dir="$T/sources/$1/things/$2" d
  mkdir -p "$dir"
  : > "$dir/deps"
  shift 2
  for d in "$@"; do echo "$d" >> "$dir/deps"; done
}
deps_of() { cat "$1/deps" 2>/dev/null || true; }

@test "sources: only the ones holding the directory, in priority order" {
  res hi a
  res lo b
  mkdir -p "$T/sources/mid/other"
  anfs_sources things
  [ "${ANFS_SRC_NAMES[*]}" = "hi lo" ]
  anfs_is_source lo
  ! anfs_is_source mid
}

@test "find: a name matches every layer; source/name only that one" {
  res hi a; res lo a
  anfs_sources things
  run anfs_find things a
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == 0$'\t'hi$'\t'* ]]
  run anfs_find things lo/a
  [ "${#lines[@]}" -eq 1 ]
  run anfs_find things nope
  [ "$status" -ne 0 ]
}

@test "list: every resource, or a source's" {
  res hi a; res lo b; res lo c
  anfs_sources things
  run anfs_list things
  [ "$output" = "$(printf 'hi/a\nlo/b\nlo/c')" ]
  run anfs_list things lo
  [ "$output" = "$(printf 'lo/b\nlo/c')" ]
}

@test "resolve: dependencies first, each once" {
  res hi app lib util
  res hi lib util
  res hi util
  anfs_sources things
  anfs_resolve things deps_of app
  [ "${ANFS_ORDER[*]}" = "hi/util hi/lib hi/app" ]
}

@test "resolve: layers land together, highest priority first" {
  res hi git
  res lo git
  anfs_sources things
  anfs_resolve things deps_of git
  [ "${ANFS_ORDER[*]}" = "hi/git lo/git" ]
}

@test "resolve: a dependency resolves to the same or a lower-priority source only" {
  res hi base
  res lo app base
  anfs_sources things
  run anfs_resolve things deps_of lo/app
  [ "$status" -ne 0 ]
  [[ "$output" == *"thing 'base' not found"* || "$output" == *"'base' not found"* ]]
}

@test "resolve: a dependency on a sibling layer is satisfied by the group" {
  res hi git lo/git
  res lo git
  anfs_sources things
  anfs_resolve things deps_of git
  [ "${ANFS_ORDER[*]}" = "hi/git lo/git" ]
}

@test "resolve: a cycle is fatal" {
  res hi a b
  res hi b a
  anfs_sources things
  run anfs_resolve things deps_of a
  [ "$status" -ne 0 ]
  [[ "$output" == *"circular dependency"* ]]
}

@test "resolve: ANFS_RESOLVE_FIRST takes one match per name, at or below the dependent" {
  res hi org
  res mid tech org
  res mid org
  res lo org
  anfs_sources things
  ANFS_RESOLVE_FIRST=true anfs_resolve things deps_of mid/tech
  [ "${ANFS_ORDER[*]}" = "mid/org mid/tech" ]
  ANFS_RESOLVE_FIRST=true anfs_resolve things deps_of org
  [ "${ANFS_ORDER[*]}" = "hi/org" ]
}

@test "resolve: ANFS_NAME_PARTS=2 takes ws/name as a name, and source/ws/name as qualified" {
  res hi main/tech main/org
  res lo main/org
  anfs_sources things
  ANFS_NAME_PARTS=2 run anfs_find things main/org
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == 1$'\t'lo$'\t'* ]]
  ANFS_NAME_PARTS=2 ANFS_RESOLVE_FIRST=true anfs_resolve things deps_of hi/main/tech
  [ "${ANFS_ORDER[*]}" = "lo/main/org hi/main/tech" ]
}
