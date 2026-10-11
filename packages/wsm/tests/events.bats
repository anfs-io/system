#!/usr/bin/env bats
# Events: wsm tells whoever registered with it (lib/anfs/callbacks.sh) which levels a run
# installed or removed, once, when the command is over. The listener here is a script that logs
# its arguments.
# Run: bats packages/wsm/tests/events.bats

load helper
setup() {
  wsm_setup
  mksource acme >/dev/null
  space_def acme main/tech <<'YML'
repositories: []
YML
  space_def acme main/org <<'YML'
repositories: []
YML
  CALLS="$BATS_TEST_TMPDIR/calls"
  REGISTRATIONS="$XDG_STATE_HOME/anfs/callbacks/wsm.yml"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "${REGISTRATIONS%/*}"
  cat > "$BATS_TEST_TMPDIR/bin/listener" <<SH
#!/bin/sh
echo "\$*" >> "$CALLS"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/listener"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  printf 'test/listener: listener heard\n' > "$REGISTRATIONS"
}

@test "install emits once, with every level that became installed" {
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  run cat "$CALLS"
  [ "$output" = "heard install acme acme/main acme/main/tech" ]
}

@test "installing what is installed emits nothing; a new level emits only itself" {
  wsm install acme/main/tech >/dev/null
  rm "$CALLS"
  wsm install acme/main/tech >/dev/null
  [ ! -f "$CALLS" ]
  wsm install acme/main/org >/dev/null
  run cat "$CALLS"
  [ "$output" = "heard install acme/main/org" ]
}

@test "--dry-run emits nothing" {
  run wsm install acme/main/tech --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
}

@test "remove emits the levels that went" {
  wsm install acme/main/tech >/dev/null
  wsm install acme/main/org >/dev/null
  rm "$CALLS"
  run wsm remove acme/main/tech
  [ "$status" -eq 0 ]
  run cat "$CALLS"
  [ "$output" = "heard remove acme/main/tech" ]
}

@test "new into an installed workspace emits install for the space it installs" {
  wsm install acme/main/tech >/dev/null
  rm "$CALLS"
  run wsm new acme/main/web
  [ "$status" -eq 0 ]
  run cat "$CALLS"
  [ "$output" = "heard install acme/main/web" ]
}

@test "new that only creates the space in the source emits nothing" {
  run wsm new acme/main/web
  [ "$status" -eq 0 ]
  [ ! -f "$CALLS" ]
}

@test "implode emits remove, and the registrations outlive wsm's state" {
  wsm install acme/main/tech >/dev/null
  rm "$CALLS"
  run wsm implode -y
  [ "$status" -eq 0 ]
  run cat "$CALLS"
  [[ "$output" == "heard remove "*"acme/main/tech"* ]]
  [ ! -e "$XDG_STATE_HOME/wsm" ]
  # They are the listener's, kept by anfs: a later install is heard without registering again
  [ -f "$REGISTRATIONS" ]
  rm "$CALLS"
  wsm install acme/main/tech >/dev/null
  run cat "$CALLS"
  [ "$output" = "heard install acme acme/main acme/main/tech" ]
}

@test "a listener that fails or is gone does not fail the command" {
  printf 'test/broken: false\ntest/gone: no-such-command x\ntest/listener: listener heard\n' > "$REGISTRATIONS"
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"callback of test/broken for wsm install failed"* ]]
  [[ "$output" != *"test/gone"* ]]
  run cat "$CALLS"
  [ "$output" = "heard install acme acme/main acme/main/tech" ]
}

@test "the options every tool takes come before the command" {
  run wsm -d install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"wsm: debug: callbacks: wsm install -> test/listener"* ]]
  run wsm --debug --version
  [ "$status" -eq 0 ]
  [[ "$output" == wsm\ * ]]
}
