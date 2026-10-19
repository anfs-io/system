#!/usr/bin/env bats
# container.yml's toolkit: read|write (units/toolkit-api/02-socket): what pcm gives a service that
# asks for the toolkit's API. macOS: ANFS_RPC_URL and the grant's token in compose's environment,
# never on disk; Linux: the grant's socket mounted. Absent: nothing. podman is stubbed; the
# platform is PCM_TOOLKIT_OS.
# Run: bats packages/pcm/tests/toolkit.bats

load helper

setup() {
  pcm_setup
  add_source a
  export ANFS_STATE_HOME="$T/anfs/state" XDG_RUNTIME_DIR="$T/run"
  mkdir -p "$ANFS_STATE_HOME/rpc"
  echo rtok-secret > "$ANFS_STATE_HOME/rpc/token.read"
  echo wtok-secret > "$ANFS_STATE_HOME/rpc/token.write"
  echo 47100 > "$ANFS_STATE_HOME/rpc/port"
  define "$T/src/a/containers" ui
  define "$T/src/a/containers" plain
  printf 'version: 0.1.0\ntoolkit: write\n' > "$T/src/a/containers/ui/container.yml"
  printf 'version: 0.1.0\n' > "$T/src/a/containers/plain/container.yml"
  PCM_ATTACHED_SERVICES=""
}

override() { yq "$1" "$(override_file "a/$2")"; }
# The compose runner: prints the environment it was given
showenv() { env; }

@test "validate: toolkit is read or write" {
  load_sources
  run validate_services a/ui
  [ "$status" -eq 0 ]
  printf 'version: 0.1.0\ntoolkit: root\n' > "$T/src/a/containers/ui/container.yml"
  run validate_services a/ui
  [ "$status" -ne 0 ]
  [[ "$output" == *"toolkit 'root' is read or write"* ]]
}

@test "macOS: the address in the override, the token only as \${ANFS_RPC_TOKEN}" {
  PCM_TOOLKIT_OS=macos
  load_sources
  compose_flags a/ui
  [ "$(override '.services.app.environment.ANFS_RPC_URL' ui)" = "tcp://host.containers.internal:47100" ]
  [ "$(override '.services.app.environment.ANFS_RPC_TOKEN' ui)" = '${ANFS_RPC_TOKEN:-}' ]
  [ "$(override '.services.app.volumes' ui)" = null ]
  ! grep -rq secret "$PCM_CACHE_HOME" "$PCM_STATE_HOME" "$PCM_DATA_HOME" 2>/dev/null
}

@test "macOS: compose runs with the grant's token in its environment" {
  PCM_TOOLKIT_OS=macos
  load_sources
  RUNNER=(showenv)
  run compose_run a/ui
  [[ "$output" == *"ANFS_RPC_TOKEN=wtok-secret"* ]]
  printf 'version: 0.1.0\ntoolkit: read\n' > "$T/src/a/containers/ui/container.yml"
  run compose_run a/ui
  [[ "$output" == *"ANFS_RPC_TOKEN=rtok-secret"* ]]
  run compose_run a/plain
  [[ "$output" != *"ANFS_RPC_TOKEN"* ]]
}

@test "macOS: no token on disk: a warning, and nothing handed over" {
  PCM_TOOLKIT_OS=macos
  rm "$ANFS_STATE_HOME/rpc/token.write"
  load_sources
  RUNNER=(showenv)
  run compose_run a/ui
  [[ "$output" == *"asks for toolkit: write"* ]]
  [[ "$output" != *"ANFS_RPC_TOKEN="* ]]
}

@test "Linux: the grant's socket mounted at /run/anfs/rpc.sock, no token" {
  PCM_TOOLKIT_OS=linux
  load_sources
  compose_flags a/ui
  [ "$(override '.services.app.environment.ANFS_RPC_URL' ui)" = "unix:///run/anfs/rpc.sock" ]
  [ "$(override '.services.app.environment.ANFS_RPC_TOKEN' ui)" = null ]
  [ "$(override '.services.app.volumes[0]' ui)" = "$T/run/anfs/rpc-write.sock:/run/anfs/rpc.sock" ]
  printf 'version: 0.1.0\ntoolkit: read\n' > "$T/src/a/containers/ui/container.yml"
  compose_flags a/ui
  [ "$(override '.services.app.volumes[0]' ui)" = "$T/run/anfs/rpc.sock:/run/anfs/rpc.sock" ]
  RUNNER=(showenv)
  run compose_run a/ui
  [[ "$output" != *"ANFS_RPC_TOKEN"* ]]
}

@test "absent: no environment, no mount" {
  for PCM_TOOLKIT_OS in macos linux; do
    load_sources
    compose_flags a/plain
    [ "$(override '.services.app.environment' plain)" = null ]
    [ "$(override '.services.app.volumes' plain)" = null ]
  done
}

@test "show: toolkit write, never the token; list --json has it" {
  PCM_TOOLKIT_OS=macos
  load_sources
  run cmd_show ui
  [[ "$output" == *"toolkit      write"* ]]
  [[ "$output" != *secret* ]]
  ANFS_TABLE=json run cmd_list
  [[ "$output" == *'"memory":null,"toolkit":"write"'* ]]
  [[ "$output" != *secret* ]]
}
