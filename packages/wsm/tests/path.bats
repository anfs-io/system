#!/usr/bin/env bats
# path and forget. Spec conformance cases 8 and 9.
# Run: bats packages/wsm/tests/path.bats

load helper
setup() {
  wsm_setup
  mkdir -p "$HOME/work/api"
  (cd "$HOME/work/api" && wsm init >/dev/null)
  ID=$(cat "$HOME/work/api/.wsm/id")
}

@test "path resolves an exact name" {
  run wsm path api
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/work/api" ]
}

@test "path resolves a full id and a unique id prefix" {
  run wsm path "$ID"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/work/api" ]
  run wsm path "${ID:0:4}"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/work/api" ]
}

@test "an id prefix shorter than 4 characters is not a prefix match" {
  run wsm path "${ID:0:3}"
  [ "$status" -eq 1 ]
}

@test "no match exits 1" {
  run wsm path nothing-like-this
  [ "$status" -eq 1 ]
}

@test "duplicate names exit 2 and list the candidates on stderr" {
  mkdir -p "$HOME/other/api"
  (cd "$HOME/other/api" && wsm init >/dev/null)
  run wsm path api
  [ "$status" -eq 2 ]
  [[ "$output" == *"is ambiguous"* ]]
  [[ "$output" == *"api  ~/work/api"* ]]
  [[ "$output" == *"api  ~/other/api"* ]]
}

@test "a stale match still prints its path, warns, and exits 3" {
  rm -rf "$HOME/work/api"
  run wsm path api
  [ "$status" -eq 3 ]
  [[ "$output" == *"$HOME/work/api"* ]]
  [[ "$output" == *"is stale"* ]]
}

@test "path with no query prints the root of the workspace holding the cwd" {
  mkdir -p "$HOME/work/api/deep/deeper"
  cd "$HOME/work/api/deep/deeper"
  run wsm path
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/work/api" ]
}

@test "path with no query outside any workspace exits 1" {
  cd "$HOME"
  run wsm path
  [ "$status" -eq 1 ]
}

@test "forget removes the entry but leaves the marker" {
  run wsm forget api
  [ "$status" -eq 0 ]
  [ "$output" = "forgot api ~/work/api" ]
  [ "$(entries)" -eq 0 ]
  [ -f "$HOME/work/api/.wsm/id" ]
}

@test "a forgotten workspace re-registers on the next command run inside it" {
  wsm forget api
  [ "$(entries)" -eq 0 ]
  cd "$HOME/work/api"
  wsm ls >/dev/null
  [ "$(entries)" -eq 1 ]
  [ "$(field api 1)" = "$ID" ]
}

@test "forget with no query uses the workspace holding the cwd" {
  cd "$HOME/work/api"
  run wsm forget
  [ "$status" -eq 0 ]
  [ "$output" = "forgot api ~/work/api" ]
}

@test "an ambiguous forget exits 2 and changes nothing" {
  mkdir -p "$HOME/other/api"
  (cd "$HOME/other/api" && wsm init >/dev/null)
  before=$(cat "$REGISTRY")
  run wsm forget api
  [ "$status" -eq 2 ]
  [ "$(cat "$REGISTRY")" = "$before" ]
  [ ! -d "$XDG_STATE_HOME/wsm/workspaces.lock" ]
}
