#!/usr/bin/env bats
# anfs bus (core/anfsd's anfs-bus): status from NATS's monitoring port (a stub curl serving fixture
# answers), the services (stub launchctl and systemctl) and anfsd's files (a fixture spool and
# cursors.json); start, stop, restart, reload and logs calling the right stub commands on both
# platforms; nats -- with the admin password in the environment only. A temp HOME, never a real
# service, never the network.
# Run: bats packages/anfsd/tests </dev/null

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_STATE_HOME ANFSD_BIN \
    ANFS_NATS_PORT ANFS_NATS_HTTP_PORT NATS_URL NATS_USER NATS_PASSWORD
  export ANFS_LOG=off ANFS_EVENTS=off ANFS_TABLE=tsv STUB="$T/stub"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/lib" "$HOME/.config/anfs" "$HOME/.config/nats" "$HOME/.config/anfsd" \
    "$STUB/http" "$STUB/launchd" "$T/bin"
  ln -s "$REPO/packages/anfs/home/.local/lib/anfs" "$HOME/.local/lib/anfs"
  ln -s "$REPO/packages/anfs/home/.local/bin/anfs" "$HOME/.local/bin/anfs"
  ln -s "$REPO/packages/anfsd/home/.local/bin/anfs-bus" "$HOME/.local/bin/anfs-bus"
  ln -s "$REPO/packages/nats/home/.config/nats/nats.env" "$HOME/.config/nats/nats.env"
  ln -s "$REPO/packages/anfsd/home/.config/anfsd/anfsd.env" "$HOME/.config/anfsd/anfsd.env"
  : > "$HOME/.config/anfs/system.list"
  printf '# Your anfs sources\n' > "$HOME/.config/anfs/user.list"
  # curl -fsS -m 2 http://127.0.0.1:<port>/<path>: $STUB/http/<path before ?>, else exit 7
  cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${@: -1}"
echo "$url" >> "$STUB/curl.log"
p="${url#http://127.0.0.1:*/}" p="${p%%\?*}"
[[ -f "$STUB/http/$p" ]] || exit 7
cat "$STUB/http/$p"
STUB
  # launchctl: print answers from $STUB/launchd/<label> (missing: not loaded, 113)
  cat > "$T/bin/launchctl" <<'STUB'
#!/usr/bin/env bash
echo "launchctl $*" >> "$STUB/svc.log"
if [[ "$1" == print ]]; then f="$STUB/launchd/${2##*/}"; [[ -f "$f" ]] || exit 113; cat "$f"; fi
exit 0
STUB
  cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB/svc.log"
if [[ "$2" == show ]]; then f="$STUB/systemd/${@: -1}"; [[ -f "$f" ]] && cat "$f" || printf 'ActiveState=inactive\nMainPID=0\n'; fi
exit 0
STUB
  printf '#!/bin/sh\necho "journalctl $*"\n' > "$T/bin/journalctl"
  printf '#!/bin/sh\ncat "$STUB/linger" 2>/dev/null || echo no\n' > "$T/bin/loginctl"
  chmod +x "$T/bin/"*
  # the stubs, yq and bash, and the system's: never a harness of the person's (claude, pi, agy...)
  mkdir -p "$T/sys"
  ln -s "$(command -v yq)" "$T/sys/yq"
  ln -s "$(command -v bash)" "$T/sys/bash"
  export PATH="$T/bin:$T/sys:/usr/bin:/bin:/usr/sbin:/sbin"
  NS="$HOME/.local/state/nats"
  AS="$HOME/.local/state/anfsd"
  EV="$HOME/.local/state/anfs/events"
}

bus() { run --separate-stderr "$HOME/.local/bin/anfs-bus" "$@" </dev/null; }

# NATS and anfsd installed: STATE, the users, the units (as their hooks leave them), a fake anfsd
installed() {
  local os="${1:-macos}"
  mkdir -p "$NS/users" "$AS" "$HOME/.local/share/anfsd/v0.1.0" "$HOME/Library/LaunchAgents" "$HOME/.config/systemd/user"
  for u in anfsd admin reader; do printf '%s\n' "pw-$u" > "$NS/users/$u"; done
  echo 47222 > "$NS/port"
  fake_anfsd "$HOME/.local/share/anfsd/v0.1.0/anfsd" v0.1.0
  chmod +x "$HOME/.local/share/anfsd/v0.1.0/anfsd"
  ln -s "$HOME/.local/share/anfsd/v0.1.0/anfsd" "$HOME/.local/bin/anfsd"
  if [[ "$os" == macos ]]; then
    touch "$HOME/Library/LaunchAgents/io.anfs.nats.plist" "$HOME/Library/LaunchAgents/io.anfs.anfsd.plist"
  else
    touch "$HOME/.config/systemd/user/anfs-nats.service" "$HOME/.config/systemd/user/anfsd.service"
  fi
}

