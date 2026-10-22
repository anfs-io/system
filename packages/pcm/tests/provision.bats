#!/usr/bin/env bats
# pcm provision / pcm deprovision (units/pcm/02-provision): a service's hooks for a consumer that
# is not a pcm definition. podman is a stub whose `ps` finds the service running when $T/running
# exists; the compose runner is a script that records its arguments and creates $T/running on up;
# varlock is a script that records its arguments and runs the hook with a schema variable set.
# Run: ANFS_TESTS_PMM_PCM=1 bats packages/pcm/tests/provision.bats

load helper
bats_require_minimum_version 1.5.0

setup() {
  pcm_setup
  add_source a
  OSTYPE=linux-gnu
  PCM_ATTACHED_SERVICES=""
  PCM_HEALTH_TIMEOUT=5
  CALLS="$T/podman.calls" COMPOSE_LOG="$T/compose.log" VARLOCK_LOG="$T/varlock.log"
  HOOK_LOG="$T/hook.log" RUNNING_FILE="$T/running"
  export COMPOSE_LOG VARLOCK_LOG HOOK_LOG RUNNING_FILE
  : > "$CALLS" ; : > "$COMPOSE_LOG" ; : > "$VARLOCK_LOG" ; : > "$HOOK_LOG"
  mkdir -p "$T/bin"
  cat > "$T/bin/compose" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COMPOSE_LOG"
[[ " $* " != *" up "* ]] || touch "$RUNNING_FILE"
echo "compose says hello"
EOF
  cat > "$T/bin/varlock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$VARLOCK_LOG"
case "$1" in
  load) echo "DB_SCHEMA_VAR=from-schema"; exit 0 ;;
  run) while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
       export DB_SCHEMA_VAR=from-schema; exec "$@" ;;
esac
exit 1
EOF
  chmod +x "$T/bin/compose" "$T/bin/varlock"
  PATH="$T/bin:$PATH"
  RUNNER=("$T/bin/compose")
  OTHER_ID=""   # the io.pcm.id a running container reports (another definition's)

  # The definition: one compose service, a schema, and hooks that record what they got
  define "$T/src/a/containers" db
  printf '# @type=string\nDB_SCHEMA_VAR=from-schema\n' > "$T/src/a/containers/db/.env.schema"
  hook provision 'echo "provision: working for $PCM_DEPENDENT" >&2
echo "not a pair"
echo "URL=postgres://u:s3cret-value@db:5432/x"
echo "PASSWORD=s3cret-value"
echo "lower=ignored"'
  hook deprovision 'echo "deprovision: dropping for $PCM_DEPENDENT"
echo "dropped" >&2'
  load_sources
}

# hook <name> <body>: an executable hook in db's directory that logs its env and args first
hook() {
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s|%%s|%%s\\n" "%s" "$PCM_SERVICE" "$PCM_PROJECT" "$PCM_DEPENDENT" "$DB_SCHEMA_VAR $*" >> "$HOOK_LOG"\n%s\n' \
    "$1" "$2" > "$T/src/a/containers/db/$1"
  chmod +x "$T/src/a/containers/db/$1"
}

podman() {
  echo "$*" >> "$CALLS"
  case "$1" in
    ps) [[ -f "$RUNNING_FILE" && "$*" == *"label=io.pcm.name=db "* ]] && echo db_db_1; return 0 ;;
    inspect) [[ "$*" == *io.pcm.id* ]] && echo "${OTHER_ID:-a/db}"; return 0 ;;
    network|healthcheck) return 0 ;;
    *) return 1 ;;
  esac
}

@test "provision, running: the hook under varlock with pcm's env and the args; only KEY=VALUE on stdout" {
  touch "$RUNNING_FILE"
  run --separate-stderr cli_call provision db --as partitia/shop database=shop </dev/null
  [ "$status" -eq 0 ]
  [ "$output" == $'URL=postgres://u:s3cret-value@db:5432/x\nPASSWORD=s3cret-value' ]
  [[ "$stderr" == *"provision: working for partitia/shop"* ]]
  [[ "$stderr" == *"provisioned a/db for partitia/shop: URL PASSWORD"* ]]
  [ "$(cat "$HOOK_LOG")" == "provision|db|db|partitia/shop|from-schema database=shop" ]
  [[ "$(cat "$VARLOCK_LOG")" == *"run --inject vars --no-redact-stdout -- "*"/db/provision database=shop"* ]]
  [ ! -s "$COMPOSE_LOG" ]   # nothing started
}

