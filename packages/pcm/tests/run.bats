#!/usr/bin/env bats
# pcm run (units/pcm/01-run): a one-off container from a service's definition, through compose
# run with the one-off's override; what it starts first; the one-off label the other commands
# filter on; remove deleting one-offs; and pcm show's mounts format (podman 6). podman is a stub
# that records its calls; the compose runner is a script that records its arguments.
# Run: ANFS_TESTS_PMM_PCM=1 bats packages/pcm/tests/run.bats

load helper

setup() {
  pcm_setup
  add_source a
  OSTYPE=linux-gnu
  PCM_ATTACHED_SERVICES=""
  CALLS="$T/podman.calls" COMPOSE_LOG="$T/compose.log"
  export COMPOSE_LOG
  : > "$CALLS"
  : > "$COMPOSE_LOG"
  mkdir -p "$T/bin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$COMPOSE_LOG"\nexit "${FAKE_RC:-0}"\n' > "$T/bin/compose"
  chmod +x "$T/bin/compose"
  RUNNER=("$T/bin/compose")
  # RUNNING: compose services with a running container of their own; ONEOFFS: one-off names;
  # SHOWN: a pcm id whose container `pcm show` finds running; SHOWN_ROWS: its containers rows
  # (name, state, ExitedAt, Status, ports; tab-separated, \t and \n escapes)
  RUNNING="" ONEOFFS="" SHOWN="" SHOWN_ROWS=""
}

podman() {
  echo "$*" >> "$CALLS"
  case "$1" in
    ps)
      local s
      if [[ "$*" == *"--format json"* ]]; then
        [[ -z "$SHOWN" ]] || printf '[{"Id":"1","Names":["%s_app_1"],"State":"running","Status":"Up","Labels":{"io.pcm.id":"%s"}}]\n' "${SHOWN#*/}" "$SHOWN"
      elif [[ "$*" == *"label=io.pcm.oneoff "* ]]; then
        [[ -z "$ONEOFFS" ]] || printf '%s\n' $ONEOFFS
      elif [[ "$*" == *"com.docker.compose.service="* ]]; then
        for s in $RUNNING; do [[ "$*" != *"com.docker.compose.service=$s "* ]] || echo "app_${s}_1"; done
      elif [[ -n "$SHOWN" && "$*" == *"{{.ExitedAt}}"* ]]; then
        printf '%b' "${SHOWN_ROWS:-${SHOWN#*/}_app_1\\trunning\\t-62135596800\\tUp 2 hours\\t\\n}"
      elif [[ -n "$SHOWN" && "$*" == *"label=io.pcm.name=${SHOWN#*/} "* && "$*" == *"{{.Names}}"* ]]; then
        echo "${SHOWN#*/}_app_1"
      fi
      return 0 ;;
    inspect)
      [[ "$2" == --format ]] && printf '%s' "$3" > "$T/inspect.format"
      return 0 ;;
    rm|network) return 0 ;;
    *) return 1 ;;
  esac
}

# The compose line of the one-off (the last one)
run_line() { tail -n1 "$COMPOSE_LOG"; }
run_override() { yq "$1" "$PCM_CACHE_HOME/$2.run.override.yml"; }

@test "usage: a service is needed and must exist" {
  define "$T/src/a/containers" app
  load_sources
  run cli_call run </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage: pcm run"* ]]
  run cli_call run ghost -- true </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown service 'ghost'"* ]]
  [ ! -s "$COMPOSE_LOG" ]
}

@test "the compose line: the one-off's override, a name, --no-deps, --rm, -T without a terminal" {
  define "$T/src/a/containers" app
  load_sources
  run cli_call run app -- echo hi </dev/null
  [ "$status" -eq 0 ]
  local re='^-p app -f [^ ]*/a/containers/app/compose\.yml -f [^ ]*/app\.run\.override\.yml run --name app-run-[0-9a-f]{6} --no-deps --rm -T app echo hi$'
  [[ "$(run_line)" =~ $re ]]
}

