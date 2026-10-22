#!/usr/bin/env bats
# lib/anfs/callbacks.sh: registering with a tool, and the tool emitting an event to whoever did.
# Also `anfs callbacks` and `anfs log`, the commands over this and log.sh.
# Run: bats packages/anfs/tests/

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

setup() {
  LIB="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export ANFS_STATE_HOME="$XDG_STATE_HOME/anfs"
  unset ANFS_DEBUG ANFS_LOG
  CLI_TOOL=toola
  # shellcheck source=/dev/null
  source "$LIB/log.sh"
  source "$LIB/callbacks.sh"

  CALLS="$BATS_TEST_TMPDIR/calls"
  FILE="$ANFS_STATE_HOME/callbacks/toola.yml"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/listener" <<SH
#!/bin/sh
echo "\$*" >> "$CALLS"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/listener"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "register records name: handler in anfs's state, one file per tool, and replaces" {
  anfs_callback_register toola one "listener first"
  anfs_callback_register toola one "listener a"
  anfs_callback_register toola two "listener b"
  run yq -r '.one' "$FILE"
  [ "$output" = "listener a" ]
  run yq -r 'keys | length' "$FILE"
  [ "$output" = "2" ]
}

@test "registrations are anfs's, not the tool's: the tool's state home is not where they go" {
  TOOLA_STATE_HOME="$BATS_TEST_TMPDIR/elsewhere"
  anfs_callback_register toola one "listener a"
  [ -f "$FILE" ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
  unset ANFS_STATE_HOME
  anfs_callback_register toola two "listener b"
  [ -f "$XDG_STATE_HOME/anfs/callbacks/toola.yml" ]
}

@test "register needs all three" {
  run anfs_callback_register toola one
  [ "$status" -eq 1 ]
  [ ! -e "$FILE" ]
}

@test "unregister drops only that name; unknown names and tools are fine" {
  anfs_callback_register toola one "listener a"
  anfs_callback_register toola two "listener b"
  anfs_callback_unregister toola one
  anfs_callback_unregister toola nobody
  anfs_callback_unregister toolz one
  run yq -r 'keys | .[]' "$FILE"
  [ "$output" = "two" ]
}

@test "run calls every listener with the event and the arguments, in order" {
  anfs_callback_register toola one "listener a"
  anfs_callback_register toola two "listener b --flag"
  anfs_callbacks_run toola install x "y z"
  run cat "$CALLS"
  [ "${lines[0]}" = "a install x y z" ]
  [ "${lines[1]}" = "b --flag install x y z" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "arguments reach the handler as they were given" {
  cat > "$BATS_TEST_TMPDIR/bin/count" <<SH
#!/bin/sh
echo "\$#" >> "$CALLS"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/count"
  anfs_callback_register toola one count
  anfs_callbacks_run toola install "two words" 'a;b' '$HOME'
  run cat "$CALLS"
  [ "$output" = "4" ]
}

@test "nothing runs without arguments, without registrations, or for another tool" {
  anfs_callbacks_run toola install x
  anfs_callback_register toola one "listener a"
  anfs_callbacks_run toola install
  anfs_callbacks_run toolb install x
  [ ! -f "$CALLS" ]
}

@test "a failing listener is reported and the rest still run" {
  anfs_callback_register toola bad "false"
  anfs_callback_register toola good "listener ok"
  run anfs_callbacks_run toola remove x
  [ "$status" -eq 0 ]
  [[ "$output" == *"toola: callback of bad for toola remove failed (exit 1): false"* ]]
  run cat "$CALLS"
  [ "$output" = "ok remove x" ]
}

@test "a listener whose command is gone is skipped quietly, and reads as stale" {
  anfs_callback_register toola gone "no-such-command x"
  anfs_callback_register toola good "listener ok"
  run anfs_callbacks_run toola install x
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run anfs_callbacks_ls toola
  [ "${lines[0]}" = "toola"$'\t'"gone"$'\t'"stale"$'\t'"no-such-command x" ]
  [ "${lines[1]}" = "toola"$'\t'"good"$'\t'"ok"$'\t'"listener ok" ]
}

@test "a listener that reads stdin does not eat the registrations" {
  cat > "$BATS_TEST_TMPDIR/bin/greedy" <<SH
#!/bin/sh
cat >/dev/null
echo greedy >> "$CALLS"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/greedy"
  anfs_callback_register toola a greedy
  anfs_callback_register toola b "listener after"
  anfs_callbacks_run toola install x < /dev/null
  run cat "$CALLS"
  [ "${lines[1]}" = "after install x" ]
}

@test "a listener cannot change the emitting tool: it runs in a subshell" {
  toola_callback_invoke() { LEAK=yes; cd /; }
  anfs_callback_register toola one anything
  local here="$PWD"
  anfs_callbacks_run toola install x
  [ -z "${LEAK:-}" ]
  [ "$PWD" = "$here" ]
}

@test "a tool's own invoker replaces the default, and gets name, handler, event, arguments" {
  toola_callback_invoke() { echo "$*" >> "$CALLS"; }
  anfs_callback_register toola pkg/one some_function
  anfs_callbacks_run toola install x y
  run cat "$CALLS"
  [ "$output" = "pkg/one some_function install x y" ]
}

@test "ls covers every tool with registrations, and a tool's own idea of stale" {
  anfs_callback_register toola one "listener a"
  anfs_callback_register toolb pkg/x fn
  toolb_callback_state() { echo stale; }
  run anfs_callbacks_ls
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "toola"$'\t'"one"$'\t'"ok"$'\t'"listener a" ]
  [ "${lines[1]}" = "toolb"$'\t'"pkg/x"$'\t'"stale"$'\t'"fn" ]
}

# --- the commands -------------------------------------------------------------------------------

anfs_cmd() {
  mkdir -p "$BATS_TEST_TMPDIR/home/.local/lib" "$BATS_TEST_TMPDIR/home/.config/anfs"
  [[ -e "$BATS_TEST_TMPDIR/home/.local/lib/anfs" ]] || ln -s "$LIB" "$BATS_TEST_TMPDIR/home/.local/lib/anfs"
  HOME="$BATS_TEST_TMPDIR/home" XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/home/.config" \
    "$BATS_TEST_DIRNAME/../home/.local/bin/anfs" "$@"
}

@test "anfs callbacks: every registration; ppm's are ok while the package is installed" {
  run anfs_cmd callbacks
  [ "$output" = "no callbacks registered" ]
  anfs_callback_register wsm stack/obsidian "listener x"
  anfs_callback_register ppm core/psm psm_ppm_changed
  anfs_callback_register ppm core/gone old_fn
  mkdir -p "$XDG_STATE_HOME/ppm/installed/core"
  echo "version: 0.1.0" > "$XDG_STATE_HOME/ppm/installed/core/psm.yml"
  run anfs_cmd callbacks
  [ "$status" -eq 0 ]
  [[ "$output" == *"ppm"$'\t'"core/psm"$'\t'"ok"$'\t'"psm_ppm_changed"* ]]
  [[ "$output" == *"ppm"$'\t'"core/gone"$'\t'"stale"$'\t'"old_fn"* ]]
  [[ "$output" == *"wsm"$'\t'"stack/obsidian"$'\t'"ok"$'\t'"listener x"* ]]
  run anfs_cmd callbacks wsm
  [ "${#lines[@]}" -eq 1 ]
}

@test "anfs log: the whole log, or one tool's" {
  CLI_TOOL=wsm anfs_warn "from wsm"
  CLI_TOOL=wsmx anfs_warn "from wsmx"
  CLI_TOOL=ppm anfs_warn "from ppm"
  run anfs_cmd log
  [[ "$output" == *"from wsm"* && "$output" == *"from ppm"* ]]
  run anfs_cmd log wsm
  [[ "$output" == *"warn: from wsm" ]]
  [[ "$output" != *"wsmx"* && "$output" != *"from ppm"* ]]
}
