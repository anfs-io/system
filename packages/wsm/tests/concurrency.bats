#!/usr/bin/env bats
# Locking under contention. Spec conformance case 14.
# Run: bats packages/wsm/tests/concurrency.bats

load helper
setup() { wsm_setup; }

@test "10 parallel inits produce exactly 10 entries and no leftovers" {
  for i in $(seq 1 10); do mkdir -p "$HOME/p$i"; done
  for i in $(seq 1 10); do
    ( cd "$HOME/p$i" && "$WSM" init >/dev/null 2>&1 ) &
  done
  wait

  [ "$(entries)" -eq 10 ]
  [ "$(cut -f1 "$REGISTRY" | sort -u | wc -l | tr -d ' ')" -eq 10 ]
  [ "$(cut -f4 "$REGISTRY" | sort -u | wc -l | tr -d ' ')" -eq 10 ]

  # No lock directory and no temp files survive the run
  [ ! -e "$XDG_STATE_HOME/wsm/workspaces.lock" ]
  run find "$XDG_STATE_HOME/wsm" -name 'workspaces.tmp.*'
  [ -z "$output" ]
}

@test "a lock left behind by a dead process is cleared once it is old enough" {
  mkdir -p "$XDG_STATE_HOME/wsm/workspaces.lock"
  # 61 seconds ago: past the point where a live holder is plausible
  echo $(( $(date +%s) - 61 )) > "$XDG_STATE_HOME/wsm/workspaces.lock/created"

  mkdir -p "$HOME/p"
  cd "$HOME/p"
  run wsm init
  [ "$status" -eq 0 ]
  [[ "$output" == *"clearing a stale lock"* ]]
  [ "$(entries)" -eq 1 ]
  [ ! -e "$XDG_STATE_HOME/wsm/workspaces.lock" ]
}

@test "a fresh lock held by someone else fails with 75 rather than being broken" {
  mkdir -p "$XDG_STATE_HOME/wsm/workspaces.lock"
  date +%s > "$XDG_STATE_HOME/wsm/workspaces.lock/created"

  mkdir -p "$HOME/p"
  cd "$HOME/p"
  run wsm init
  [ "$status" -eq 75 ]
  # The other holder's lock is still standing
  [ -d "$XDG_STATE_HOME/wsm/workspaces.lock" ]
}

@test "reads do not take the lock" {
  mkdir -p "$HOME/p"
  (cd "$HOME/p" && wsm init >/dev/null)
  mkdir -p "$XDG_STATE_HOME/wsm/workspaces.lock"
  date +%s > "$XDG_STATE_HOME/wsm/workspaces.lock/created"

  run wsm ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"p	~/p"* ]]
}
