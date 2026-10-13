#!/usr/bin/env bats
# macOS guests (the tart backend): clones in tart's store, and Apple's limit of two at once
load helper

setup() {
  setup_pmm
  mkdir -p "$HOME/.tart"     # tart's home: pmm leaves tart alone on a machine that never ran it
  fake_tart_build mac
}

teardown() {
  local f
  for f in "$PMM_STATE_HOME"/run/*/pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null; done
  return 0
}

@test "up: a clone of the build named pmm-<machine>, with the definition's shares; no hold" {
  mkdir -p "$T/share"
  machine "$PMM_MACHINES_HOME/m1" "$(printf 'image: mac\ncpus: 6\nmemory: 8G\nshares: ["%s:src:ro"]' "$T/share")"
  load_machines
  run cli_call up m1
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx "tart clone pmm-image-mac-bbbbbbbbbbbbbbbb pmm-m1" "$PMM_CALLS"
  grep -qx "tart set pmm-m1 --cpu 6 --memory 8192" "$PMM_CALLS"
  grep -q "tart run --no-graphics --dir=src:.*/share:ro pmm-m1" "$PMM_CALLS"
  [ "$(state_get m1 .backend)" = tart ]
  [ "$(state_get m1 .boot.user)" = admin ]
  [ -z "$(held mac)" ]
  [ "$(mach_address m1)" = 192.168.64.9 ]
  run cli_call down m1
  [ "$(mach_state m1)" = stopped ]
}

@test "the macOS limit: a third running guest is refused before anything is cloned" {
  echo running > "$TART_STUB/pmm-one"
  echo running > "$TART_STUB/someone-elses"
  echo stopped > "$TART_STUB/pmm-idle"
  machine "$PMM_MACHINES_HOME/m3" "image: mac"
  load_machines
  run cli_call up m3
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 macOS guests at once and 2 are up (one someone-elses); pmm down one first"* ]]
  run grep "tart clone" "$PMM_CALLS"
  [ "$status" -ne 0 ]
  [ ! -f "$TART_STUB/pmm-m3" ]
  echo stopped > "$TART_STUB/someone-elses"
  run cli_call up m3
  [ "$status" -eq 0 ]
}

@test "snapshot, reset and remove: clones in tart's store, gone with the machine" {
  cli_call create m1 --image mac >/dev/null
  load_machines
  cli_call snapshot m1 s1 >/dev/null
  [ -f "$TART_STUB/pmm-m1-snap-s1" ]
  run cli_call snapshot m1
  [ "$output" = s1 ]
  run cli_call reset -y m1 s1
  [ "$status" -eq 0 ]
  grep -qx "tart clone pmm-m1-snap-s1 pmm-m1" "$PMM_CALLS"
  cli_call remove -y m1 >/dev/null
  [ ! -f "$TART_STUB/pmm-m1" ] && [ ! -f "$TART_STUB/pmm-m1-snap-s1" ]
  [ -f "$TART_STUB/pmm-image-mac-bbbbbbbbbbbbbbbb" ]
}
