#!/usr/bin/env bats
# lib/anfs/events.sh: space ids, anfs_emit (one CloudEvent per line, appended to the space's log in
# STATE) and `anfs events ls` (filters, specs through wsm, -f and --once). A temp HOME with core's
# lib/anfs, anfs and wsm linked in; one source, acme, a local directory with three spaces (acme,
# acme/tech with ids, acme/bare without), and the tree ~/spaces/acme with acme's space.yml linked.
# Run: bats packages/anfs/tests/events.bats

bats_require_minimum_version 1.5.0
unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

UUID7='^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

setup() {
  PKGS="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  T=$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)
  export HOME="$T/home"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/lib" "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources" "$T/out"
  ln -s "$PKGS/anfs/home/.local/lib/anfs" "$HOME/.local/lib/anfs"
  ln -s "$PKGS/anfs/home/.local/bin/anfs" "$HOME/.local/bin/anfs"
  ln -s "$PKGS/wsm/home/.local/bin/wsm" "$HOME/.local/bin/wsm"
  SRC="$T/srcs/acme"
  mkdir -p "$SRC/spaces/tech" "$SRC/spaces/bare"
  printf 'id: acmeroot22\n' > "$SRC/spaces/space.yml"
  printf '# tech\nid: acmetech22\nrepositories: []\n' > "$SRC/spaces/tech/space.yml"
  printf 'repositories: []\n' > "$SRC/spaces/bare/space.yml"
  ln -s "$SRC" "$HOME/.local/share/anfs/sources/acme"
  printf '%s  acme\n' "$SRC" > "$HOME/.config/anfs/user.list"
  mkdir -p "$HOME/spaces/acme/notes"
  ln -s "$SRC/spaces/space.yml" "$HOME/spaces/acme/space.yml"
  EV="$HOME/.local/state/anfs/events"
  SYSPATH="$(dirname "$(command -v yq)"):$(dirname "$(command -v bash)"):/usr/bin:/bin"
  cd "$HOME"
}