@test "options: undeclared ones are the command's, --keep keeps it, -u is the user, no command runs the service's" {
  define "$T/src/a/containers" app
  load_sources
  run cli_call run app ls -la </dev/null
  [[ "$(run_line)" == *" --rm -T app ls -la" ]]
  run cli_call run --keep app -- sh -c 'exit 0' </dev/null
  [ "$status" -eq 0 ]
  [[ "$(run_line)" == *" --no-deps -T app sh -c exit 0" ]]
  [[ "$(run_line)" != *--rm* ]]
  [[ "$output" =~ kept\ app-run-[0-9a-f]{6}\ \(pcm\ remove\ app ]]
  run cli_call run -u bob app </dev/null
  [[ "$(run_line)" == *" --no-deps --rm -u bob -T app" ]]
}

@test "the exit status is the command's" {
  define "$T/src/a/containers" app
  load_sources
  FAKE_RC=3 run cli_call run app -- false </dev/null
  [ "$status" -eq 3 ]
}

@test "-s: the only compose service by default; several need one; an unknown one is an error" {
  define "$T/src/a/containers" app 'services:
  web:
    image: docker.io/library/alpine:3
  worker:
    image: docker.io/library/alpine:3'
  load_sources
  run cli_call run app -- true </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"several compose services; pick one with -s: web worker"* ]]
  run cli_call run app -s nope -- true </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"no compose service 'nope' (it has: web worker)"* ]]
  [ ! -s "$COMPOSE_LOG" ]
  run cli_call run app -s worker -- true </dev/null
  [ "$status" -eq 0 ]
  [[ "$(run_line)" == *" -T worker true" ]]
}

@test "the one-off's override: io.pcm.oneoff and pcm's labels; the service's own is not written" {
  define "$T/src/a/containers" app
  load_sources
  run cli_call run app -- true </dev/null
  [ "$(run_override '.services.app.labels["io.pcm.oneoff"]' app)" = true ]
  [ "$(run_override '.services.app.labels["io.pcm.id"]' app)" = a/app ]
  [ "$(run_override '.services.app.labels["io.pcm.name"]' app)" = app ]
  [ ! -e "$PCM_CACHE_HOME/app.override.yml" ]
}

@test "an ingress service: no ingress labels on the one-off, and its proxy is not started" {
  define "$T/src/a/containers" traefik 'services:
  proxy:
    image: docker.io/library/alpine:3
x-pcm:
  provides: proxy'
  printf '#!/usr/bin/env bash\nfor a in "$@"; do echo "test.$a"; done\n' > "$T/src/a/containers/traefik/labels"
  chmod +x "$T/src/a/containers/traefik/labels"
  define "$T/src/a/containers" app 'services:
  web:
    image: docker.io/library/alpine:3
x-pcm:
  ingress:
    port: 3000'
  load_sources
  [ "$(dep_ids a/app)" = a/traefik ]
  run cli_call run app -- true </dev/null
  [ "$status" -eq 0 ]
  [ "$(run_override '.services.web.labels["io.pcm.ingress"]' app)" = null ]
  [ "$(run_override '.services.web.labels | keys | map(select(test("^test"))) | length' app)" = 0 ]
  ! grep -q -- '-p traefik' "$COMPOSE_LOG"
}

@test "x-pcm.depends_on: a dependency not running is started first, as up starts it" {
  define "$T/src/a/containers" db
  define "$T/src/a/containers" app 'services:
  app:
    image: docker.io/library/alpine:3
x-pcm:
  depends_on: [db]'
  load_sources
  run cli_call run app -- true </dev/null
  [ "$status" -eq 0 ]
  [[ "$(sed -n 1p "$COMPOSE_LOG")" =~ ^-p\ db\ .*\ up\ -d$ ]]
  [[ "$(run_line)" == "-p app "*" run --name app-run-"* ]]
}

@test "compose depends_on: a sibling not running is started with the service's override; a running one is not" {
  define "$T/src/a/containers" app 'services:
  web:
    image: docker.io/library/alpine:3
    depends_on: [db]
  db:
    image: docker.io/library/alpine:3'
  load_sources
  run cli_call run app -s web -- true </dev/null
  [ "$status" -eq 0 ]
  [[ "$(sed -n 1p "$COMPOSE_LOG")" =~ ^-p\ app\ -f\ [^\ ]*/compose\.yml\ -f\ [^\ ]*/app\.override\.yml\ up\ -d\ db$ ]]
  [[ "$output" == *"starting db of a/app (required by web)"* ]]
  [ "$(wc -l < "$COMPOSE_LOG")" -eq 2 ]
  : > "$COMPOSE_LOG"
  RUNNING=db
  run cli_call run app -s web -- true </dev/null
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$COMPOSE_LOG")" -eq 1 ]
}

