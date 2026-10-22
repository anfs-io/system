#!/usr/bin/env bats
# ppm's message file (lib/ppm/core.sh, user_message) is RUNTIME: in $TMPDIR, so a job's run
# (anfs work run sets TMPDIR) keeps it to itself; /tmp only when TMPDIR is unset.
# Run: bats packages/ppm/tests/messages.bats

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

setup() {
  LIB="$BATS_TEST_DIRNAME/../home/.local/lib/ppm"
  ANFS="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"
  mkdir -p "$BATS_TEST_TMPDIR/tmp"
}

@test "the message file is made in TMPDIR, and holds what user_message queues" {
  run env TMPDIR="$BATS_TEST_TMPDIR/tmp" ANFS_LOG=off bash -c '
    source "$1/log.sh"; source "$2/core.sh"; trap - EXIT
    user_message "hello"; echo "$PPM_MSG_FILE"; cat "$PPM_MSG_FILE"; rm -f "$PPM_MSG_FILE"' _ "$ANFS" "$LIB"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "$BATS_TEST_TMPDIR/tmp/ppm-messages."* ]] || { echo "$output"; return 1; }
  [ "${lines[1]}" = hello ]
}

@test "core.sh names no fixed /tmp for it; implode sweeps TMPDIR" {
  ! grep -n 'mktemp /tmp' "$LIB/core.sh"
  grep -q 'rm -f "${TMPDIR:-/tmp}"/ppm-messages' "$LIB/implode.sh"
}