# A clean environment: HOME, PATH, USER and NAME=value given first; events on
clean() {
  local -a vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i HOME="$HOME" PATH="$HOME/.local/bin:$SYSPATH" USER=tester TMPDIR="$T" ANFS_LOG=off \
    ${vars[@]+"${vars[@]}"} "$@"
}
# anfs_emit through the library, in the current directory
emit() {
  local -a vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  clean ${vars[@]+"${vars[@]}"} bash -c 'set -euo pipefail
    source "$HOME/.local/lib/anfs/paths.sh"; source "$ANFS_LIB_DIR/log.sh"; source "$ANFS_LIB_DIR/events.sh"
    anfs_emit "$@"' _ "$@"
}
# yq over JSON Lines: one result per line (yq separates documents with ---)
yqj() { yq -p json -oy "$@" | grep -vx -- '---'; }
# Every line of every log file
all_lines() { cat "$EV"/*/*.jsonl 2>/dev/null; }
# One attribute of the last line of a scope's log
attr() { tail -n 1 "$EV/$1"/*.jsonl | yq -p json -oy -r "$2"; }
ev() {
  local -a vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  clean ${vars[@]+"${vars[@]}"} anfs events "$@"
}

# --- ids ------------------------------------------------------------------------------------

@test "a new space id is 10 of a-z2-7, and they differ" {
  run clean bash -c 'source "$HOME/.local/lib/anfs/paths.sh"; source "$ANFS_LIB_DIR/events.sh"
    for i in $(seq 50); do anfs_space_id_new; echo "$REPLY"; done'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 50 ]
  for l in "${lines[@]}"; do [[ "$l" =~ ^[a-z2-7]{10}$ ]]; done
  [ "$(printf '%s\n' "${lines[@]}" | sort -u | wc -l | tr -d ' ')" = 50 ]
}

@test "an id is written before the first line that is not a comment; a {} file becomes the id; read back" {
  printf '# head\n\ndepends: [x]\n' > "$T/a.yml"
  printf '{}\n' > "$T/b.yml"
  printf 'id: "notvalid"\n' > "$T/c.yml"
  run clean bash -c 'source "$HOME/.local/lib/anfs/paths.sh"; source "$ANFS_LIB_DIR/events.sh"
    anfs_space_id_write "$1/a.yml" abcdefghij && anfs_space_id_write "$1/b.yml" bbbbbbbbbb
    anfs_space_id_read "$1/a.yml"; echo "$? $REPLY"
    anfs_space_id_read "$1/c.yml" || echo "$? $REPLY"
    anfs_space_id_read "$1/none.yml" || echo "$?"' _ "$T"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/a.yml")" = $'# head\n\nid: abcdefghij\ndepends: [x]' ]
  [ "$(cat "$T/b.yml")" = "id: bbbbbbbbbb" ]
  [ "$(yq -r .id "$T/b.yml")" = bbbbbbbbbb ]
  [ "${lines[0]}" = "0 abcdefghij" ]
  [ "${lines[1]}" = "2 notvalid" ]
  [ "${lines[2]}" = "1" ]
}

# --- emit -----------------------------------------------------------------------------------

@test "emit: one CloudEvent in the space around the directory (a source checkout), every attribute of the profile" {
  cd "$SRC/spaces/tech"
  run emit report.filed r-20261023-1 package=core/pcm 'title=it "broke"' to=file
  [ "$status" -eq 0 ] && [ -z "$output" ]
  f=$(ls "$EV/acmetech22"/*.jsonl)
  [ "$(wc -l < "$f" | tr -d ' ')" = 1 ]
  [[ "${f##*/}" =~ ^[0-9]{4}-[0-9]{2}\.jsonl$ ]]
  run yq -p json -o json -I0 '[.specversion, .source, .type, .subject, .datacontenttype, .actor, .spacepath, .anfsv, .data.package, .data.title, .data.to]' "$f"
  [ "$output" = '["1.0","/anfs/spaces/acmetech22","io.anfs.report.filed","r-20261023-1","application/json","shell:tester","acme/tech",1,"core/pcm","it \"broke\"","file"]' ]
  [[ "$(attr acmetech22 .id)" =~ $UUID7 ]]
  [[ "$(attr acmetech22 .time)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]
  # left out when empty: no actorspace, actorrole
  [ "$(attr acmetech22 'has("actorrole")')" = false ]
  # the month file is the event's UTC month
  [ "${f##*/}" = "$(attr acmetech22 .time | cut -c1-7).jsonl" ]
}

@test "emit: the space from the tree (~/spaces/<path>), from ANFS_SPACE, from --at; the host scope outside any" {
  cd "$HOME/spaces/acme/notes"
  emit a.b one
  [ "$(attr acmeroot22 .spacepath)" = acme ]
  cd "$T/out"
  emit ANFS_SPACE=acme/tech a.b two
  [ "$(attr acmetech22 .subject)" = two ]
  emit --at "$SRC/spaces/tech" a.b three
  [ "$(attr acmetech22 .subject)" = three ]
  emit a.b four
  [ "$(attr host .source)" = /anfs/host ]
  [ "$(attr host 'has("spacepath")')" = false ]
  run emit ANFS_SPACE=acme/nope a.b five
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANFS_SPACE=acme/nope names no space: the event goes to the host scope"* ]]
  [ "$(attr host .subject)" = five ]
  # --host wins over the directory
  cd "$SRC/spaces/tech"
  emit --host a.b six
  [ "$(attr host .subject)" = six ]
}

@test "emit: a space with no id warns and files in the host scope with its path" {
  cd "$SRC/spaces/bare"
  run emit a.b x
  [ "$status" -eq 0 ]
  [[ "$output" == *"the space acme/bare has no id (wsm id --new acme/bare): the event goes to the host scope"* ]]
  [ "$(attr host .spacepath)" = acme/bare ]
  [ "$(attr host .source)" = /anfs/host ]
}

@test "emit: the actor (ANFS_ACTOR, Claude Code, AI_AGENT, shell:\$USER) and ANFS_AS" {
  cd "$T/out"
  emit a.b 1
  [ "$(attr host .actor)" = shell:tester ]
  emit CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=2e9431a0-1282-4568 a.b 2
  [ "$(attr host .actor)" = claude:2e9431a0 ]
  emit CLAUDECODE=1 a.b 3
  [ "$(attr host .actor)" = claude ]
  emit AI_AGENT=opencode_1-2_agent a.b 4
  [ "$(attr host .actor)" = opencode ]
  emit ANFS_ACTOR=bot:7 CLAUDECODE=1 a.b 5
  [ "$(attr host .actor)" = bot:7 ]
  emit ANFS_AS=acme/tech/maintainer a.b 6
  [ "$(attr host .actorspace)" = acmetech22 ]
  [ "$(attr host .actorrole)" = maintainer ]
  run emit ANFS_AS=nonsense a.b 7
  [[ "$output" == *"ANFS_AS=nonsense is not <space path>/<role>"* ]]
  [ "$(attr host 'has("actorrole")')" = false ]
}

@test "emit: ids are valid UUIDv7s whose time is the event's, and sorting them sorts by time" {
  cd "$T/out"
  for ms in 1792771200500 1792771200001 1792857600000 1792771199999; do emit ANFS_EVENTS_TEST_MS=$ms a.b "$ms"; done
  run yqj -r '.id + " " + .subject + " " + .time' "$EV/host/"*.jsonl
  [ "${#lines[@]}" -eq 4 ]
  for l in "${lines[@]}"; do
    set -- $l
    [[ "$1" =~ $UUID7 ]]
    # the first 48 bits are the milliseconds
    hex="${1//-/}"; [ "$((16#${hex:0:12}))" = "$2" ]
  done
  [ "$(printf '%s\n' "${lines[@]}" | sort | cut -d' ' -f2 | tr '\n' ' ')" = "1792771199999 1792771200001 1792771200500 1792857600000 " ]
  [[ "$(printf '%s\n' "${lines[@]}" | grep 1792771200500 | cut -d' ' -f3)" == 2026-10-23T16:00:00.500Z ]]
}

@test "emit: over 4 KB is refused with a warning, exit 0, nothing written; a bad type or pair too" {
  cd "$T/out"
  big=$(printf '%04000d' 0)
  run emit a.b x "data=$big"
  [ "$status" -eq 0 ]
  [[ "$output" == *"event a.b not recorded: "*" bytes, over 4096: keep data small"* ]]
  [ -z "$(all_lines)" ]
  run emit Bad x
  [ "$status" -eq 0 ] && [[ "$output" == *"'Bad' is not <noun>.<verb>"* ]]
  run emit a.b x novalue
  [ "$status" -eq 0 ] && [[ "$output" == *"'novalue' is not key=value"* ]]
  [ -z "$(all_lines)" ]
}

@test "emit: ANFS_EVENTS=off writes nothing; a state it cannot write warns and exits 0" {
  cd "$T/out"
  run emit ANFS_EVENTS=off a.b x
  [ "$status" -eq 0 ] && [ -z "$output" ] && [ ! -d "$EV" ]
  mkdir -p "$HOME/.local/state/anfs"
  chmod 500 "$HOME/.local/state/anfs"
  run emit a.b x
  chmod 700 "$HOME/.local/state/anfs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"event a.b not recorded: cannot make"* ]]
}

@test "emit: ANFS_EVENTS_SPOOL (a run's spool) gets the line, both scopes and --host; the log gets nothing" {
  SP="$T/run/events"
  cd "$SRC/spaces/tech"
  run emit ANFS_EVENTS_SPOOL="$SP" ANFS_ACTOR=claude:89abcdef report.closed r-1 to=file
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run emit ANFS_EVENTS_SPOOL="$SP/" --host source.updated core
  [ "$status" -eq 0 ] && [ -z "$output" ]
  cd "$T/out"
  run emit ANFS_EVENTS_SPOOL="$SP" a.b x
  [ "$status" -eq 0 ]
  [ ! -d "$EV" ]
  [ "$(cat "$SP"/acmetech22/*.jsonl | wc -l | tr -d ' ')" = 1 ]
  [ "$(cat "$SP"/host/*.jsonl | wc -l | tr -d ' ')" = 2 ]
  f=$(ls "$SP"/acmetech22/*.jsonl)
  [ "${f##*/}" = "$(yq -p json -oy -r .time "$f" | cut -c1-7).jsonl" ]
  [ "$(yq -p json -oy -r '.actor + " " + .source + " " + .type' "$f")" = "claude:89abcdef /anfs/spaces/acmetech22 io.anfs.report.closed" ]
  # off still wins
  run emit ANFS_EVENTS=off ANFS_EVENTS_SPOOL="$SP" a.b y
  [ "$(cat "$SP"/host/*.jsonl | wc -l | tr -d ' ')" = 2 ]
}

@test "emit: in a run's spool the line keeps 512 bytes for anfsd's stamp: 3700 bytes refused there, accepted in the log" {
  cd "$T/out"
  big=$(printf '%03500d' 0)
  run emit ANFS_EVENTS_SPOOL="$T/sp" a.b x "data=$big"
  [ "$status" -eq 0 ]
  [[ "$output" == *"event a.b not recorded: "*" bytes, over 3584: keep data small"* ]]
  [ ! -e "$T/sp/host" ] || [ -z "$(cat "$T"/sp/host/*.jsonl 2>/dev/null)" ]
  run emit a.b x "data=$big"
  [ "$status" -eq 0 ] && [ -z "$output" ]
  n=$(wc -c < "$(ls "$EV"/host/*.jsonl)" | tr -d ' ')
  (( n > 3584 && n <= 4096 ))
}

@test "emit: 20 at once, each near 4 KB, give 20 whole lines" {
  cd "$T/out"
  big=$(printf '%03800d' 0)
  for i in $(seq 20); do emit a.b "s$i" "data=$big" & done
  wait
  [ "$(cat "$EV/host/"*.jsonl | wc -l | tr -d ' ')" = 20 ]
  [ "$(yqj -r .subject "$EV/host/"*.jsonl | sort -u | wc -l | tr -d ' ')" = 20 ]
  while IFS= read -r l; do printf '%s\n' "$l" | yq -p json -e '.data.data | length == 3800' >/dev/null; done < <(cat "$EV/host/"*.jsonl)
}

# --- events ls ------------------------------------------------------------------------------

# Events across scopes and months: tech (Oct and Nov), the root, the host
some_events() {
  cd "$SRC/spaces/tech"
  emit ANFS_EVENTS_TEST_MS=1793000000000 report.closed r-1 commit=abc   # 2026-10-26
  emit ANFS_EVENTS_TEST_MS=1792900000000 report.filed r-1               # 2026-10-24
  emit ANFS_EVENTS_TEST_MS=1793600000000 ANFS_ACTOR=claude:1 report.filed r-2   # 2026-11-02
  cd "$HOME/spaces/acme"
  emit ANFS_EVENTS_TEST_MS=1792950000000 space.made acme
  cd "$T/out"
  emit ANFS_EVENTS_TEST_MS=1793100000000 ANFS_AS=acme/tech/maintainer other.thing h
}

@test "anfs events ls: every scope, the host's included, oldest first across months and scopes" {
  some_events
  run --separate-stderr ev ls
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    $'2026-10-25T03:46:40Z report.filed\tr-1\tacme/tech\tshell:tester' \
    $'2026-10-25T17:40:00Z space.made\tacme\tacme\tshell:tester' \
    $'2026-10-26T07:33:20Z report.closed\tr-1\tacme/tech\tshell:tester' \
    $'2026-10-27T11:20:00Z other.thing\th\thost\tshell:tester as maintainer' \
    $'2026-11-02T06:13:20Z report.filed\tr-2\tacme/tech\tclaude:1')" ]
  run ev ls --all
  [ "${#lines[@]}" -eq 5 ]
  run ev ls --json
  [ "${#lines[@]}" -eq 5 ]
  printf '%s\n' "${lines[@]}" | yq -p json -e '.specversion == "1.0"' >/dev/null
  run ev ANFS_TABLE=aligned ls
  [[ "${lines[0]}" == "EVENT"*"SUBJECT"*"SPACE"*"BY" ]]
}