# A fake anfsd: its version, and `rules --json` from $STUB/rules.json ([] when none)
fake_anfsd() {
  printf '#!/bin/sh\ncase "$1" in rules) cat "$STUB/rules.json" 2>/dev/null || echo "[]" ;; *) echo %s ;; esac\n' "$2" > "$1"
  chmod +x "$1"
}

# NATS answering, with the stream ANFS (and other streams given as name:subjects)
nats_up() {
  echo '{"status":"ok"}' > "$STUB/http/healthz"
  echo '{"version":"2.15.1","port":47222}' > "$STUB/http/varz"
  local extra="" s
  for s in "$@"; do extra+=",{\"name\":\"${s%%:*}\",\"config\":{\"subjects\":[\"${s#*:}\"]},\"state\":{\"messages\":1,\"bytes\":10}}"; done
  cat > "$STUB/http/jsz" <<JSON
{"streams":1,"account_details":[{"name":"\$G","stream_detail":[{"name":"ANFS","config":{"subjects":["anfs.>"]},
 "state":{"messages":42,"bytes":5120,"first_ts":"2026-10-01T10:00:00.123456Z","last_ts":"2026-10-23T17:00:00Z"}}$extra]}]}
JSON
}

# launchd has <label> running as <pid>
running() { printf 'gui/501/%s = {\n\tstate = running\n\tpid = %s\n}\n' "$1" "$2" > "$STUB/launchd/$1"; }

# A spool and cursors: host 3 lines (2 shipped), space 1 line (none)
spool() {
  mkdir -p "$EV/host" "$EV/abcde23456"
  printf 'a\nbb\nccc\n' > "$EV/host/2026-10.jsonl"
  printf 'dddd\n' > "$EV/abcde23456/2026-10.jsonl"
  printf '{"host/2026-10.jsonl":5}\n' > "$AS/cursors.json"
}

@test "status: all ok, exit 0" {
  installed
  nats_up
  running io.anfs.nats 111
  sleep 30 & local p=$!
  running io.anfs.anfsd "$p"
  echo "$p" > "$AS/anfsd.pid"
  ANFS_SERVICE_OS=macos bus status
  kill "$p"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[0]}" = "nats	ok	v2.15.1, 127.0.0.1:47222 (monitoring 47223); running 111" ]
  [ "${lines[1]}" = "jetstream	ok	stream ANFS: 42 messages, 5.0 KiB, first 2026-10-01T10:00:00Z, last 2026-10-23T17:00:00Z" ]
  [ "${lines[2]}" = "anfsd	ok	pid $p, v0.1.0 (release)" ]
  [ "${lines[3]}" = "shipper	ok	nothing to ship" ]
  [ "${lines[4]}" = "dispatch	ok	0 rules loaded, 0 disabled, 0 invalid; 0 working, 0 queued" ]
  [ "${#lines[@]}" -eq 5 ]
  grep -q '^http://127.0.0.1:47223/jsz?streams=true&config=true$' "$STUB/curl.log"
}

@test "status: dispatch (the rules, the runs) and a row per harness the rules use" {
  installed
  nats_up
  cat > "$STUB/rules.json" <<'JSON'
[{"rule":"a","status":"ok","space":"anfs-dev","harness":"claude"},
 {"rule":"b","status":"disabled","space":"anfs-dev","harness":"pi"},
 {"rule":"c","status":"partial","space":"anfs-dev","harness":"antigravity"},
 {"rule":"d","status":"invalid","space":"anfs-dev","harness":"opencode","reason":"x"}]
JSON
  local n=0
  for s in working submitted submitted completed; do
    n=$(( n + 1 ))
    mkdir -p "$AS/runs/r-$n"
    printf '{"state":"%s"}\n' "$s" > "$AS/runs/r-$n/run.json"
  done
  printf '#!/bin/sh\necho "2.1.296 (Claude Code)"\n' > "$T/bin/claude"
  printf '#!/bin/sh\nsleep 600\n' > "$T/bin/agy"
  chmod +x "$T/bin/claude" "$T/bin/agy"
  ANFS_SERVICE_OS=macos bus status
  [ "$status" -eq 1 ]
  [ "${lines[4]}" = "dispatch	fail	2 rules loaded, 1 disabled, 1 invalid (anfs agents rules); 1 working, 2 queued" ]
  [ "${lines[5]}" = "harness claude	ok	$T/bin/claude, 2.1.296 (Claude Code)" ]
  [ "${lines[6]}" = "harness pi	fail	pi is not on PATH (a rule uses it)" ]
  [ "${lines[7]}" = "harness antigravity	ok	$T/bin/agy, version not asked: agy --version hangs" ]
  [ "${#lines[@]}" -eq 8 ]
}

