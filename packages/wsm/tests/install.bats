#!/usr/bin/env bats
# install: putting spaces from anfs sources in place — spaces/<name>/space.yml, dependencies
# first, then the resources each declares. Everything clones over file:// from bare repos in the
# test temp dir — no network.
# Run: bats packages/wsm/tests/install.bats

load helper
setup() {
  wsm_setup
  mksource acme >/dev/null
}

@test "a space with no space.yml is created and registered at spaces/<name>" {
  mkdir -p "$BATS_TEST_TMPDIR/srcs/acme/spaces/plain"
  run wsm install acme/plain
  [ "$status" -eq 0 ]
  [ -f "$HOME/spaces/plain/.wsm/id" ]
  [ "$(entries)" -eq 1 ]
  [ "$(field "$HOME/spaces/plain" 2)" = plain ]
}

@test "path: puts the space where it says, and the source is recorded" {
  space_def acme tech <<'YML'
path: work/acme/tech
YML
  run wsm install tech
  [ "$status" -eq 0 ]
  [ -f "$HOME/work/acme/tech/.wsm/id" ]
  [ "$(cat "$HOME/work/acme/tech/.wsm/source")" = acme/tech ]
}

@test "dependencies are installed first" {
  space_def acme org <<'YML'
path: spaces/acme/org
YML
  space_def acme tech <<'YML'
path: spaces/acme/tech
depends: [org]
YML
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme/org"*"space acme/tech"* ]]
  [ -f "$HOME/spaces/acme/org/.wsm/id" ]
  [ -f "$HOME/spaces/acme/tech/.wsm/id" ]
}

@test "source/ installs every space in the source" {
  space_def acme org <<'YML'
path: spaces/acme/org
YML
  space_def acme marketing <<'YML'
path: spaces/acme/marketing
depends: [org]
YML
  run wsm install acme/
  [ "$status" -eq 0 ]
  [ "$(entries)" -eq 2 ]
}

@test "an unknown space or dependency fails before anything is created" {
  space_def acme tech <<'YML'
depends: [nope]
YML
  run wsm install acme/tech
  [ "$status" -ne 0 ]
  [[ "$output" == *"space 'nope' not found"* ]]
  [ ! -e "$HOME/spaces/tech" ]
}

@test "a path outside \$HOME is refused" {
  space_def acme bad <<'YML'
path: ../escaped
YML
  run wsm install acme/bad
  [ "$status" -ne 0 ]
  [ ! -e "$HOME/../escaped" ]
}

@test "it clones every declared repo" {
  local a b
  a=$(mkbare alpha); b=$(mkbare beta)
  space_def acme space <<YML
path: space
resources:
  - type: repo
    url: $a
    path: repos/alpha
  - type: repo
    url: $b
    path: repos/beta
YML
  run wsm install acme/space
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloned repos/alpha"* ]]
  [[ "$output" == *"cloned repos/beta"* ]]
  [[ "$output" == *"2 cloned, 0 present, 0 skipped, 0 failed"* ]]
  [ -f "$HOME/space/repos/alpha/README" ]
  [ -f "$HOME/space/repos/beta/README" ]
}

@test "type defaults to repo, and a ref is checked out after the clone" {
  local a
  a=$(mkbare alpha other)
  space_def acme space <<YML
path: space
resources:
  - url: $a
    path: repos/alpha
    ref: other
YML
  run wsm install acme/space
  [ "$status" -eq 0 ]
  [ -f "$HOME/space/repos/alpha/BRANCH" ]
}

@test "re-running leaves existing clones alone, and keeps the space's identity" {
  local a id
  a=$(mkbare alpha)
  space_def acme space <<YML
path: space
resources:
  - url: $a
    path: repos/alpha
YML
  wsm install acme/space >/dev/null
  id=$(cat "$HOME/space/.wsm/id")
  echo "local work" > "$HOME/space/repos/alpha/SCRATCH"

  run wsm install acme/space
  [ "$status" -eq 0 ]
  [[ "$output" == *"present repos/alpha"* ]]
  [[ "$output" == *"0 cloned, 1 present"* ]]
  [ -f "$HOME/space/repos/alpha/SCRATCH" ]
  [ "$(cat "$HOME/space/.wsm/id")" = "$id" ]
  [ "$(entries)" -eq 1 ]
}

@test "an unknown type is a warning and a skip, and the rest still run" {
  local a
  a=$(mkbare alpha)
  space_def acme space <<YML
path: space
resources:
  - type: link
    path: bases/thing
  - url: $a
    path: repos/alpha
YML
  run wsm install acme/space
  [ "$status" -eq 0 ]
  [[ "$output" == *"unknown resource type 'link'"* ]]
  [[ "$output" == *"1 cloned, 0 present, 1 skipped, 0 failed"* ]]
  # Read field by field: the entry with no url must not shift the next one's path
  [ -f "$HOME/space/repos/alpha/README" ]
  [ ! -e "$HOME/space/bases" ]
}

@test "something in the way that is not a repo fails, and the rest still run" {
  local a b
  a=$(mkbare alpha); b=$(mkbare beta)
  mkdir -p "$HOME/space/repos/alpha"
  echo "not a repo" > "$HOME/space/repos/alpha/stuff"
  space_def acme space <<YML
path: space
resources:
  - url: $a
    path: repos/alpha
  - url: $b
    path: repos/beta
YML
  run wsm install acme/space
  [ "$status" -ne 0 ]
  [[ "$output" == *"in the way and not a git repo: repos/alpha"* ]]
  [[ "$output" == *"1 cloned, 0 present, 0 skipped, 1 failed"* ]]
  [ -f "$HOME/space/repos/beta/README" ]
  [ -f "$HOME/space/repos/alpha/stuff" ]
}

@test "a resource path that escapes the space is refused" {
  space_def acme space <<'YML'
path: space
resources:
  - url: file:///nowhere.git
    path: ../escaped
YML
  run wsm install acme/space
  [ "$status" -ne 0 ]
  [[ "$output" == *"inside the workspace"* ]]
  [ ! -e "$HOME/escaped" ]
}

@test "a failed clone leaves nothing behind" {
  space_def acme space <<'YML'
path: space
resources:
  - url: file:///definitely/not/a/repo.git
    path: repos/nope
YML
  run wsm install acme/space
  [ "$status" -ne 0 ]
  [[ "$output" == *"clone failed"* ]]
  [ ! -e "$HOME/space/repos/nope" ]
}

@test "--dry-run reports but creates and clones nothing" {
  local a
  a=$(mkbare alpha)
  space_def acme space <<YML
path: space
resources:
  - url: $a
    path: repos/alpha
YML
  run wsm install acme/space --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would clone repos/alpha"* ]]
  [ ! -e "$HOME/space" ]
}

@test "id: gives the space a fixed identity" {
  space_def acme fixed <<'YML'
id: 0b4a1c2e-1111-4222-8333-444455556666
YML
  run wsm install acme/fixed
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/spaces/fixed/.wsm/id")" = 0b4a1c2e-1111-4222-8333-444455556666 ]
}

@test "a dependency is one space, not every source's space of that name" {
  mksource other >/dev/null
  space_def acme org <<'YML'
path: spaces/acme/org
YML
  space_def acme tech <<'YML'
path: spaces/acme/tech
depends: [org]
YML
  space_def other org <<'YML'
path: spaces/other/org
YML
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  [ -d "$HOME/spaces/acme/org" ]
  [ ! -e "$HOME/spaces/other/org" ]
}
