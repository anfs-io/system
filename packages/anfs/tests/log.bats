#!/usr/bin/env bats
# lib/anfs/log.sh: what a tool says and the log every tool writes; and the options cli.sh gives
# every tool before its command (-d/--debug, --trace).
# Run: bats packages/anfs/tests/

bats_require_minimum_version 1.5.0

setup() {
  LIB="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  export ANFS_STATE_HOME="$BATS_TEST_TMPDIR/state"
  LOG="$ANFS_STATE_HOME/anfs.log"
  unset ANFS_DEBUG ANFS_TRACE ANFS_LOG DEMO_DEBUG NO_COLOR
  # A tool the way the real ones are built: the library, cli.sh, one command
  TOOL="$BATS_TEST_TMPDIR/demo"
  cat > "$TOOL" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$LIB/log.sh"
source "$LIB/cli.sh"
CLI_TOOL=demo
cli_cmd say "Say something" --arg "level" --arg "msg"
cmd_say() {
  case "\$1" in
    info) anfs_info "\$2" ;;
    warn) anfs_warn "\$2" ;;
    debug) anfs_debug "\$2" ;;
    die) anfs_die "\$2" ;;
    fail) anfs_fail 73 "\$2" ;;
  esac
}
cli_dispatch "\$@"
SH
  chmod +x "$TOOL"
}

@test "info goes to stdout, unprefixed and unlogged" {
  run --separate-stderr "$TOOL" say info hello
  [ "$output" = "hello" ]
  [ -z "$stderr" ]
  # Only the start line (the invocation) mentions it
  run grep -c hello "$LOG"
  [ "$output" = "1" ]
}

@test "warn goes to stderr with the tool's name, and to the log" {
  run --separate-stderr "$TOOL" say warn careful
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$stderr" = "demo: careful" ]
  grep -Eq '^[0-9T:+-]+ demo\[[0-9]+\] warn: careful$' "$LOG"
}

@test "die exits 1 and fail exits with its code, both logged as errors" {
  run "$TOOL" say die broken
  [ "$status" -eq 1 ]
  [ "$output" = "demo: broken" ]
  run "$TOOL" say fail exists
  [ "$status" -eq 73 ]
  [ "$output" = "demo: exists" ]
  grep -q 'demo\[[0-9]*\] error: broken$' "$LOG"
  grep -q 'demo\[[0-9]*\] error: exists (exit 73)$' "$LOG"
}

@test "debug is always logged, and shown only when debugging is on" {
  run "$TOOL" say debug quiet
  [ -z "$output" ]
  grep -q 'debug: quiet$' "$LOG"
  run "$TOOL" -d say debug loud
  [ "$output" = "demo: debug: loud" ]
  run "$TOOL" --debug say debug loud
  [ "$output" = "demo: debug: loud" ]
}

@test "ANFS_DEBUG is every tool's, <TOOL>_DEBUG one tool's; false and 0 are off" {
  ANFS_DEBUG=1 run "$TOOL" say debug a
  [ "$output" = "demo: debug: a" ]
  DEMO_DEBUG=true run "$TOOL" say debug b
  [ "$output" = "demo: debug: b" ]
  OTHER_DEBUG=true run "$TOOL" say debug c
  [ -z "$output" ]
  ANFS_DEBUG=false DEMO_DEBUG=0 run "$TOOL" say debug d
  [ -z "$output" ]
}

@test "-d is exported, so a tool this one runs debugs too" {
  cat >> "$TOOL" <<'SH'
SH
  sed -i.bak 's|^cli_dispatch.*|cli_cmd env "Print ANFS_DEBUG as a child sees it"\ncmd_env() { bash -c "echo child=\\${ANFS_DEBUG:-unset}"; }\ncli_dispatch "$@"|' "$TOOL"
  run "$TOOL" -d env
  [ "$output" = "child=true" ]
  run "$TOOL" env
  [ "$output" = "child=unset" ]
}

@test "the options are listed in help, and only read before the command" {
  run "$TOOL" help
  [[ "$output" == *"-d, --debug"* ]]
  [[ "$output" == *"--trace"* ]]
  # After the command, -d is the command's to take or refuse
  run "$TOOL" say debug -d
  [ "$status" -eq 64 ]
}

@test "--trace traces with file, line and function" {
  run "$TOOL" --trace say info x
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ demo:"*":cmd_say: anfs_info x"* ]]
}

