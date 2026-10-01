#!/usr/bin/env bats
# init and new. Spec conformance cases 1-5.
# Run: bats packages/wsm/tests/init.bats

load helper
setup() { wsm_setup; }

@test "init creates a marker, registers, and reports added" {
  mkdir -p "$HOME/code/chorus"
  cd "$HOME/code/chorus"
  run wsm init
  [ "$status" -eq 0 ]
  [ "$output" = "added chorus ~/code/chorus" ]
  [ -f "$HOME/code/chorus/.wsm/id" ]
  [ "$(entries)" -eq 1 ]
  [ "$(field chorus 4)" = "$HOME/code/chorus" ]
}

@test "init a second time is a no-op and leaves the registry byte-identical" {
  mkdir -p "$HOME/p"; cd "$HOME/p"
  wsm init
  before=$(cat "$REGISTRY")
  run wsm init
  [ "$status" -eq 0 ]
  [ "$output" = "unchanged p ~/p" ]
  [ "$(cat "$REGISTRY")" = "$before" ]
}

@test "init keeps the id of an existing valid marker, as for a clone" {
  mkmarker cloned 3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c
  cd "$HOME/cloned"
  run wsm init
  [ "$status" -eq 0 ]
  [ "${output%% *}" = "added" ]
  [ "$(cat "$HOME/cloned/.wsm/id")" = "3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c" ]
  [ "$(field cloned 1)" = "3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c" ]
}

@test "moving a workspace updates the path, keeps added, and adds no duplicate" {
  mkdir -p "$HOME/old"; cd "$HOME/old"
  wsm init
  id=$(cat "$HOME/old/.wsm/id")
  added=$(field old 3)

  mv "$HOME/old" "$HOME/new"
  cd "$HOME/new"
  run wsm init
  [ "$status" -eq 0 ]
  [ "${output%% *}" = "moved" ]

  [ "$(entries)" -eq 1 ]
  [ "$(cut -f1 "$REGISTRY")" = "$id" ]
  [ "$(cut -f3 "$REGISTRY")" = "$added" ]
  [ "$(cut -f4 "$REGISTRY")" = "$HOME/new" ]
}

@test "init --name sets the display name, and renames on a later run" {
  mkdir -p "$HOME/a"; cd "$HOME/a"
  run wsm init --name first
  [ "$output" = "added first ~/a" ]
  run wsm init --name second
  [ "$status" -eq 0 ]
  [ "$output" = "updated second ~/a" ]
  [ "$(entries)" -eq 1 ]
}

@test "new creates the directory and registers it" {
  run wsm new "$HOME/made/here"
  [ "$status" -eq 0 ]
  [ "$output" = "added here ~/made/here" ]
  [ -f "$HOME/made/here/.wsm/id" ]
}

@test "new on an existing path exits 73 and creates nothing" {
  mkdir -p "$HOME/taken"
  run wsm new "$HOME/taken"
  [ "$status" -eq 73 ]
  [ ! -e "$HOME/taken/.wsm" ]
  [ "$(entries)" -eq 0 ]
}

@test "an invalid marker exits 65 and is not replaced" {
  mkdir -p "$HOME/broken/.wsm"
  echo "not-a-uuid" > "$HOME/broken/.wsm/id"
  cd "$HOME/broken"
  run wsm init
  [ "$status" -eq 65 ]
  [ "$(cat "$HOME/broken/.wsm/id")" = "not-a-uuid" ]
  [ "$(entries)" -eq 0 ]
}

@test "a name holding a tab or a slash exits 64" {
  mkdir -p "$HOME/n"; cd "$HOME/n"
  run wsm init --name "$(printf 'a\tb')"
  [ "$status" -eq 64 ]
  run wsm init --name "a/b"
  [ "$status" -eq 64 ]
  [ "$(entries)" -eq 0 ]
}

@test "a workspace outside \$HOME is refused" {
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"
  cd "$outside"
  run wsm init
  [ "$status" -eq 64 ]
}
