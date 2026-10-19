#!/usr/bin/env bats
# remove's guards (no engine: podman is stubbed, nothing is running).
# Run: bats packages/pcm/tests/

load helper

setup() {
  pcm_setup
  add_source a
  define "$T/src/a/containers" app
  load_sources
}

@test "remove: needs a service, rejects unknown services and options" {
  run cli_call remove
  [ "$status" -eq 64 ]
  [[ "$output" == *"pcm: usage: pcm remove [-y] [-f] <service>..."* ]]
  run cli_call remove ghost
  [[ "$output" == *"unknown service 'ghost'"* ]]
  run cli_call remove --bogus app
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown option '--bogus'"* ]]
}

@test "remove: without a terminal it needs -y, and deletes nothing" {
  mkdir -p "$PCM_VOLUMES_HOME/app"
  run cmd_remove app < /dev/null
  [ "$status" -eq 77 ]
  [[ "$output" == *"pass -y"* ]]
  [ -d "$PCM_VOLUMES_HOME/app" ]
}
