#!/usr/bin/env bats
# anfs agents (core/anfsd's anfs-agents): ls, show and logs from fixture run directories as anfsd
# leaves them (run.json, event.json, out.log); stop on a process group the test started (the
# cancel marker written, every process of the group gone); rules and match through a stub anfsd.
# A temp HOME; PATH is the stubs, yq, bash and the system's, so no harness is ever found or run.
# Run: bats packages/anfsd/tests </dev/null

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_STATE_HOME ANFSD_BIN ANFS_ACTOR
  export ANFS_LOG=off ANFS_EVENTS=off ANFS_TABLE=tsv STUB="$T/stub"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/lib" "$HOME/.config/anfs" "$HOME/.config/anfsd" "$STUB" "$T/bin" "$T/sys"
  ln -s "$REPO/packages/anfs/home/.local/lib/anfs" "$HOME/.local/lib/anfs"
  ln -s "$REPO/packages/anfs/home/.local/bin/anfs" "$HOME/.local/bin/anfs"
  ln -s "$REPO/packages/anfsd/home/.local/bin/anfs-agents" "$HOME/.local/bin/anfs-agents"
  ln -s "$REPO/packages/anfsd/home/.config/anfsd/anfsd.env" "$HOME/.config/anfsd/anfsd.env"
  : > "$HOME/.config/anfs/system.list"
  printf '# Your anfs sources\n' > "$HOME/.config/anfs/user.list"
  # the anfsd anfs bus would run (ANFSD_BIN): rules from $STUB/rules.json, match says its args,
  # render marks each line
  cat > "$T/anfsd" <<'STUB'
#!/bin/sh
case "$1" in
  rules) cat "$STUB/rules.json" ;;
  match) shift; echo "match: $*" ;;
  render) sed "s/^/[$2] /" ;;
  version) echo dev ;;
esac
STUB
  chmod +x "$T/anfsd"
  printf 'ANFSD_BIN=%s\n' "$T/anfsd" > "$HOME/.config/anfsd/anfsd.local.env"
  ln -s "$(command -v yq)" "$T/sys/yq"
  ln -s "$(command -v bash)" "$T/sys/bash"
  ln -s "$(command -v perl)" "$T/sys/perl"
  export PATH="$T/bin:$T/sys:/usr/bin:/bin:/usr/sbin:/sbin"
  RUNS="$HOME/.local/state/anfsd/runs"
  NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  OLD=$(date -u -v-3d +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%S.000Z)
}

teardown() {
  [[ -z "${GROUP:-}" ]] || kill -KILL -- "-$GROUP" 2>/dev/null || true
}

ag() { run --separate-stderr "$HOME/.local/bin/anfs-agents" "$@" </dev/null; }

# A run directory: <id> <state> [reason] [submitted] [ended] [pid] [pgid] [ps start]
fixture() {
  local id="$1" state="$2" reason="${3:-}" sub="${4:-$NOW}" ended="${5:-}" pid="${6:-0}" pgid="${7:-0}" pss="${8:-}"
  mkdir -p "$RUNS/$id"
  cat > "$RUNS/$id/run.json" <<JSON
{"id":"$id","rule":"fix-core-report","space":"anfs-dev","space_id":"abcde23456","space_dir":"/s",
 "event":"01a169de-e9bb-7000-8000-000000000001","event_type":"report.filed","subject":"r-1","actor":"shell:t",
 "role":"maintainer","address":"anfs-dev/maintainer","harness":"claude","model":"opus",
 "job":"fix-r-1","repos":["core"],"cwd":"/w/fix-r-1","concurrency":1,"timeout":"2h0m0s","retries":0,"attempt":1,
 "argv":["claude","-p","--","Fix it.\n\n---\nfooter $(printf 'x%.0s' $(seq 200))"],
 "pid":$pid,"pgid":$pgid,"ps_start":"$pss","state":"$state","reason":"$reason","submitted":"$sub","ended":"$ended",
 "summary":"$( [[ "$state" == completed ]] && echo "Fixed it." )"${EXTRA:+,$EXTRA}}
JSON
  printf '{"specversion":"1.0","id":"01a169de-e9bb-7000-8000-000000000001","type":"io.anfs.report.filed"}\n' > "$RUNS/$id/event.json"
}

