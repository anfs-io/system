#!/usr/bin/env bats
# anfs rpc (units/toolkit-api/01-rpc): the toolkit's API as a filter, JSON lines in and out. The
# real anfs in a temp $HOME; ppm is a stub built like a real tool (log.sh, cli.sh), in
# $ANFS_BIN_DIR. Requests are piped in; nothing here touches a real tool.
# Run: bats packages/anfs/tests/rpc.bats

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIB="$REPO/packages/anfs/home/.local/lib/anfs"
  export HOME="$BATS_TEST_TMPDIR/home"
  BIN="$HOME/.local/bin"
  ANFS="$BIN/anfs"
  local tools="$BATS_TEST_TMPDIR/tools" t
  mkdir -p "$HOME/.local/lib" "$BIN" "$HOME/.config/anfs" "$tools"
  ln -s "$LIB" "$HOME/.local/lib/anfs"
  ln -s "$REPO/packages/anfs/home/.local/bin/anfs" "$ANFS"
  for t in bash yq; do ln -s "$(command -v "$t")" "$tools/$t"; done
  export PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_JSON ANFS_STATE_HOME
  unset ANFS_RPC ANFS_RPC_TIMEOUT SUDO_ASKPASS
  export ANFS_LOG=off GIT_CONFIG_NOSYSTEM=1
  printf '# Your anfs sources\n' > "$HOME/.config/anfs/user.list"
  : > "$HOME/.config/anfs/system.list"
  ARGS="$BATS_TEST_TMPDIR/args"

  # ppm, as the real tools are built: every command the tests need
  cat > "$BIN/ppm" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$LIB/log.sh"
source "$LIB/table.sh"
source "$LIB/cli.sh"
CLI_TOOL=ppm CLI_VERSION=0.2.5
cli_cmd list "Packages" --alias ls
cli_cmd path "A path" --arg "package"
cli_cmd show "Its arguments, one per line" --arg "what..."
cli_cmd install "Records its argv" --opt "-y --yes: Do not ask" --arg "what..."
cli_cmd remove "Asks first" --opt "-y --yes: Do not ask" --arg "what"
cli_cmd fail "Fails"
cli_cmd hang "Hangs"
cli_cmd noisy "Out and err"
cmd_list() { if anfs_json_on; then echo '[{"name":"core/a b","v":1}]'; else echo "core/a b 1"; fi; }
cmd_path() { echo "/x/\$1"; }
cmd_show() { printf '<%s>\n' "\$@"; }
cmd_install() { printf '%s\n' "\$@" > "$ARGS"; echo installed; }
cmd_remove() { anfs_confirm "remove deletes \$1" "Remove?"; echo "removed \$1"; }
cmd_fail() { echo "first" >&2; echo "the last line" >&2; exit 3; }
# A grandchild, as a tool's \$(yq ...) on a hung mount: the timeout must reach past the tool's children
cmd_hang() { local x; x=\$(bash -c 'echo \$\$ > "\$1"; exec sleep 30' - "$BATS_TEST_TMPDIR/hang.pid"; true); }
cmd_noisy() { echo one; echo two >&2; echo three; }
cli_dispatch "\$@"
SH
  chmod +x "$BIN/ppm"
}

teardown() {
  [[ -z "${RPID:-}" ]] || kill "$RPID" 2>/dev/null || true
  [[ ! -f "$BATS_TEST_TMPDIR/hang.pid" ]] || kill "$(cat "$BATS_TEST_TMPDIR/hang.pid")" 2>/dev/null || true
}

rpc() { "$ANFS" rpc "$@"; }

@test "a read: data is the tool's --json output, parsed" {
  run rpc <<<'{"run":["ppm","list"]}'
  [ "$status" -eq 0 ]
  [ "$output" = '{"exit":0,"data":[{"name":"core/a b","v":1}]}' ]
}

