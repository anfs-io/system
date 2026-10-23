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
 "summary":"$( [[ "$state" == completed ]] && echo "Fixed it." )"}
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