ID1=01a16a00-0000-7000-8000-00000000aaa1
ID2=01a16a00-0000-7000-8000-00000000bbb2
ID3=01a16a00-0000-7000-8000-00000000ccc3
ID4=01a16a00-0000-7000-8000-00000000ddd4

@test "ls: the runs not ended and the last day's; --all every one; a space spec; --json" {
  fixture "$ID1" working
  fixture "$ID2" failed timeout "$NOW" "$NOW"
  fixture "$ID3" completed "" "$OLD" "$OLD"
  ag ls
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "0000aaa1	working	fix-core-report	maintainer	anfs-dev	claude	fix-r-1	0s" ] ||
    [[ "${lines[0]}" == "0000aaa1	working	fix-core-report	maintainer	anfs-dev	claude	fix-r-1	"[0-9]s ]]
  [[ "${lines[1]}" == "0000bbb2	failed (timeout)	"* ]]
  ag ls --all
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[2]}" == "0000ccc3	completed	"*"	3d" ]]
  ag ls lgat/
  [ -z "$output" ]
  ag ls anfs-dev --all
  [ "${#lines[@]}" -eq 3 ]
  ANFS_TABLE= ag --json ls
  run yq -p json -o json -I0 '.[1] | [.run, .status, .id, .state, .reason]' <<< "$output"
  [ "$output" = "[\"0000bbb2\",\"failed (timeout)\",\"$ID2\",\"failed\",\"timeout\"]" ]
  # no runs at all
  rm -rf "$RUNS"
  ag ls
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "show: by the id or its last 8; the record, the command (the prompt cut), the event" {
  fixture "$ID3" completed "" "$NOW" "$NOW"
  ag show 0000ccc3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "run:       $ID3" ]
  [ "${lines[1]}" = "status:    completed" ]
  [ "${lines[2]}" = "rule:      fix-core-report in anfs-dev (abcde23456)" ]
  [ "${lines[3]}" = "as:        anfs-dev/maintainer (claude, opus)" ]
  [[ "$output" == *"job:       fix-r-1 [core]"* ]]
  [[ "$output" == *$'summary:\nFixed it.'* ]]
  [[ "$output" == *$'command:\n  claude\n  -p\n  --\n  Fix it.  --- footer xxx'*'...'* ]]
  [[ "$output" == *'"type":"io.anfs.report.filed"'* ]]
  ag show "$ID3"
  [ "$status" -eq 0 ]
  ag --json show 0000ccc3
  run yq -p json -r '.run.state + " " + .event.type' <<< "$output"
  [ "$output" = "completed io.anfs.report.filed" ]
  ag show 0000dddd
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no run 0000dddd (anfs agents ls --all)"* ]]
  fixture 01a16a00-0000-7000-8000-10000000ccc3 working
  ag show 0000ccc3
  [ "$status" -eq 2 ]
  ag show 'x;rm'
  [ "$status" -eq 64 ]
}

@test "logs: out.log through anfsd render (the harness named); --json as written; none yet" {
  fixture "$ID1" working
  ag logs 0000aaa1
  [ "$status" -eq 0 ]
  [[ "$output" == "no output yet (working)" ]]
  printf '{"type":"result"}\nplain\n' > "$RUNS/$ID1/out.log"
  ag logs 0000aaa1
  [ "${lines[0]}" = '[claude] {"type":"result"}' ]
  [ "${lines[1]}" = "[claude] plain" ]
  ag --json logs 0000aaa1
  [ "${lines[0]}" = '{"type":"result"}' ]
}

# a process group of two (a shell and its child), as anfsd's setsid'd runs are
group() {
  perl -e 'setpgrp(0, 0); exec @ARGV' sh -c "$1"' sleep 300 & echo $! > "'"$T"'/child"; wait' </dev/null >/dev/null 2>&1 &
  GROUP=$!
  local i
  for i in $(seq 50); do [[ -s "$T/child" ]] && break; sleep 0.1; done
  CHILD=$(cat "$T/child")
  PSS=$(ps -o lstart= -p "$GROUP" | tr -s ' ' | sed 's/^ //;s/ $//')
}

