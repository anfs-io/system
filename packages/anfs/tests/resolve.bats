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

@test "find: ANFS_NAME_NEST takes the first segment as the source only when it is one" {
  res hi main/tech
  res lo main/org
  anfs_sources things
  ANFS_NAME_NEST=true run anfs_find things main/org
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == 1$'\t'lo$'\t'* ]]
  ANFS_NAME_NEST=true run anfs_find things lo/main/org
  [ "${lines[0]}" = 1$'\t'lo$'\t'"$T/sources/lo/things/main/org" ]
  ANFS_NAME_NEST=true run anfs_find things hi/main/org
  [ "$status" -ne 0 ]
  # a source's alone is no name without a marker
  ANFS_NAME_NEST=true run anfs_find things hi
  [ "$status" -ne 0 ]
}

@test "find: ANFS_RESOLVE_MARKER skips a directory without it; the source alone is its own directory" {
  res hi a/b/c
  touch "$T/sources/hi/things/a/b/c/marker"
  touch "$T/sources/hi/things/marker"
  anfs_sources things
  ANFS_NAME_NEST=true ANFS_RESOLVE_MARKER=marker run anfs_find things hi/a/b
  [ "$status" -ne 0 ]
  ANFS_NAME_NEST=true ANFS_RESOLVE_MARKER=marker run anfs_find things a/b/c
  [[ "${lines[0]}" == 0$'\t'hi$'\t'"$T/sources/hi/things/a/b/c" ]]
  ANFS_NAME_NEST=true ANFS_RESOLVE_MARKER=marker run anfs_find things hi
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 0$'\t'hi$'\t'"$T/sources/hi/things" ]
  ANFS_NAME_NEST=true ANFS_RESOLVE_MARKER=marker run anfs_find things mid
  [ "$status" -ne 0 ]
}

@test "resolve: nested names order as source/path, and a source alone as its alias" {
  res hi main/tech main/org lo
  res lo main/org
  touch "$T/sources/hi/things/main/tech/marker" "$T/sources/lo/things/main/org/marker" "$T/sources/lo/things/marker"
  anfs_sources things
  ANFS_NAME_NEST=true ANFS_RESOLVE_MARKER=marker ANFS_RESOLVE_FIRST=true anfs_resolve things deps_of hi/main/tech
  [ "${ANFS_ORDER[*]}" = "lo/main/org lo hi/main/tech" ]
  [ "${ANFS_ORDER_DIRS[1]}" = "$T/sources/lo/things" ]
}

@test "find: without ANFS_NAME_NEST a spec with a / is qualified, as before" {
  res hi git
  res lo git
  anfs_sources things
  run anfs_find things lo/git
  [ "${#lines[@]}" -eq 1 ]
  run anfs_find things git
  [ "${#lines[@]}" -eq 2 ]
}