@test "anfs events ls: --type (short or full glob), --subject, --by, --since, --after" {
  some_events
  run ev ls --type 'report.*'
  [ "${#lines[@]}" -eq 3 ]
  run ev ls --type 'io.anfs.report.filed'
  [ "${#lines[@]}" -eq 2 ]
  run ev ls --subject r-1
  [ "${#lines[@]}" -eq 2 ]
  run ev ls --by 'claude:*'
  [ "${#lines[@]}" -eq 1 ] && [[ "$output" == *r-2* ]]
  run ev ls --since 2026-10-26
  [ "${#lines[@]}" -eq 3 ]
  run ev ls --since 2026-10-26T07:33:21Z
  [ "${#lines[@]}" -eq 2 ]
  # a duration: these are all older than a day before now (the test's dates are in the past)
  emit a.b now
  run ev ls --since 1h
  [ "${#lines[@]}" -eq 1 ] && [[ "$output" == *$'\tnow\t'* ]]
  id=$(yqj -r 'select(.subject == "h") | .id' "$EV/host/"*.jsonl)
  run ev ls --after "$id"
  [ "${#lines[@]}" -eq 2 ] && [[ "${lines[0]}" == *r-2* ]]
  run ev ls --after nope
  [ "$status" -eq 64 ]
  run ev ls --since yesterday
  [ "$status" -eq 64 ]
  run ev ls --once
  [ "$status" -eq 64 ] && [[ "$output" == *"--once goes with -f"* ]]
}

