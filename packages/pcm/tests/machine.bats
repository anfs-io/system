#!/usr/bin/env bats
# pcm_podman_ready on macOS: PCM_MACHINE_MEMORY sizes the podman machine, restarting it when it
# runs with another amount. podman is a stub that records what it was asked.
# Run: bats packages/pcm/tests/

load helper

setup() {
  pcm_setup
  OSTYPE=darwin24
  CALLS="$T/podman.calls"
  : > "$CALLS"
  # The stub machine: MEM MiB, STATE running|stopped; EXISTS=false for none at all
  MEM=2048 STATE=running EXISTS=true
  unset PCM_MACHINE_MEMORY
}

podman() {
  echo "$*" >> "$CALLS"
  case "$1 ${2:-}" in
    "machine list") [[ "$EXISTS" == true ]] && echo podman-machine-default; return 0 ;;
    "machine inspect")
      [[ "$EXISTS" == true ]] || return 125
      case "$*" in
        *Memory*) echo "$MEM" ;;
        *State*) echo "$STATE" ;;
      esac ;;
    "machine stop") STATE=stopped ;;
    "machine set") MEM="${4}" ;;
    "machine start") STATE=running ;;
    "machine init") EXISTS=true STATE=stopped ;;
    "info ") [[ "$STATE" == running ]] ;;
    "ps --format") echo "postgres_postgres_1"; echo "traefik_traefik_1" ;;
    *) return 0 ;;
  esac
}

called() { grep -qxF -- "$1" "$CALLS"; }

@test "unset: a running machine is left alone" {
  pcm_podman_ready
  ! grep -q "machine stop\|machine set" "$CALLS"
}

@test "the same amount: nothing is restarted" {
  PCM_MACHINE_MEMORY=2048
  pcm_podman_ready
  ! grep -q "machine stop\|machine set\|machine start" "$CALLS"
}

@test "another amount: stop, set, start, naming the containers it stops" {
  PCM_MACHINE_MEMORY=4096
  run pcm_podman_ready
  [ "$status" -eq 0 ]
  [[ "$output" == *"has 2048 MiB; PCM_MACHINE_MEMORY is 4096"* ]]
  [[ "$output" == *"stops these containers: postgres_postgres_1 traefik_traefik_1"* ]]
  [ "$(grep -n 'machine stop' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'machine set' "$CALLS" | cut -d: -f1)" ]
  called "machine set --memory 4096"
  called "machine start"
}

@test "a stopped machine of another size is resized and started without a stop" {
  PCM_MACHINE_MEMORY=4096 STATE=stopped
  pcm_podman_ready
  ! called "machine stop"
  called "machine set --memory 4096"
  called "machine start"
}

@test "a new machine is created with the memory" {
  PCM_MACHINE_MEMORY=4096 EXISTS=false
  pcm_podman_ready 2>/dev/null
  called "machine init --memory 4096"
  called "machine start"
}

@test "a value that isn't MiB is an error, before touching the machine" {
  PCM_MACHINE_MEMORY=4G
  run pcm_podman_ready
  [ "$status" -eq 1 ]
  [[ "$output" == *"memory in MiB (e.g. 4096), not '4G'"* ]]
  [ ! -s "$CALLS" ]
}

@test "Linux has no machine: nothing to do" {
  OSTYPE=linux-gnu PCM_MACHINE_MEMORY=4096
  pcm_podman_ready
  [ ! -s "$CALLS" ]
}