@test "every invocation logs one start line with its arguments" {
  "$TOOL" say info "two words"
  run grep -c ' start: ' "$LOG"
  [ "$output" = "1" ]
  grep -q 'demo\[[0-9]*\] start: [0-9]*-[0-9]* say info two words$' "$LOG"
}

@test "every invocation ends with an end line: the start line's id and the exit status" {
  "$TOOL" say info x
  run "$TOOL" say fail y
  local id
  id=$(awk '/ start: / { print $4; exit }' "$LOG")
  [[ "$id" =~ ^[0-9]+-[0-9]+$ ]]
  grep -q "demo\[${id%-*}\] end: $id 0\$" "$LOG"
  [ "$(grep -c ' end: [0-9]*-[0-9]* 73$' "$LOG")" = 1 ]
  [ "$(grep -c ' end: ' "$LOG")" = 2 ]
}

@test "the end line keeps the tool's own EXIT trap and its exit status" {
  sed -i.bak 's|^CLI_TOOL=demo$|CLI_TOOL=demo; trap "echo cleaned >\&2" EXIT|' "$TOOL"
  run "$TOOL" say fail z
  [ "$status" -eq 73 ]
  [[ "$output" == *cleaned* ]]
  grep -q ' end: [0-9]*-[0-9]* 73$' "$LOG"
}

@test "anfs_on_exit inside a command: its cleanup runs and the end line is kept" {
  sed -i.bak 's|^    fail) anfs_fail 73 "\$2" ;;$|    fail) anfs_fail 73 "\$2" ;;\n    tidy) anfs_on_exit "echo tidied >\&2"; anfs_fail 73 "\$2" ;;|' "$TOOL"
  grep -q 'tidy)' "$TOOL"
  run "$TOOL" say tidy z
  [ "$status" -eq 73 ]
  [[ "$output" == *tidied* ]]
  grep -q ' end: [0-9]*-[0-9]* 73$' "$LOG"
}

@test "anfs_on_exit before logging starts is a plain EXIT trap, and '' clears it" {
  run bash -c "source '$LIB/log.sh'; anfs_on_exit 'echo bye'; true"
  [ "$output" = bye ]
  run bash -c "source '$LIB/log.sh'; anfs_on_exit 'echo bye'; anfs_on_exit ''; true"
  [ -z "$output" ]
}

@test "anfs_confirm without a terminal and without -y exits 77, message unchanged" {
  cat >> "$TOOL.ask" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$LIB/log.sh"
source "$LIB/cli.sh"
CLI_TOOL=demo
cli_cmd rm "Asks" --opt "-y --yes: Do not ask"
cmd_rm() { anfs_confirm "rm deletes it" "Remove?"; echo done; }
cli_dispatch "\$@"
SH
  chmod +x "$TOOL.ask"
  run "$TOOL.ask" rm </dev/null
  [ "$status" -eq 77 ]
  [ "$output" = "demo: rm deletes it; pass -y to confirm without a terminal" ]
  run "$TOOL.ask" rm -y </dev/null
  [ "$output" = done ]
}

@test "no colour codes in the log, or on a stderr that is not a terminal" {
  run "$TOOL" -d say debug plain
  [[ "$output" != *$'\033'* ]]
  ! grep -q $'\033' "$LOG"
}

@test "past the cap the log becomes anfs.log.1, replacing the last one" {
  mkdir -p "$ANFS_STATE_HOME"
  echo old-generation > "$LOG.1"
  head -c 2000 /dev/zero | tr '\0' 'x' > "$LOG"
  ANFS_LOG_MAX=1000 "$TOOL" say warn after
  [ "$(wc -c < "$LOG.1" | tr -d ' ')" = "2000" ]
  grep -q 'warn: after$' "$LOG"
  ! grep -q xxxx "$LOG"
}

@test "ANFS_LOG=off writes no file" {
  ANFS_LOG=off run "$TOOL" say warn x
  [ "$output" = "demo: x" ]
  [ ! -e "$ANFS_STATE_HOME" ]
}

@test "a log that cannot be written is not an error" {
  mkdir -p "$ANFS_STATE_HOME"
  mkdir "$LOG"
  run "$TOOL" say warn still
  [ "$status" -eq 0 ]
  [ "$output" = "demo: still" ]
}