@test "the service's own containers leave one-offs out: project_containers, _box_container, pcm_containers" {
  define "$T/src/a/containers" app
  load_sources
  project_containers a/app -a
  _box_container a/app
  pcm_containers
  [ "$(grep -c -- 'label!=io.pcm.oneoff' "$CALLS")" -eq 3 ]
}

@test "remove: the one-offs go first and are in its summary; the run override goes" {
  define "$T/src/a/containers" app
  load_sources
  ONEOFFS="app-run-abc123 app-run-def456"
  mkdir -p "$PCM_CACHE_HOME"
  touch "$PCM_CACHE_HOME/app.run.override.yml"
  run cli_call remove -y app </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"one-offs     app-run-abc123 app-run-def456"* ]]
  grep -qxF "rm -f app-run-abc123 app-run-def456" "$CALLS"
  [ ! -e "$PCM_CACHE_HOME/app.run.override.yml" ]
}

@test "show: the kept one-offs are named" {
  define "$T/src/a/containers" app
  load_sources
  ONEOFFS="app-run-abc123"
  run cmd_show app
  [[ "$output" == *"one-offs     app-run-abc123"* ]]
}

@test "show: the mounts format binds the name before range (podman 6: \$ is the list of results)" {
  define "$T/src/a/containers" app
  load_sources
  SHOWN=a/app
  run cmd_show app
  [ "$status" -eq 0 ]
  [ "$(cat "$T/inspect.format")" = '{{$n := .Name}}{{range .Mounts}}{{$n}}	{{.Source}} -> {{.Destination}}{{if not .RW}} (ro){{end}}
{{end}}' ]
}

@test "show: an exited container podman gave no finish time is exited (unclean), others keep podman's Status" {
  define "$T/src/a/containers" app
  load_sources
  SHOWN=a/app
  SHOWN_ROWS='app_db_1\texited\t-62135596800\tExited (0) 292 years ago\t\napp_app_1\texited\t1790027654\tExited (143) 4 weeks ago\t0.0.0.0:80->80/tcp\napp_web_1\trunning\t-62135596800\tUp 2 hours\t\n'
  run cmd_show app
  [ "$status" -eq 0 ]
  [[ "$output" =~ app_db_1\ +exited\ \(unclean\) ]]
  [[ "$output" != *"292 years"* ]]
  [[ "$output" =~ app_app_1\ +Exited\ \(143\)\ 4\ weeks\ ago\ + ]]
  [[ "$output" == *"0.0.0.0:80->80/tcp"* ]]
  [[ "$output" =~ app_web_1\ +Up\ 2\ hours ]]
}

# A compose runner that, like podman-compose 1.6, runs `podman rmi` for down --rmi with the images
# of the project's containers, and with none prints podman's error (r-20261022-3)
rmi_runner() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$COMPOSE_LOG"\n[[ " $* " != *" --rmi "* || -n "$BUILT" ]] || echo "Error: image name or ID must be specified" >&2\n' > "$T/bin/compose"
}

@test "remove: a stock image (no build:) asks compose for no --rmi; nothing from podman's rmi" {
  define "$T/src/a/containers" app
  load_sources
  rmi_runner
  SHOWN=a/app BUILT=""
  export BUILT
  run cli_call remove -y app </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"Error:"* ]]
  [[ "$output" != *"images "* ]]
  grep -q -- ' down --volumes --remove-orphans$' "$COMPOSE_LOG"
}

@test "remove: a built image goes with --rmi local while its containers exist; with none, no --rmi" {
  define "$T/src/a/containers" app 'services:
  app:
    build: .
    image: app'
  load_sources
  rmi_runner
  SHOWN=a/app BUILT=localhost/app
  export BUILT
  run cli_call remove -y app </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"images       the ones compose built"* ]]
  grep -q -- ' down --volumes --remove-orphans --rmi local$' "$COMPOSE_LOG"
  : > "$COMPOSE_LOG"
  SHOWN="" BUILT=""
  run cli_call remove -y app </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"Error:"* ]]
  grep -q -- ' down --volumes --remove-orphans$' "$COMPOSE_LOG"
}