@test "anfs events ls SPEC: wsm resolves it (an id, a prefix), never the host scope; specs and --all are 64" {
  some_events
  run ev ls acme/tech
  [ "$status" -eq 0 ] && [ "${#lines[@]}" -eq 3 ]
  run ev ls acme/
  [ "${#lines[@]}" -eq 4 ] && [[ "$output" != *host* ]]
  run ev ls acme
  [ "${#lines[@]}" -eq 1 ] && [[ "$output" == *space.made* ]]
  run --separate-stderr ev ls acme/bare
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"acme/bare has no id, so no events (wsm id --new acme/bare)"* ]]
  run ev ls acme/zzz
  [ "$status" -eq 1 ]
  run ev ls acme --all
  [ "$status" -eq 64 ]
}

@test "completion: --type offers the toolkit's types and their globs; a spec comes from wsm" {
  run clean anfs __complete events ls --type ""
  [[ "$output" == *report.filed* && "$output" == *report.closed* && "$output" == *"report.*"* ]]
  [[ "$output" == *container.started* && "$output" == *"container.*"* && "$output" == *"pod.*"* && "$output" == *podman.connected* ]]
  run clean anfs __complete events ls ""
  [[ "$output" == *acme/tech* && "$output" == *"acme/"* ]]
}

# --- follow ---------------------------------------------------------------------------------