alive() { kill -0 "$1" 2>/dev/null; }

@test "stop: the cancel marker, SIGTERM to the group; every process of it gone" {
  group ""
  fixture "$ID1" working "" "$NOW" "" "$GROUP" "$GROUP" "$PSS"
  ag stop 0000aaa1
  [ "$status" -eq 77 ]
  alive "$GROUP"
  [ ! -e "$RUNS/$ID1/cancel" ]
  ANFS_ACTOR=shell:person ag stop 0000aaa1 -y
  [ "$status" -eq 0 ]
  [ "$output" = "0000aaa1: stopped" ]
  [ "$(cat "$RUNS/$ID1/cancel")" = "shell:person" ]
  wait "$GROUP" 2>/dev/null || true
  ! alive "$GROUP"
  ! alive "$CHILD"
  GROUP=""
}

@test "stop: SIGKILL when the group ignores SIGTERM; a queued run is canceled before it starts; ended ones are left" {
  group "trap '' TERM;"
  fixture "$ID1" working "" "$NOW" "" "$GROUP" "$GROUP" "$PSS"
  fixture "$ID2" submitted
  fixture "$ID3" completed "" "$NOW" "$NOW"
  ANFS_AGENTS_GRACE=1 ag stop --all -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"0000aaa1: killed (SIGKILL after 1s)"* ]]
  [[ "$output" == *"0000bbb2: canceled before it starts"* ]]
  [[ "$output" != *0000ccc3* ]]
  [ -f "$RUNS/$ID2/cancel" ] && [ ! -e "$RUNS/$ID3/cancel" ]
  wait "$GROUP" 2>/dev/null || true
  sleep 0.2
  ! alive "$GROUP"
  ! alive "$CHILD"
  GROUP=""
  # a pid another process took since: not signaled
  sleep 300 </dev/null >/dev/null 2>&1 & local other=$!
  fixture "$ID4" working "" "$NOW" "" "$other" "$other" "Thu Jan  1 00:00:00 1970"
  ag stop 0000ddd4 -y
  [[ "$output" == "0000ddd4: its process is gone (pid $other is another one now)" ]]
  alive "$other"
  kill "$other"
  ag stop
  [ "$status" -eq 64 ]
}

@test "rules: anfsd rules --json as RULE STATUS SPACE ON AS HARNESS; a spec; --json keeps the reason" {
  cat > "$STUB/rules.json" <<'JSON'
[{"rule":"fix-core-report","status":"disabled","space":"anfs-dev","space_id":"abcde23456","on":"report.filed package=core/* to=file","as":"maintainer","harness":"claude","job":"fix-{{subject}}","enabled":false,"reason":"","warnings":[],"file":"/s/space.yml"},
 {"rule":"bad","status":"invalid","space":"lgat/web","space_id":"zzzzz23456","on":"","as":"","harness":"","job":"","enabled":true,"reason":"as: is required","warnings":[],"file":"/l/space.yml"}]
JSON
  ag rules
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "fix-core-report	disabled	anfs-dev	report.filed package=core/* to=file	maintainer	claude" ]
  [ "${lines[1]}" = "bad	invalid	lgat/web	-	-	-" ]
  ag rules lgat/
  [ "${#lines[@]}" -eq 1 ]
  ANFS_TABLE= ag --json rules anfs-dev
  run yq -p json -o json -I0 '.' <<< "$output"
  [ "$output" = '[{"rule":"fix-core-report","status":"disabled","space":"anfs-dev","on":"report.filed package=core/* to=file","as":"maintainer","harness":"claude","reason":null,"job":"fix-{{subject}}","space_id":"abcde23456"}]' ]
  ANFS_TABLE= ag --json rules lgat/web
  [[ "$output" == *'"reason":"as: is required"'* ]]
}

@test "match: anfsd match with the line as given (--json passed on); no anfsd is 69" {
  ag match --type report.filed --space anfs-dev --data to=file
  [ "$status" -eq 0 ]
  [ "$output" = "match: --type report.filed --space anfs-dev --data to=file" ]
  ag --json match --event -
  [ "$output" = "match: --json --event -" ]
  printf 'ANFSD_BIN=%s\n' "$T/none" > "$HOME/.config/anfsd/anfsd.local.env"
  ag match --type x.y
  [ "$status" -eq 69 ]
}