@test "status: NATS down and anfsd stopped: each says so, exit 1; nothing installed says how" {
  ANFS_SERVICE_OS=macos bus status
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "nats	not installed	ppm install core/nats" ]
  [ "${lines[1]}" = "jetstream	fail	NATS is not answering" ]
  [ "${lines[2]}" = "anfsd	not installed	ppm install core/anfsd" ]
  installed
  ANFS_SERVICE_OS=macos bus status
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "nats	stopped	anfs bus start nats" ]
  [ "${lines[2]}" = "anfsd	stopped	v0.1.0 (release); anfs bus start anfsd" ]
  # loaded, but nothing answers
  running io.anfs.nats 111
  ANFS_SERVICE_OS=macos bus status
  [[ "${lines[0]}" == "nats	fail	running 111, but nothing answers on 127.0.0.1:47223"* ]]
}

@test "status: the shipper's lag per scope from cursors.json and the spool" {
  installed
  nats_up
  spool
  ANFS_SERVICE_OS=macos bus status
  [ "$status" -eq 1 ]
  [ "${lines[3]}" = "shipper	lag	abcde23456: 1 lines, 5 B not shipped" ]
  [ "${lines[4]}" = "shipper	lag	host: 1 lines, 4 B not shipped" ]
  printf '{"host/2026-10.jsonl":9,"abcde23456/2026-10.jsonl":5}\n' > "$AS/cursors.json"
  ANFS_SERVICE_OS=macos bus status
  [ "${lines[3]}" = "shipper	ok	nothing to ship" ]
}

@test "status: another stream on anfs.> is a fail; no ANFS yet is a fail; --json is the rows" {
  installed
  nats_up 'OTHER:anfs.host.>'
  ANFS_SERVICE_OS=macos bus status
  [ "$status" -eq 1 ]
  [ "${lines[2]}" = "jetstream	fail	another stream holds anfs.>: OTHER (anfs.host.>) (anfsd cannot make ANFS)" ]
  echo '{"account_details":[]}' > "$STUB/http/jsz"
  ANFS_TABLE= ANFS_SERVICE_OS=macos bus status --json
  [ "$status" -eq 1 ]
  run yq -p json -o json -I0 '.[1]' <<< "$output"
  [ "$output" = '{"service":"jetstream","status":"fail","detail":"no stream ANFS yet (anfsd makes it when it starts)"}' ]
}

@test "status: ANFSD_BIN is from source; on Linux the units through systemctl, and linger" {
  installed linux
  nats_up
  mkdir -p "$STUB/systemd"
  printf 'ActiveState=active\nMainPID=222\n' > "$STUB/systemd/anfsd.service"
  printf 'ActiveState=active\nMainPID=111\n' > "$STUB/systemd/anfs-nats.service"
  fake_anfsd "$T/dev-anfsd" dev
  printf 'ANFSD_BIN=%s\n' "$T/dev-anfsd" > "$HOME/.config/anfsd/anfsd.local.env"
  echo '{}' > "$AS/cursors.json"
  ANFS_SERVICE_OS=linux bus status
  [ "$status" -eq 1 ]
  [ "${lines[2]}" = "anfsd	ok	222, dev (from source: $T/dev-anfsd)" ]
  [ "${lines[5]}" = "linger	off	loginctl enable-linger $USER: without it the bus stops when you log out" ]
  echo yes > "$STUB/linger"
  ANFS_SERVICE_OS=linux bus status
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "${lines[5]}" = "linger	ok	the bus runs without a login" ]
}