# Run `anfs events ls <args>` in the background; its pid in BG, its output in $T/bg
bg() {
  ( exec env -i HOME="$HOME" PATH="$HOME/.local/bin:$SYSPATH" USER=tester TMPDIR="$T" ANFS_LOG=off \
      "$HOME/.local/bin/anfs" events ls "$@" ) > "$T/bg" 2>&1 3>&- &
  BG=$!
}
# Wait up to <n> seconds for BG to exit; its status in BG_RC (124 when it is still running, then killed)
bg_wait() {
  local i
  for (( i = 0; i < $1 * 10; i++ )); do kill -0 "$BG" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$BG" 2>/dev/null; then kill "$BG"; wait "$BG" 2>/dev/null || true; BG_RC=124; return; fi
  BG_RC=0; wait "$BG" || BG_RC=$?
}

@test "follow --once: exits 0 when another process appends a match, in a few seconds" {
  cd "$T/out"
  emit a.b old
  bg -f --once --subject r-7
  sleep 1.5
  kill -0 "$BG"                      # still waiting: nothing matched yet
  emit a.b r-6                      # not it
  sleep 1.2
  kill -0 "$BG"
  local t0=$SECONDS
  cd "$SRC/spaces/tech"; emit report.closed r-7 commit=abc
  bg_wait 5
  [ "$BG_RC" -eq 0 ]
  (( SECONDS - t0 <= 4 ))
  [ "$(cat "$T/bg")" = "$(grep -o '[0-9T:-]*Z report.closed' "$T/bg")"$'\tr-7\tacme/tech\tshell:tester' ]
}

