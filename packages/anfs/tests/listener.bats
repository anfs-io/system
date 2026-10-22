#!/usr/bin/env bats
# The toolkit API's listener (units/toolkit-api/02-socket): core/anfs's post_install writes and
# loads a launchd agent (macOS) or two systemd user sockets (Linux); post_remove and anfs implode
# unload and delete them. A temp $HOME; launchctl and systemctl are stubs that log their argv:
# nothing here loads a unit or listens. The platform is ANFS_RPC_OS.
# Run: bats packages/anfs/tests/listener.bats

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PKG="$REPO/packages/anfs"
  export HOME="$BATS_TEST_TMPDIR/home"
  local tools="$BATS_TEST_TMPDIR/tools" t
  mkdir -p "$HOME/.local/lib" "$HOME/.local/bin" "$HOME/.config/anfs" "$tools"
  ln -s "$PKG/home/.local/lib/anfs" "$HOME/.local/lib/anfs"
  ln -s "$PKG/home/.local/bin/anfs" "$HOME/.local/bin/anfs"
  for t in bash yq; do ln -s "$(command -v "$t")" "$tools/$t"; done
  CALLS="$BATS_TEST_TMPDIR/svc.calls"
  : > "$CALLS"
  # FAIL=1: the stub fails (no GUI session, no user manager)
  for t in launchctl systemctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n[ -z "$FAIL" ]\n' "$t" "$CALLS" > "$tools/$t"
    chmod +x "$tools/$t"
  done
  export PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_STATE_HOME ANFS_RPC_PORT FAIL
  export ANFS_LOG=off ANFS_TABLE=tsv GIT_CONFIG_NOSYSTEM=1
  printf '# Your anfs sources\n' > "$HOME/.config/anfs/user.list"
  : > "$HOME/.config/anfs/system.list"
  RPC="$HOME/.local/state/anfs/rpc"
  PLIST="$HOME/Library/LaunchAgents/io.anfs.rpc.plist"
  UNITS="$HOME/.config/systemd/user"
}

# Run one of core/anfs's hooks, as ppm does: install.sh sourced in a subshell, user_message given
hook() { bash -c 'user_message() { printf "%s" "$@"; echo; }; source "$1/install.sh"; "$2"' _ "$PKG" "$1"; }

mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

@test "macOS post_install: the agent on 127.0.0.1:47100, inetd mode, anfs rpc --token; loaded" {
  ANFS_RPC_OS=macos run hook post_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"127.0.0.1:47100"* ]]
  [ -f "$PLIST" ]
  ! command -v plutil >/dev/null || plutil -lint "$PLIST"
  grep -q '<key>Label</key><string>io.anfs.rpc</string>' "$PLIST"
  grep -q "<string>$HOME/.local/bin/anfs</string>" "$PLIST"
  tr -d ' \n' < "$PLIST" | grep -q '<string>rpc</string><string>--token</string></array>'
  grep -q '<key>SockNodeName</key><string>127.0.0.1</string>' "$PLIST"
  grep -q '<key>SockServiceName</key><string>47100</string>' "$PLIST"
  tr -d ' \n' < "$PLIST" | grep -q '<key>inetdCompatibility</key><dict><key>Wait</key><false/></dict>'
  grep -q "<key>PATH</key><string>$BATS_TEST_TMPDIR/tools:" "$PLIST"
  [ "$(cat "$CALLS")" = "launchctl bootstrap gui/$(id -u) $PLIST" ]
  [ "$(cat "$RPC/port")" = 47100 ]
  [ ! -e "$UNITS" ]
}

@test "the tokens: one per grant, 64 hex, 0600 in a 0700 dir; a reinstall keeps them" {
  ANFS_RPC_OS=macos hook post_install
  local r w
  r=$(cat "$RPC/token.read") w=$(cat "$RPC/token.write")
  [[ "$r" =~ ^[0-9a-f]{64}$ && "$w" =~ ^[0-9a-f]{64}$ && "$r" != "$w" ]]
  [ "$(mode "$RPC/token.read")" = 600 ] && [ "$(mode "$RPC/token.write")" = 600 ] && [ "$(mode "$RPC")" = 700 ]
  # ppm install --reinstall: post_remove, then post_install
  : > "$CALLS"
  ANFS_RPC_OS=macos hook post_remove
  ANFS_RPC_OS=macos hook post_install
  [ "$(cat "$RPC/token.read")" = "$r" ] && [ "$(cat "$RPC/token.write")" = "$w" ]
  [ "$(sed -n 1p "$CALLS")" = "launchctl bootout gui/$(id -u)/io.anfs.rpc" ]
  [ "$(sed -n 2p "$CALLS")" = "launchctl bootstrap gui/$(id -u) $PLIST" ]
}

