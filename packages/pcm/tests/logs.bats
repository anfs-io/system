#!/usr/bin/env bats
# pcm logs (units/pcm/06-logs, r-20261022-6): a service's logs through compose logs, run as up
# runs compose; -s, the options passed on, no containers, one-offs, the podman compose --pcm
# wrapper, and bin/pcm from a non-interactive bash. podman is a stub; the compose runner is a
# script that records its arguments.
# Run: ANFS_TESTS_PMM_PCM=1 bats packages/pcm/tests/logs.bats

load helper

setup() {
  pcm_setup
  add_source a
  PCM_ATTACHED_SERVICES=""
  CALLS="$T/podman.calls" COMPOSE_LOG="$T/compose.log"
  export COMPOSE_LOG
  : > "$CALLS"
  : > "$COMPOSE_LOG"
  mkdir -p "$T/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$COMPOSE_LOG"\n' > "$T/bin/compose"
  chmod +x "$T/bin/compose"
  RUNNER=("$T/bin/compose")
  # RUNNING: compose services with a container; ONEOFFS: one-off names
  RUNNING="web worker" ONEOFFS=""
  define "$T/src/a/containers" app "$(printf 'services:\n  web:\n    image: docker.io/library/alpine:3\n  worker:\n    image: docker.io/library/alpine:3\n')"
  load_sources
}

podman() {
  echo "$*" >> "$CALLS"
  local s
  case "$1" in
    ps)
      if [[ "$*" == *"label=io.pcm.oneoff "* ]]; then
        [[ -z "$ONEOFFS" ]] || printf '%s\n' $ONEOFFS
      else
        for s in $RUNNING; do
          [[ "$*" == *"com.docker.compose.service="* && "$*" != *"com.docker.compose.service=$s "* ]] || echo "app_${s}_1"
        done
      fi
      return 0 ;;
    inspect) echo "a/app"; return 0 ;;
    logs) return 0 ;;
    *) return 1 ;;
  esac
}

@test "every compose service's logs, as project <name>, with up's compose files" {
  run cli_call logs app </dev/null
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$COMPOSE_LOG")" -eq 1 ]
  line=$(cat "$COMPOSE_LOG")
  [[ "$line" == "-p app -f $T/src/a/containers/app/compose.yml -f $PCM_CACHE_HOME/app.override.yml logs" ]]
}

@test "-s NAME: that compose service's" {
  run cli_call logs app -s worker </dev/null
  [ "$status" -eq 0 ]
  [[ "$(cat "$COMPOSE_LOG")" == *" logs worker" ]]
  grep -q 'com.docker.compose.service=worker' "$CALLS"
}

@test "-f, --tail, --since and what follows -- go on to compose logs" {
  run cli_call logs app -f --tail 5 --since 10m -- -t </dev/null
  [ "$status" -eq 0 ]
  [[ "$(cat "$COMPOSE_LOG")" == *" logs -f --tail 5 --since 10m -t" ]]
  : > "$COMPOSE_LOG"
  run cli_call logs app --follow -s web </dev/null
  [ "$status" -eq 0 ]
  [[ "$(cat "$COMPOSE_LOG")" == *" logs -f web" ]]
}

@test "no containers: 1, saying so, and no compose call" {
  RUNNING=""
  run cli_call logs app </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"a/app has no containers (pcm up app)"* ]]
  [ ! -s "$COMPOSE_LOG" ]
  RUNNING="web"
  run cli_call logs app -s worker </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"no containers of compose service worker"* ]]
  [ ! -s "$COMPOSE_LOG" ]
}

@test "usage: an unknown service or compose service is 64" {
  run cli_call logs ghost </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown service 'ghost'"* ]]
  run cli_call logs app -s db </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"no compose service 'db' (it has: web worker)"* ]]
  [ ! -s "$COMPOSE_LOG" ]
}

@test "one-offs: left out (stopped containers count), shown when -s names one" {
  run cli_call logs app </dev/null
  grep -q -- '^ps -a --filter label=io.pcm.name=app --filter label!=io.pcm.oneoff' "$CALLS"
  ONEOFFS="app-run-1a2b3c"
  run cli_call logs app -s app-run-1a2b3c --tail 3 </dev/null
  [ "$status" -eq 0 ]
  grep -qx 'logs --tail 3 app-run-1a2b3c' "$CALLS"
  [ "$(wc -l < "$COMPOSE_LOG")" -eq 1 ]
}

@test "podman compose --pcm logs is pcm logs" {
  compose_wrapper logs -f app --tail 2 </dev/null
  [[ "$(cat "$COMPOSE_LOG")" == *" logs -f --tail 2" ]]
  run compose_wrapper logs app app </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"one service at a time"* ]]
}

@test "bin/pcm logs from a non-interactive bash, no zsh" {
  local home="$T/home"
  mkdir -p "$home/.local/lib" "$T/path"
  ln -s "$ANFS_LIB" "$home/.local/lib/anfs"
  define "$PCM_CONTAINERS_HOME" ui
  printf '#!/usr/bin/env bash\ncase "$1" in ps) echo ui_app_1 ;; inspect) echo local/ui ;; esac\n' > "$T/path/podman"
  chmod +x "$T/path/podman"
  run env -i HOME="$home" PATH="$T/path:$PATH" PCM_LIB_DIR="$PCM_LIB_DIR" ANFS_LOG=off \
    PCM_CONFIG_HOME="$PCM_CONFIG_HOME" PCM_CONTAINERS_HOME="$PCM_CONTAINERS_HOME" \
    PCM_CACHE_HOME="$PCM_CACHE_HOME" PCM_STATE_HOME="$PCM_STATE_HOME" PCM_DATA_HOME="$PCM_DATA_HOME" \
    ANFS_CONFIG_HOME="$ANFS_CONFIG_HOME" ANFS_DATA_HOME="$ANFS_DATA_HOME" ANFS_CACHE_HOME="$ANFS_CACHE_HOME" \
    PCM_COMPOSE="$T/bin/compose" COMPOSE_LOG="$COMPOSE_LOG" \
    bash -c "'$PCM_PKG/home/.local/bin/pcm' logs ui --tail 5" </dev/null
  [ "$status" -eq 0 ]
  [[ "$(cat "$COMPOSE_LOG")" == "-p ui -f $PCM_CONTAINERS_HOME/ui/compose.yml -f $PCM_CACHE_HOME/ui.override.yml logs --tail 5" ]]
}