@test "follow --once: a match already in the log ends it at once" {
  cd "$T/out"
  emit report.closed r-8
  local t0=$SECONDS
  run ev ls -f --once --type report.closed --subject r-8
  [ "$status" -eq 0 ] && [[ "$output" == *r-8* ]]
  (( SECONDS - t0 <= 2 ))
}

@test "follow: a new month's file and a scope that did not exist yet are picked up; it does not spin" {
  cd "$T/out"
  emit ANFS_EVENTS_TEST_MS=1792771200000 a.b october
  bg -f --json
  sleep 1.5
  # no busy loop: well under a tenth of a CPU over the wait
  cpu=$(ps -o time= -p "$BG" | tr -d ' ')
  emit ANFS_EVENTS_TEST_MS=1793836800000 a.b november          # host, 2026-11
  cd "$SRC/spaces/tech"; emit a.b tech-first                   # a scope with no directory before
  for _ in $(seq 40); do [[ "$(wc -l < "$T/bg")" -ge 3 ]] && break; sleep 0.1; done
  kill "$BG"; wait "$BG" 2>/dev/null || true
  run yqj -r .subject "$T/bg"
  [ "${lines[0]}" = october ]
  [[ "$output" == *november* && "$output" == *tech-first* ]]
  [ "${#lines[@]}" -eq 3 ]
  [[ "$cpu" =~ ^0:00\.[0-2] ]]
}

# anfs_events_follow with a predicate (anfs report wait's use): <subject to stop on> <seconds>
follow_from_now() {
  ( exec env -i HOME="$HOME" PATH="$SYSPATH" TMPDIR="$T" ANFS_LOG=off bash -c '
      source "$1/paths.sh"; source "$1/log.sh"; source "$1/events.sh"
      ANFS_EVENTS_DIRS=("$ANFS_EVENTS_HOME/host" "$ANFS_EVENTS_HOME/acmetech22")
      stop_on() { _anfs_ev_parse "$1" && echo "saw $EV_SUBJECT" && [[ "$EV_SUBJECT" == "$2" ]]; }
      pred() { stop_on "$1" "$STOP"; }
      anfs_events_follow_init
      echo ready
      STOP="$2" anfs_events_follow pred $(( EPOCHSECONDS + $3 )) && echo stopped || echo "deadline"
    ' _ "$PKGS/anfs/home/.local/lib/anfs" "$@" ) > "$T/follow" 2>&1 3>&- &
  BG=$!
  for _ in $(seq 30); do grep -q ready "$T/follow" 2>/dev/null && break; sleep 0.1; done
}

@test "follow from now: what is there is skipped; a predicate stops it; a deadline ends it with 1, idle" {
  cd "$T/out"
  emit a.b before
  follow_from_now done 30
  emit a.b one
  cd "$SRC/spaces/tech"; emit a.b done
  bg_wait 5
  [ "$BG_RC" -eq 0 ]
  [ "$(cat "$T/follow")" = "ready
saw one
saw done
stopped" ]
  cd "$T/out"
  follow_from_now never 3
  sleep 2
  cpu=$(ps -o time= -p "$BG" | tr -d ' ')
  bg_wait 5
  [ "$(cat "$T/follow")" = "ready
deadline" ]
  [[ "$cpu" =~ ^0:00\.[0-1] ]]
}