@test "ANFS_RPC_PORT: the port the agent listens on, recorded for pcm" {
  ANFS_RPC_OS=macos ANFS_RPC_PORT=47999 hook post_install
  grep -q '<key>SockServiceName</key><string>47999</string>' "$PLIST"
  [ "$(cat "$RPC/port")" = 47999 ]
}

@test "macOS: launchctl fails (no GUI session): the install goes on, with a warning" {
  FAIL=1 ANFS_RPC_OS=macos run hook post_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not load io.anfs.rpc"* ]]
  [ -f "$PLIST" ]
}

@test "macOS post_remove: unloaded and deleted; the tokens stay" {
  ANFS_RPC_OS=macos hook post_install
  : > "$CALLS"
  ANFS_RPC_OS=macos run hook post_remove
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "launchctl bootout gui/$(id -u)/io.anfs.rpc" ]
  [ ! -e "$PLIST" ]
  [ -s "$RPC/token.read" ]
}

@test "remove with no plist in this HOME never calls launchctl (the label is per user, not per HOME)" {
  ANFS_RPC_OS=macos run hook post_remove
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "Linux post_install: two sockets, Accept=yes, 0600, each starting anfs rpc with its grant; enabled" {
  ANFS_RPC_OS=linux run hook post_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"rpc.sock (read) and rpc-write.sock (write)"* ]]
  [ "$(ls "$UNITS" | sort | tr '\n' ' ')" = "anfs-rpc-write.socket anfs-rpc-write@.service anfs-rpc.socket anfs-rpc@.service " ]
  grep -qx 'ListenStream=%t/anfs/rpc.sock' "$UNITS/anfs-rpc.socket"
  grep -qx 'ListenStream=%t/anfs/rpc-write.sock' "$UNITS/anfs-rpc-write.socket"
  for u in anfs-rpc anfs-rpc-write; do
    grep -qx 'Accept=yes' "$UNITS/$u.socket"
    grep -qx 'SocketMode=0600' "$UNITS/$u.socket"
    grep -qx 'StandardInput=socket' "$UNITS/$u@.service"
    grep -qx 'StandardOutput=socket' "$UNITS/$u@.service"
  done
  grep -qx "ExecStart=$HOME/.local/bin/anfs rpc --grant read" "$UNITS/anfs-rpc@.service"
  grep -qx "ExecStart=$HOME/.local/bin/anfs rpc --grant write" "$UNITS/anfs-rpc-write@.service"
  [ "$(cat "$CALLS")" = "systemctl --user daemon-reload
systemctl --user enable --now anfs-rpc.socket anfs-rpc-write.socket" ]
  [ ! -e "$PLIST" ]
}

@test "Linux post_remove: disabled, the units deleted, the dirs it made gone" {
  ANFS_RPC_OS=linux hook post_install
  : > "$CALLS"
  ANFS_RPC_OS=linux run hook post_remove
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "systemctl --user disable --now anfs-rpc.socket anfs-rpc-write.socket
systemctl --user daemon-reload" ]
  [ ! -e "$HOME/.config/systemd" ]
}

@test "Linux: no user manager: the install goes on, with a warning" {
  FAIL=1 ANFS_RPC_OS=linux run hook post_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not enable anfs-rpc.socket"* ]]
}

@test "anfs implode: the listener unloaded and deleted before anything else, the tokens with it" {
  ANFS_RPC_OS=macos hook post_install
  : > "$CALLS"
  ANFS_RPC_OS=macos run "$HOME/.local/bin/anfs" implode -y </dev/null
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == *"the toolkit API's listener"* ]]
  [ "$(cat "$CALLS")" = "launchctl bootout gui/$(id -u)/io.anfs.rpc" ]
  [ ! -e "$PLIST" ] && [ ! -e "$RPC" ]
}

@test "anfs implode on Linux: the sockets disabled and deleted" {
  ANFS_RPC_OS=linux hook post_install
  : > "$CALLS"
  ANFS_RPC_OS=linux run "$HOME/.local/bin/anfs" implode -y </dev/null
  [ "$status" -eq 0 ]
  grep -q 'disable --now anfs-rpc.socket anfs-rpc-write.socket' "$CALLS"
  [ ! -e "$UNITS" ] && [ ! -e "$RPC" ]
}
