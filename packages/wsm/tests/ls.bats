#!/usr/bin/env bats
# ls and prune. Spec conformance cases 6 and 7.
# Run: bats packages/wsm/tests/ls.bats

load helper
setup() {
  wsm_setup
  mkdir -p "$HOME/live" "$HOME/gone"
  (cd "$HOME/live" && wsm init >/dev/null)
  (cd "$HOME/gone" && wsm init >/dev/null)
}

# stdout is a pipe under bats, so ls prints tab-separated rather than aligned columns
names() { cut -f1; }

@test "ls lists every valid workspace" {
  run wsm ls
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(printf '%s\n' "$output" | names | tr '\n' ' ')" = "gone live " ]
}

@test "a removed workspace drops out of ls and shows up under --stale" {
  rm -rf "$HOME/gone"
  run wsm ls
  [ "$(printf '%s\n' "$output" | names)" = "live" ]
  run wsm ls --stale
  [ "$(printf '%s\n' "$output" | names)" = "gone" ]
}

@test "a marker replaced by a different id makes the entry stale" {
  printf '%s\n' "3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c" > "$HOME/gone/.wsm/id"
  run wsm ls --stale
  [ "$(printf '%s\n' "$output" | names)" = "gone" ]
}

@test "--all lists both and marks the stale ones" {
  rm -rf "$HOME/gone"
  run wsm ls --all
  [ "${#lines[@]}" -eq 2 ]
  [[ "$output" == *"gone	~/gone (stale)"* ]]
  [[ "$output" == *"live	~/live"* ]]
  [[ "$output" != *"live	~/live (stale)"* ]]
}

@test "--paths prints absolute paths and --ids prints ids" {
  run wsm ls --paths
  [[ "$output" == *"$HOME/live"* ]]
  [[ "$output" != *"~/live"* ]]
  run wsm ls --ids
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" =~ ^[0-9a-f]{8}- ]]
}

@test "--paths and --ids together exit 64" {
  run wsm ls --paths --ids
  [ "$status" -eq 64 ]
}

@test "an empty registry lists nothing and still exits 0" {
  rm -f "$REGISTRY"
  run wsm ls
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prune --dry-run reports but writes nothing" {
  rm -rf "$HOME/gone"
  before=$(cat "$REGISTRY")
  run wsm prune --dry-run
  [ "$status" -eq 0 ]
  [ "$output" = "would prune gone ~/gone" ]
  [ "$(cat "$REGISTRY")" = "$before" ]
}

@test "prune removes stale entries and leaves the rest" {
  rm -rf "$HOME/gone"
  run wsm prune
  [ "$status" -eq 0 ]
  [ "$output" = "pruned gone ~/gone" ]
  [ "$(entries)" -eq 1 ]
  [ "$(cut -f2 "$REGISTRY")" = "live" ]
}

@test "prune with nothing stale changes nothing" {
  before=$(cat "$REGISTRY")
  run wsm prune
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$REGISTRY")" = "$before" ]
}
