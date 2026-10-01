#!/usr/bin/env bats
# scan and auto-registration. Spec conformance cases 10 and 11.
# Run: bats packages/wsm/tests/scan.bats

load helper
setup() { wsm_setup; }

@test "a command run inside an unregistered workspace registers it" {
  mkmarker cloned
  [ "$(entries)" -eq 0 ]
  cd "$HOME/cloned"
  run wsm ls
  [ "$status" -eq 0 ]
  [ "$(entries)" -eq 1 ]
  [ "$(field cloned 2)" = "cloned" ]
}

@test "auto-registration works from a subdirectory" {
  mkmarker deep
  mkdir -p "$HOME/deep/a/b"
  cd "$HOME/deep/a/b"
  wsm ls >/dev/null
  [ "$(field deep 4)" = "$HOME/deep" ]
}

@test "an already registered workspace is not rewritten" {
  mkdir -p "$HOME/p"
  (cd "$HOME/p" && wsm init >/dev/null)
  before=$(cat "$REGISTRY")
  cd "$HOME/p"
  wsm ls >/dev/null
  wsm ls >/dev/null
  [ "$(cat "$REGISTRY")" = "$before" ]
}

@test "auto-registration leaves no lock behind" {
  mkmarker cloned
  cd "$HOME/cloned"
  wsm ls >/dev/null
  [ ! -e "$XDG_STATE_HOME/wsm/workspaces.lock" ]
}

@test "scan rebuilds a deleted registry from the markers" {
  mkdir -p "$HOME/a" "$HOME/b/c"
  (cd "$HOME/a" && wsm init >/dev/null)
  (cd "$HOME/b/c" && wsm init >/dev/null)
  rm -f "$REGISTRY"

  run wsm scan
  [ "$status" -eq 0 ]
  [ "$(entries)" -eq 2 ]
  [[ "$output" == *"2 added, 0 moved, 0 updated, 0 unchanged"* ]]
}

@test "scan skips node_modules and the other pruned directories" {
  mkmarker real
  mkmarker node_modules/pkg
  mkmarker .git/hidden
  run wsm scan
  [ "$status" -eq 0 ]
  [ "$(entries)" -eq 1 ]
  [ "$(cut -f2 "$REGISTRY")" = "real" ]
}

@test "scan does not follow symlinks" {
  mkmarker real
  ln -s "$HOME/real" "$HOME/link"
  run wsm scan
  [ "$status" -eq 0 ]
  [ "$(entries)" -eq 1 ]
  [ "$(cut -f4 "$REGISTRY")" = "$HOME/real" ]
}

@test "scan is idempotent" {
  mkmarker a
  mkmarker b
  wsm scan >/dev/null
  run wsm scan
  [[ "$output" == *"0 added, 0 moved, 0 updated, 2 unchanged"* ]]
}

@test "scan --dry-run reports but writes nothing" {
  mkmarker a
  run wsm scan --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would added a ~/a"* ]]
  [ "$(entries)" -eq 0 ]
}

@test "scan takes explicit directories" {
  mkmarker inside/here
  mkmarker elsewhere
  run wsm scan "$HOME/inside"
  [ "$status" -eq 0 ]
  [ "$(entries)" -eq 1 ]
  [ "$(cut -f2 "$REGISTRY")" = "here" ]
}

@test "scan warns about an invalid marker and skips it" {
  mkdir -p "$HOME/broken/.wsm"
  echo "nope" > "$HOME/broken/.wsm/id"
  mkmarker fine
  run wsm scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"invalid marker, skipped"* ]]
  [ "$(entries)" -eq 1 ]
}

@test "scan records a move in one pass" {
  mkdir -p "$HOME/before"
  (cd "$HOME/before" && wsm init >/dev/null)
  added=$(cut -f3 "$REGISTRY")
  mv "$HOME/before" "$HOME/after"
  run wsm scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 added, 1 moved, 0 updated, 0 unchanged"* ]]
  [ "$(entries)" -eq 1 ]
  [ "$(cut -f3 "$REGISTRY")" = "$added" ]
  [ "$(cut -f4 "$REGISTRY")" = "$HOME/after" ]
}