@test "anfs agents is anfs-agents through anfs's package seam" {
  fixture "$ID1" working
  run --separate-stderr "$HOME/.local/bin/anfs" agents ls </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == "0000aaa1	working	"* ]]
}

@test "ls: a held run is held:rate or held:queue; --unhandled lists the events rejected for queue or rate and never run" {
  EXTRA='"held":"rate","held_since":"'"$NOW"'"' fixture "$ID1" submitted
  EXTRA='"held":"queue"' fixture "$ID2" submitted
  # event e1: rejected for its queue only (unhandled); e2: rejected for the rate, then redispatched (handled);
  # e3: rejected stale (handled: final)
  EXTRA='"event":"01a169de-e9bb-7000-8000-0000000000e1","subject":"r-e1"' fixture "$ID3" rejected queue "$NOW" "$NOW"
  EXTRA='"event":"01a169de-e9bb-7000-8000-0000000000e2","subject":"r-e2"' fixture "$ID4" rejected rate "$NOW" "$NOW"
  EXTRA='"event":"01a169de-e9bb-7000-8000-0000000000e2","subject":"r-e2","redispatch_by":"shell:t"' fixture 01a16a00-0000-7000-8000-00000000eee5 completed "" "$NOW" "$NOW"
  EXTRA='"event":"01a169de-e9bb-7000-8000-0000000000e3","subject":"r-e3"' fixture 01a16a00-0000-7000-8000-00000000fff6 rejected stale "$NOW" "$NOW"
  ag ls
  [[ "${lines[0]}" == "0000aaa1	held:rate	fix-core-report	"* ]]
  [[ "${lines[1]}" == "0000bbb2	held:queue	"* ]]
  [[ "${lines[2]}" == "0000ccc3	rejected (queue)	"* ]]
  ag ls --unhandled
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "01a169de-e9bb-7000-8000-0000000000e1	r-e1	anfs-dev/fix-core-report	queue	"[0-9]s ]]
  ag ls -u lgat/
  [ -z "$output" ]
  ANFS_TABLE= ag --json ls --unhandled
  [ "$(yq -p json -r '.[0].event + " " + .[0].reason' <<< "$output")" = "01a169de-e9bb-7000-8000-0000000000e1 queue" ]
}

@test "show: held since, redispatched by, its events ingested and refused, and the bytes of its spool not ingested" {
  EXTRA='"held":"queue","held_since":"'"$NOW"'","redispatch_by":"shell:person","events_ingested":3,"events_refused":1' fixture "$ID1" submitted
  mkdir -p "$RUNS/$ID1/events/abcde23456" "$RUNS/$ID1/events/host"
  printf '%s\n' '{"a":1}' '{"b":2}' > "$RUNS/$ID1/events/abcde23456/2026-10.jsonl"
  printf '%s\n' '{"c":3}' > "$RUNS/$ID1/events/host/2026-10.jsonl"
  printf '{"abcde23456/2026-10.jsonl":8,"host/2026-10.jsonl":8,"#ingested":3}\n' > "$RUNS/$ID1/cursors.json"
  ag show 0000aaa1
  [ "$status" -eq 0 ]
  [[ "$output" == *"held:      queue since $NOW"* ]]
  [[ "$output" == *"redispatch: by shell:person"* ]]
  [[ "$output" == *"its events: 3 ingested, 1 refused, 8 bytes not ingested"* ]]
  printf '{"abcde23456/2026-10.jsonl":16,"host/2026-10.jsonl":8}\n' > "$RUNS/$ID1/cursors.json"
  ag show 0000aaa1
  [[ "$output" == *"its events: 3 ingested, 1 refused"$'\n'* ]]
}

@test "rules: a space whose dispatcher is none shows off" {
  printf '%s\n' '[{"rule":"r","status":"off","space":"lgat","on":"report.filed","as":"m","harness":"claude","reason":"dispatcher: none","job":"","space_id":"lgatlgat22","overflow":"delay","hold":20}]' > "$STUB/rules.json"
  ag rules
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "r	off	lgat	report.filed	m	claude" ]
}