@test "a non-JSON answer is out" {
  run rpc <<<'{"run":["ppm","path","core/x"]}'
  [ "$output" = '{"exit":0,"out":"/x/core/x"}' ]
}

@test "through anfs: anfs package list is ppm list, a read" {
  run rpc <<<'{"run":["anfs","package","list"]}'
  [ "$output" = '{"exit":0,"data":[{"name":"core/a b","v":1}]}' ]
}

@test "version: anfs's and each installed tool's" {
  run rpc <<<'{"version":true}'
  [[ "$output" =~ ^\{\"anfs\":\"[0-9.]+\",\"tools\":\{\"ppm\":\"0.2.5\"\}\}$ ]]
}

@test "refused: not a toolkit tool, a path, implode, rpc; each answer is an error and the next line works" {
  run rpc <<'EOF'
{"run":["bash","-c","echo hi"]}
{"run":["../x"]}
{"run":["/usr/bin/env","ppm"]}
{"run":["pvm","list"]}
{"run":["anfs","implode","-y"]}
{"run":["ppm","implode"]}
{"run":["anfs","rpc"]}
{"run":["ppm","path","ok"]}
EOF
  [ "${#lines[@]}" -eq 8 ]
  for i in 0 1 2 3; do [[ "${lines[i]}" == '{"error":"not a toolkit tool: '* ]]; done
  [ "${lines[4]}" = '{"error":"refused: implode"}' ]
  [ "${lines[5]}" = '{"error":"refused: implode"}' ]
  [ "${lines[6]}" = '{"error":"refused: anfs rpc"}' ]
  [ "${lines[7]}" = '{"exit":0,"out":"/x/ok"}' ]
}

@test "a write under --grant read (the default) is refused; under write it runs" {
  run rpc <<<'{"run":["ppm","install","a"]}'
  [ "$output" = '{"error":"refused: a write request (install) under --grant read"}' ]
  [ ! -f "$ARGS" ]
  run rpc --grant write <<<'{"run":["ppm","install","a"]}'
  [ "$output" = '{"exit":0,"out":"installed"}' ]
  run "$ANFS" rpc --grant root </dev/null
  [ "$status" -eq 64 ]
}

@test "malformed requests answer error and the connection stays open" {
  run rpc <<'EOF'
not json
[1,2]
{"run":"ppm list"}
{"run":[]}
{"run":["ppm",1]}
{"nothing":true}

{"run":["ppm","path","still"]}
EOF
  [ "${#lines[@]}" -eq 7 ]
  [ "${lines[0]}" = '{"error":"not a JSON request"}' ]
  for i in 1 2 3 4 5; do [[ "${lines[i]}" == '{"error":'* ]]; done
  [ "${lines[6]}" = '{"exit":0,"out":"/x/still"}' ]
}

@test "no shell: \$(...), ; and spaces reach the tool unchanged" {
  run rpc <<<'{"run":["ppm","show","$(touch /tmp/rpc-pwned)","a; b","two  spaces","\"q\""]}'
  [ "$output" = '{"exit":0,"out":"<$(touch /tmp/rpc-pwned)>\n<a; b>\n<two  spaces>\n<\"q\">"}' ]
  [ ! -e /tmp/rpc-pwned ]
}

@test "yes adds -y, before a --" {
  run rpc --grant write <<<'{"run":["ppm","install","a","--","b"],"yes":true}'
  [ "$output" = '{"exit":0,"out":"installed"}' ]
  # -y before the --, so it is an option and not an argument
  [ "$(cat "$ARGS")" = $'a\nb' ]
  run rpc --grant write <<<'{"run":["ppm","remove","x"],"yes":true}'
  [ "$output" = '{"exit":0,"out":"removed x"}' ]
}

@test "a confirm without yes exits 77: needs terminal, with the command" {
  run rpc --grant write <<<'{"run":["ppm","remove","x"]}'
  [ "$output" = '{"exit":77,"needs":"terminal","command":["ppm","remove","x"],"error":"ppm: remove deletes x; pass -y to confirm without a terminal"}' ]
}

@test "a failed run: its exit and the last stderr line" {
  run rpc --grant write <<<'{"run":["ppm","fail"]}'
  [ "$output" = '{"exit":3,"error":"the last line"}' ]
}

@test "stream: a line per line of stdout and stderr, then the exit" {
  run rpc --grant write <<<'{"run":["ppm","noisy"],"stream":true}'
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[3]}" = '{"exit":0}' ]
  [[ " ${lines[*]:0:3} " == *'{"out":"one"}'* && " ${lines[*]:0:3} " == *'{"out":"two"}'* ]]
  [[ "${lines[*]}" == *'{"out":"one"}'*'{"out":"three"}'* ]]
}

@test "the timeout kills a run that hangs, and everything under it" {
  ANFS_RPC_TIMEOUT=1 run rpc --grant write <<<'{"run":["ppm","hang"]}'
  [ "$output" = '{"exit":124,"error":"timed out after 1s","command":["ppm","hang"]}' ]
  sleep 0.2
  ! kill -0 "$(cat "$BATS_TEST_TMPDIR/hang.pid")" 2>/dev/null
}

@test "watch: a start and an end event for a run in another process" {
  unset ANFS_LOG
  local in="$BATS_TEST_TMPDIR/in" out="$BATS_TEST_TMPDIR/out" i w
  mkfifo "$in"
  "$ANFS" rpc <"$in" >"$out" 2>&1 &
  RPID=$!
  exec {w}>"$in"
  printf '%s\n' '{"watch":true}' '{"version":true}' >&$w
  for i in $(seq 50); do grep -q '"anfs":' "$out" && break; sleep 0.1; done
  "$BIN/ppm" path core/z >/dev/null
  for i in $(seq 50); do grep -q '"event":"end"' "$out" && break; sleep 0.1; done
  exec {w}>&-
  wait "$RPID"
  RPID=""
  grep -Eq '^\{"event":"start","id":"[0-9]+-[0-9]+","tool":"ppm","pid":[0-9]+,"time":"[^"]+","args":"path core/z"\}$' "$out"
  grep -Eq '^\{"event":"end","id":"[0-9]+-[0-9]+","tool":"ppm","pid":[0-9]+,"time":"[^"]+","exit":0\}$' "$out"
  # the pair has one id; the rpc's own start (before the watch) is not an event
  [ "$(grep -o '"id":"[^"]*"' "$out" | sort -u | wc -l | tr -d ' ')" = 1 ]
  ! grep -q '"tool":"anfs"' "$out"
}

@test "a read is not an event: reads run with ANFS_LOG=off" {
  unset ANFS_LOG
  rpc <<<'{"run":["ppm","list"]}' >/dev/null
  ! grep -q 'ppm\[' "$HOME/.local/state/anfs/anfs.log"
  rpc --grant write <<<'{"run":["ppm","install","a"]}' >/dev/null
  grep -q 'ppm\[[0-9]*\] end: [0-9]*-[0-9]* 0$' "$HOME/.local/state/anfs/anfs.log"
}

@test "sudo that cannot run unattended exits 77 (ppm's _system_sudo)" {
  local stub="$BATS_TEST_TMPDIR/tools/sudo"
  printf '#!/bin/sh\necho called >> "%s"\nexit 1\n' "$BATS_TEST_TMPDIR/sudo.log" > "$stub"
  chmod +x "$stub"
  # under rpc there is no terminal, whatever the parent has
  ANFS_RPC=1 run bash -c 'ppm_fail() { echo "ERROR: $*" >&2; }; source "$1"; _system_sudo "pkg"; echo after' _ \
    "$REPO/packages/ppm/home/.local/lib/ppm/platform.sh" </dev/null
  [ "$status" -eq 77 ]
  [[ "$output" == *"needs sudo: run it in a terminal, or set SUDO_ASKPASS"* ]]
  [[ "$output" != *after* ]]
  # only sudo -n was tried: no prompt
  [ "$(grep -c called "$BATS_TEST_TMPDIR/sudo.log")" -eq 1 ]
}

# --- the token (plan 02): the listener's TCP mode, driven directly, no listener -------------------

tokens() {
  local d="$HOME/.local/state/anfs/rpc"
  mkdir -p "$d"
  echo rtok > "$d/token.read"
  echo wtok > "$d/token.write"
}

@test "--token: no token line, a wrong one or a malformed one: unauthorized, closed, nothing run" {
  tokens
  run -1 rpc --token <<<'{"run":["ppm","install","a"]}'
  [ "$output" = '{"error":"unauthorized: the first line is {\"token\":\"...\"}"}' ]
  run -1 rpc --token <<<'{"token":"nope"}
{"run":["ppm","path","x"]}'
  [ "${#lines[@]}" -eq 1 ] && [[ "${lines[0]}" == '{"error":"unauthorized'* ]]
  run -1 rpc --token <<<'{"token":"rtok","run":["ppm","path","x"]}'
  [[ "$output" == '{"error":"unauthorized'* ]]
  run -1 rpc --token <<<'{"token":""}'
  [[ "$output" == '{"error":"unauthorized'* ]]
  [ ! -f "$ARGS" ]
}

@test "--token: no tokens on disk: nothing opens" {
  run -1 rpc --token <<<'{"token":""}
{"version":true}'
  [[ "$output" == '{"error":"unauthorized'* ]]
}

@test "--token: the read token is the read grant, the write token the write grant (whatever --grant says)" {
  tokens
  run rpc --token --grant write <<<'{"token":"rtok"}
{"run":["ppm","path","x"]}
{"run":["ppm","install","a"]}'
  [ "${lines[0]}" = '{"exit":0,"out":"/x/x"}' ]
  [ "${lines[1]}" = '{"error":"refused: a write request (install) under --grant read"}' ]
  run rpc --token <<<'{"token":"wtok"}
{"run":["ppm","install","a"]}'
  [ "$output" = '{"exit":0,"out":"installed"}' ]
}

@test "without --token (a unix socket) a first token line is read and ignored" {
  run rpc <<<'{"token":"anything"}
{"run":["ppm","path","x"]}'
  [ "$output" = '{"exit":0,"out":"/x/x"}' ]
  # only the first line: a later one is a request, and not one rpc knows
  run rpc <<<'{"run":["ppm","path","x"]}
{"token":"anything"}'
  [ "${lines[1]}" = '{"error":"unknown request (run, watch or version)"}' ]
}

@test "a group's list is a read: wsm skill list (skill is a group), not a write" {
  cat > "$BIN/wsm" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$LIB/log.sh"
source "$LIB/table.sh"
source "$LIB/cli.sh"
CLI_TOOL=wsm CLI_VERSION=0.7.0
cli_group skill "Skills"
cli_cmd "skill list" "Skills" --alias ls
cli_cmd "skill install" "Install"
cmd_skill_list() { echo '[{"skill":"acme/tech/x","status":"ok"}]'; }
cmd_skill_install() { echo installed; }
cli_dispatch "\$@"
SH
  chmod +x "$BIN/wsm"
  run rpc <<<'{"run":["wsm","skill","list"]}'
  [ "$output" = '{"exit":0,"data":[{"skill":"acme/tech/x","status":"ok"}]}' ]
  run rpc <<<'{"run":["anfs","space","skill","ls"]}'
  [ "$output" = '{"exit":0,"data":[{"skill":"acme/tech/x","status":"ok"}]}' ]
  run rpc <<<'{"run":["wsm","skill","install"]}'
  [[ "$output" == *'refused: a write request (install) under --grant read'* ]]
}