@test "start, stop, restart on macOS: launchctl, NATS first up and last down" {
  installed
  ANFS_SERVICE_OS=macos bus start
  [ "$status" -eq 0 ]
  [ "$output" = "nats: started
anfsd: started" ]
  grep -x "launchctl bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/io.anfs.nats.plist" "$STUB/svc.log"
  [ "$(grep bootstrap "$STUB/svc.log" | tail -1)" = "launchctl bootstrap gui/$(id -u) $HOME/Library/LaunchAgents/io.anfs.anfsd.plist" ]
  : > "$STUB/svc.log"
  ANFS_SERVICE_OS=macos bus stop
  [ "$output" = "anfsd: stopped
nats: stopped" ]
  [ "$(cat "$STUB/svc.log")" = "launchctl bootout gui/$(id -u)/io.anfs.anfsd
launchctl bootout gui/$(id -u)/io.anfs.nats" ]
  # already running: start leaves it
  running io.anfs.nats 111
  ANFS_SERVICE_OS=macos bus start nats
  [ "$output" = "nats: already running" ]
  ANFS_SERVICE_OS=macos bus start bogus
  [ "$status" -eq 64 ]
}

@test "restart nats renders server.conf from nats.local.env; restart anfsd writes ANFSD_BIN's path" {
  installed
  printf 'ANFS_NATS_PORT=47555\n' > "$HOME/.config/nats/nats.local.env"
  ANFS_SERVICE_OS=macos bus restart nats
  [ "$status" -eq 0 ]
  grep -qx 'listen: 127.0.0.1:47555' "$NS/server.conf"
  [ "$(cat "$NS/port")" = 47555 ]
  grep -q '<string>-c</string>' "$HOME/Library/LaunchAgents/io.anfs.nats.plist"
  fake_anfsd "$T/dev-anfsd" dev
  printf 'ANFSD_BIN=%s\n' "$T/dev-anfsd" > "$HOME/.config/anfsd/anfsd.local.env"
  ANFS_SERVICE_OS=macos bus restart anfsd
  [ "$status" -eq 0 ]
  tr -d ' \n' < "$HOME/Library/LaunchAgents/io.anfs.anfsd.plist" | grep -q "<array><string>$T/dev-anfsd</string><string>run</string></array>"
  printf 'ANFSD_BIN=%s\n' "$T/none" > "$HOME/.config/anfsd/anfsd.local.env"
  ANFS_SERVICE_OS=macos bus restart anfsd
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"ANFSD_BIN=$T/none is not an executable file"* ]]
}

@test "Linux: start, stop, reload through systemctl --user; nothing installed is 69" {
  ANFS_SERVICE_OS=linux bus start
  [ "$status" -eq 69 ]
  [[ "$stderr" == *"nats is not installed"*"ppm install core/nats"* ]]
  installed linux
  ANFS_SERVICE_OS=linux bus start anfsd
  [ "$status" -eq 0 ]
  grep -qx 'systemctl --user restart anfsd.service' "$STUB/svc.log"
  : > "$STUB/svc.log"
  ANFS_SERVICE_OS=linux bus stop
  [ "$(cat "$STUB/svc.log")" = "systemctl --user stop anfsd.service
systemctl --user stop anfs-nats.service" ]
  : > "$STUB/svc.log"
  ANFS_SERVICE_OS=linux bus reload
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/svc.log")" = "systemctl --user kill -s HUP anfsd.service" ]
  ANFS_SERVICE_OS=macos bus reload
  [ "$status" -eq 69 ]
}

@test "logs: the files on macOS, the journal on Linux; -f follows" {
  installed
  printf 'n1\nn2\n' > "$NS/nats-server.log"
  ANFS_SERVICE_OS=macos bus logs nats
  [ "$output" = "n1
n2" ]
  ANFS_SERVICE_OS=linux bus logs
  [ "$output" = "journalctl --user -u anfs-nats.service -u anfsd.service -n 50 --no-pager" ]
  ANFS_SERVICE_OS=linux bus logs anfsd -f
  [ "$output" = "journalctl --user -u anfsd.service -n 50 -f" ]
}

@test "nats --: the admin user and the URL in the environment, never on the command line" {
  installed
  printf '#!/bin/sh\necho "args: $*"\necho "env: $NATS_URL $NATS_USER $NATS_PASSWORD"\n' > "$HOME/.local/bin/nats"
  chmod +x "$HOME/.local/bin/nats"
  ANFS_SERVICE_OS=macos bus nats -- stream info ANFS --json
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "args: stream info ANFS --json" ]
  [ "${lines[1]}" = "env: nats://127.0.0.1:47222 admin pw-admin" ]
  rm "$NS/port"
  ANFS_SERVICE_OS=macos bus nats -- stream ls
  [ "$status" -eq 69 ]
}

@test "anfs bus is anfs-bus through anfs's package seam, exit status and all" {
  installed
  run --separate-stderr env ANFS_SERVICE_OS=macos "$HOME/.local/bin/anfs" bus status </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == "nats	stopped	"* ]]
  run "$HOME/.local/bin/anfs" help
  [[ "$output" == *bus* ]]
}