@test "provision, stopped: started as up starts it (compose up -d), then provisioned" {
  run --separate-stderr cli_call provision db </dev/null
  [ "$status" -eq 0 ]
  grep -q -- ' up -d$' "$COMPOSE_LOG"
  [[ "$stderr" == *"compose says hello"* ]]   # compose's output is not the consumer's
  [ "$output" == $'URL=postgres://u:s3cret-value@db:5432/x\nPASSWORD=s3cret-value' ]
  [ "$(cat "$HOOK_LOG")" == "provision|db|db|external|from-schema " ]
}

@test "provision: --json prints one object of the pairs" {
  touch "$RUNNING_FILE"
  ANFS_JSON=true run --separate-stderr cli_call provision db </dev/null
  [ "$status" -eq 0 ]
  [ "$output" == '{"URL":"postgres://u:s3cret-value@db:5432/x","PASSWORD":"s3cret-value"}' ]
}

@test "provision: no hook is an error, and nothing starts" {
  rm "$T/src/a/containers/db/provision"
  run cli_call provision db </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"a/db has no provision hook"* ]]
  [ ! -s "$COMPOSE_LOG" ]
  [ ! -s "$HOOK_LOG" ]
}

@test "provision: a hook that fails prints nothing on stdout and exits 1" {
  hook provision 'echo "URL=half"; exit 3'
  touch "$RUNNING_FILE"
  run --separate-stderr cli_call provision db </dev/null
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"provisioning a/db for external failed"* ]]
}

@test "provision: refused while another definition of the name runs" {
  touch "$RUNNING_FILE"
  OTHER_ID=b/db
  run cli_call provision db </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"db is already running from b/db"* ]]
  [ ! -s "$HOOK_LOG" ]
}

@test "usage: a service, a known one, settings as key=value, a sane --as" {
  run cli_call provision </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage: pcm provision [--as NAME] <service> [setting...]"* ]]
  run cli_call provision ghost </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown service 'ghost'"* ]]
  run cli_call provision db notapair </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"not a key=value setting: 'notapair'"* ]]
  run cli_call deprovision db --as 'two words' </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"--as"* ]]
  [ ! -s "$HOOK_LOG" ]
}

@test "deprovision, running: the hook with the same env and args, its output on stderr" {
  touch "$RUNNING_FILE"
  run --separate-stderr cli_call deprovision db --as smoke-test database=x </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"deprovision: dropping for smoke-test"* ]]
  [ "$(cat "$HOOK_LOG")" == "deprovision|db|db|smoke-test|from-schema database=x" ]
  [ ! -s "$COMPOSE_LOG" ]
}

@test "deprovision, stopped: not started, says what is left in place, exits 1" {
  run cli_call deprovision db --as smoke-test database=x </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"a/db is not running; what it provisioned for smoke-test (database=x) is left in place"* ]]
  [ ! -s "$COMPOSE_LOG" ]
  [ ! -s "$HOOK_LOG" ]
}

@test "deprovision: no hook is an error" {
  rm "$T/src/a/containers/db/deprovision"
  touch "$RUNNING_FILE"
  run cli_call deprovision db </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"a/db has no deprovision hook"* ]]
}

@test "the log: key names, never a value" {
  export ANFS_LOG=on ANFS_STATE_HOME="$T/anfs/state"
  touch "$RUNNING_FILE"
  run cli_call provision db --as smoke-test </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"s3cret-value"* ]]
  grep -q "provisioned a/db for smoke-test: URL PASSWORD" "$T/anfs/state/anfs.log"
  ! grep -q "s3cret-value" "$T/anfs/state/anfs.log"
}

@test "up's provisioning is unchanged: a dependent gets PCM_DB_* from the same hook" {
  define "$T/src/a/containers" app 'x-pcm:
  depends_on:
    db:
      database: app
services:
  app:
    image: docker.io/library/alpine:3'
  load_sources
  touch "$RUNNING_FILE"
  PROVISIONED=()
  start_deps a/app
  [ "${PROVISIONED[*]}" == "PCM_DB_URL=postgres://u:s3cret-value@db:5432/x PCM_DB_PASSWORD=s3cret-value" ]
  [ "$(cat "$HOOK_LOG")" == "provision|db|db|app|from-schema database=app" ]
}

@test "completion: provision and deprovision are commands, and take a service" {
  run cli_dispatch __complete "" </dev/null
  [[ "$output" == *$'\n'provision* && "$output" == *$'\n'deprovision* ]]
  define "$PCM_CONTAINERS_HOME" mine   # completion reads file names: the local source's here
  run cli_dispatch __complete provision "" </dev/null
  [[ "$output" == *mine* ]]
  run cli_dispatch __complete deprovision "" </dev/null
  [[ "$output" == *mine* ]]
}
