#!/usr/bin/env bats
# The on-disk registry format. Spec conformance cases 12, 13 and 16.
# Run: bats packages/wsm/tests/registry.bats

load helper
setup() { wsm_setup; }

@test "a path containing spaces round-trips" {
  mkdir -p "$HOME/my docs/a space"
  cd "$HOME/my docs/a space"
  run wsm init
  [ "$status" -eq 0 ]
  [ "$output" = "added a space ~/my docs/a space" ]
  run wsm path "a space"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/my docs/a space" ]
}

@test "a path containing a tab is rejected" {
  dir="$HOME/$(printf 'a\tb')"
  mkdir -p "$dir"
  cd "$dir"
  run wsm init
  [ "$status" -eq 64 ]
  [ "$(entries)" -eq 0 ]
}

@test "malformed lines are skipped with a warning and the rest still list" {
  mkdir -p "$HOME/good"
  (cd "$HOME/good" && wsm init >/dev/null)
  good=$(cat "$REGISTRY")
  {
    echo "# a comment"
    echo ""
    printf 'not-a-uuid\tx\t2026-01-01T00:00:00Z\t/tmp/x\n'
    printf 'too\tfew\n'
    printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\trel\t2026-01-01T00:00:00Z\trelative/path\n'
    printf '%s\n' "$good"
  } > "$REGISTRY"

  run wsm ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"line 3: invalid id"* ]]
  [[ "$output" == *"line 4: wrong field count"* ]]
  [[ "$output" == *"line 5: path is not absolute"* ]]
  [[ "$output" == *"good	~/good"* ]]
}

@test "a write drops the malformed lines" {
  mkdir -p "$HOME/good"
  (cd "$HOME/good" && wsm init >/dev/null)
  good=$(cat "$REGISTRY")
  { printf 'junk\n'; printf '%s\n' "$good"; } > "$REGISTRY"
  mkdir -p "$HOME/second"
  (cd "$HOME/second" && wsm init >/dev/null 2>&1)
  [ "$(entries)" -eq 2 ]
  run grep -c junk "$REGISTRY"
  [ "$status" -ne 0 ]
}

@test "duplicate ids are read once, keeping the first" {
  mkdir -p "$HOME/one"
  (cd "$HOME/one" && wsm init >/dev/null)
  line=$(cat "$REGISTRY")
  { printf '%s\n' "$line"; printf '%s\n' "$line"; } > "$REGISTRY"
  run wsm ls
  [[ "$output" == *"duplicate id"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^one	')" -eq 1 ]
}

@test "entries are written sorted by name" {
  for n in zeta alpha mid; do
    mkdir -p "$HOME/$n"
    (cd "$HOME/$n" && wsm init >/dev/null)
  done
  [ "$(cut -f2 "$REGISTRY" | tr '\n' ' ')" = "alpha mid zeta " ]
}

@test "the registry is created 0600" {
  mkdir -p "$HOME/p"
  (cd "$HOME/p" && wsm init >/dev/null)
  perms=$(ls -l "$REGISTRY" | cut -c1-10)
  [ "$perms" = "-rw-------" ]
}

@test "an empty XDG_STATE_HOME falls back to ~/.local/state" {
  mkdir -p "$HOME/p"
  cd "$HOME/p"
  XDG_STATE_HOME= run wsm init
  [ "$status" -eq 0 ]
  [ -f "$HOME/.local/state/wsm/workspaces" ]
}

@test "WSM_STATE_DIR overrides where the registry lives" {
  mkdir -p "$HOME/p"
  cd "$HOME/p"
  WSM_STATE_DIR="$BATS_TEST_TMPDIR/elsewhere" run wsm init
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/elsewhere/workspaces" ]
  [ ! -f "$REGISTRY" ]
}