# a log of two months with the event in the second, in one of two scopes
redispatch_log() {
  EV="$HOME/.local/state/anfs/events"
  mkdir -p "$EV/abcde23456" "$EV/host"
  # 01a0a402-8258 is 2026-09-15; 01a169de-e9bb is 2026-10-23
  printf '%s\n' '{"specversion":"1.0","id":"01a0a402-8258-7000-8000-000000000001","source":"/anfs/spaces/abcde23456","type":"io.anfs.report.filed","subject":"r-old","time":"2026-09-01T00:00:00.000Z","actor":"shell:t","anfsv":1,"data":{}}' > "$EV/abcde23456/2026-09.jsonl"
  printf '%s\n' '{"specversion":"1.0","id":"01a169de-e9bb-7000-8000-000000000002","source":"/anfs/host","type":"io.anfs.source.updated","subject":"core","time":"2026-10-23T17:46:18.939Z","actor":"shell:t","anfsv":1,"data":{}}' > "$EV/host/2026-10.jsonl"
  printf '%s\n' '{"specversion":"1.0","id":"01a169de-e9bb-7000-8000-000000000003","source":"/anfs/spaces/abcde23456","type":"io.anfs.report.filed","subject":"r-9","time":"2026-10-23T17:46:18.939Z","actor":"shell:t","anfsv":1,"data":{"to":"file"}}' > "$EV/abcde23456/2026-10.jsonl"
}

@test "redispatch: the line found by its id, what the rules would do, a request for anfsd and SIGHUP to its pid" {
  redispatch_log
  # anfsd: a process that notes each SIGHUP
  bash -c 'trap "echo hup >> \"$1\"" HUP; while :; do sleep 0.1; done' _ "$T/hups" &
  local pid=$!
  mkdir -p "$HOME/.local/state/anfsd"
  echo "$pid" > "$HOME/.local/state/anfsd/anfsd.pid"
  ANFS_ACTOR=shell:person ag redispatch 01a169de-e9bb-7000-8000-000000000003 fix-core-report -y --again
  [ "$status" -eq 0 ]
  [[ "$output" == *"match: --event -"* ]]
  [[ "$stderr$output" == *"asked anfsd (pid $pid)"* ]]
  local req
  req=$(ls "$HOME/.local/state/anfsd/redispatch"/*.json)
  [ "$(yq -p json -r '.rule + " " + .by + " " + (.again | tostring)' "$req")" = "fix-core-report shell:person true" ]
  [ "$(yq -p json -r '.event' "$req")" = "$(cat "$EV/abcde23456/2026-10.jsonl")" ]
  [[ "$(basename "$req")" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-7 ]]
  for i in $(seq 20); do [[ -s "$T/hups" ]] && break; sleep 0.1; done
  kill "$pid" 2>/dev/null || true
  [ "$(cat "$T/hups")" = hup ]
}

@test "redispatch: asks without -y; no anfsd waits for its start; an id not in the log, a bad id, a bad rule" {
  redispatch_log
  ag redispatch 01a0a402-8258-7000-8000-000000000001
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"pass -y to confirm without a terminal"* ]]
  [ ! -d "$HOME/.local/state/anfsd/redispatch" ] || [ -z "$(ls "$HOME/.local/state/anfsd/redispatch")" ]
  ag redispatch 01a0a402-8258-7000-8000-000000000001 -y
  [ "$status" -eq 0 ]
  [[ "$stderr$output" == *"anfsd is not running: the request waits for anfsd's start"* ]]
  [ "$(yq -p json -r '.event' "$HOME/.local/state/anfsd/redispatch"/*.json)" = "$(cat "$EV/abcde23456/2026-09.jsonl")" ]
  ag redispatch 01a169de-e9bb-7000-8000-00000000dead -y
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"no event 01a169de-e9bb-7000-8000-00000000dead in the log"* ]]
  ag redispatch not-an-id -y
  [ "$status" -eq 64 ]
  ag redispatch 01a169de-e9bb-7000-8000-000000000003 'Bad;rule' -y
  [ "$status" -eq 64 ]
}
