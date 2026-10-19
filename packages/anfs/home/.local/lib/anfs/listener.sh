#!/usr/bin/env bash
# anfs library: the toolkit API (anfs rpc) behind a socket, socket-activated. Nothing runs between
# connections; each connection starts one `anfs rpc` with the connection as stdin and stdout.
# Sourced by core/anfs's install.sh (post_install, post_remove) and by `anfs implode`; needs
# paths.sh. Defines functions only.
#
#   macOS  ~/Library/LaunchAgents/io.anfs.rpc.plist: TCP 127.0.0.1:$ANFS_RPC_PORT (47100),
#          launchd's inetd mode (Wait false: one process per connection, the socket on stdin and
#          stdout), running `anfs rpc --token`. Loopback is open to every local process, so the
#          first line must be {"token":"..."}; the token says the grant: token.read or token.write
#          in $ANFS_STATE_HOME/rpc (0600, made once, kept by a reinstall).
#   Linux  ~/.config/systemd/user/anfs-rpc{,-write}.socket (Accept=yes) and their @.service:
#          $XDG_RUNTIME_DIR/anfs/rpc.sock (read) and rpc-write.sock (write), mode 0600; the file
#          permissions are the check.
#
# The unit files are written, not stowed: they hold absolute paths and the PATH the tools need,
# which launchd cannot expand. $ANFS_STATE_HOME/rpc/port is the port they were written with (pcm
# reads it). launchctl and systemctl are called through _anfs_rpc_launchctl/_systemctl so a test
# stubs them.

: "${ANFS_RPC_PORT:=47100}"
ANFS_RPC_HOME="$ANFS_STATE_HOME/rpc"
ANFS_RPC_LABEL=io.anfs.rpc
ANFS_RPC_PLIST="$HOME/Library/LaunchAgents/$ANFS_RPC_LABEL.plist"
ANFS_RPC_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
ANFS_RPC_UNITS="anfs-rpc.socket anfs-rpc@.service anfs-rpc-write.socket anfs-rpc-write@.service"

# macos or linux; ANFS_RPC_OS overrides (tests)
_anfs_rpc_os() { case "${ANFS_RPC_OS:-$OSTYPE}" in darwin*|macos) echo macos ;; *) echo linux ;; esac; }
_anfs_rpc_launchctl() { launchctl "$@"; }
_anfs_rpc_systemctl() { systemctl --user "$@"; }

# token.read and token.write, 0600, each made once
anfs_rpc_tokens() {
  local g f
  mkdir -p "$ANFS_RPC_HOME"
  chmod 700 "$ANFS_RPC_HOME"
  for g in read write; do
    f="$ANFS_RPC_HOME/token.$g"
    [[ -s "$f" ]] || ( umask 077; od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$f" )
    chmod 600 "$f"
  done
}

# The grant token $1 opens (read or write), or fails
anfs_rpc_token_grant() {
  local g f
  [[ -n "$1" ]] || return 1
  for g in read write; do
    f="$ANFS_RPC_HOME/token.$g"
    [[ -s "$f" && "$(cat "$f")" == "$1" ]] && { echo "$g"; return 0; }
  done
  return 1
}

_anfs_rpc_xml() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; printf '%s' "${s//>/&gt;}"; }

_anfs_rpc_plist() {
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by core/anfs (lib/anfs/listener.sh); removed by ppm remove core/anfs and anfs implode -->
<plist version="1.0">
<dict>
  <key>Label</key><string>$ANFS_RPC_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(_anfs_rpc_xml "$ANFS_BIN_DIR/anfs")</string>
    <string>rpc</string>
    <string>--token</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(_anfs_rpc_xml "$PATH")</string>
  </dict>
  <key>Sockets</key>
  <dict>
    <key>Listener</key>
    <dict>
      <key>SockNodeName</key><string>127.0.0.1</string>
      <key>SockServiceName</key><string>$ANFS_RPC_PORT</string>
      <key>SockType</key><string>stream</string>
      <key>SockFamily</key><string>IPv4</string>
    </dict>
  </dict>
  <key>inetdCompatibility</key>
  <dict>
    <key>Wait</key><false/>
  </dict>
  <key>StandardErrorPath</key><string>$(_anfs_rpc_xml "$ANFS_RPC_HOME/rpc.err")</string>
</dict>
</plist>
XML
}

# Usage: _anfs_rpc_socket <unit name> <socket file> <grant>
_anfs_rpc_socket() {
  cat <<UNIT
# Written by core/anfs (lib/anfs/listener.sh); removed by ppm remove core/anfs and anfs implode
[Unit]
Description=anfs toolkit API ($3)

[Socket]
ListenStream=%t/anfs/$2
SocketMode=0600
DirectoryMode=0700
Accept=yes

[Install]
WantedBy=sockets.target
UNIT
}

_anfs_rpc_service() {
  cat <<UNIT
# Written by core/anfs (lib/anfs/listener.sh); removed by ppm remove core/anfs and anfs implode
[Unit]
Description=anfs toolkit API connection ($1)
CollectMode=inactive-or-failed

[Service]
ExecStart=$ANFS_BIN_DIR/anfs rpc --grant $1
Environment="PATH=$PATH"
StandardInput=socket
StandardOutput=socket
StandardError=journal
UNIT
}

# Write this platform's unit files (and the tokens, the port); replaces what is there
anfs_rpc_units_write() {
  anfs_rpc_tokens
  printf '%s\n' "$ANFS_RPC_PORT" > "$ANFS_RPC_HOME/port"
  if [[ "$(_anfs_rpc_os)" == macos ]]; then
    mkdir -p "$(dirname "$ANFS_RPC_PLIST")"
    _anfs_rpc_plist > "$ANFS_RPC_PLIST"
  else
    mkdir -p "$ANFS_RPC_UNIT_DIR"
    _anfs_rpc_socket anfs-rpc rpc.sock read > "$ANFS_RPC_UNIT_DIR/anfs-rpc.socket"
    _anfs_rpc_service read > "$ANFS_RPC_UNIT_DIR/anfs-rpc@.service"
    _anfs_rpc_socket anfs-rpc-write rpc-write.sock write > "$ANFS_RPC_UNIT_DIR/anfs-rpc-write.socket"
    _anfs_rpc_service write > "$ANFS_RPC_UNIT_DIR/anfs-rpc-write@.service"
  fi
}

# Unload what is loaded (a missing job is fine), write the units, load them. Never fails: a
# machine without a launchd GUI session or a systemd user manager (ssh only, a container) gets a
# warning and the files, loaded at the next login.
anfs_rpc_listener_install() {
  anfs_rpc_listener_unload
  anfs_rpc_units_write
  if [[ "$(_anfs_rpc_os)" == macos ]]; then
    _anfs_rpc_launchctl bootstrap "gui/$(id -u)" "$ANFS_RPC_PLIST" 2>/dev/null ||
      { echo "anfs: could not load $ANFS_RPC_LABEL (no GUI session?); it loads at the next login" >&2; return 0; }
  else
    command -v systemctl >/dev/null 2>&1 &&
      _anfs_rpc_systemctl daemon-reload 2>/dev/null &&
      _anfs_rpc_systemctl enable --now anfs-rpc.socket anfs-rpc-write.socket 2>/dev/null ||
      { echo "anfs: could not enable anfs-rpc.socket (no systemd user manager?)" >&2; return 0; }
  fi
}

# Stop listening; the files stay. Only what this HOME's unit files say is loaded is unloaded
# (the launchd label is per user, not per HOME: a test's HOME must not unload the real one).
anfs_rpc_listener_unload() {
  if [[ "$(_anfs_rpc_os)" == macos ]]; then
    [[ -f "$ANFS_RPC_PLIST" ]] || return 0
    _anfs_rpc_launchctl bootout "gui/$(id -u)/$ANFS_RPC_LABEL" >/dev/null 2>&1 || true
  elif [[ -f "$ANFS_RPC_UNIT_DIR/anfs-rpc.socket" ]]; then
    _anfs_rpc_systemctl disable --now anfs-rpc.socket anfs-rpc-write.socket >/dev/null 2>&1 || true
  fi
}

# Unload and delete the unit files (the tokens stay: a reinstall keeps them; implode deletes
# $ANFS_RPC_HOME with the rest of anfs's state)
anfs_rpc_listener_remove() {
  anfs_rpc_listener_unload
  local u had=false
  rm -f "$ANFS_RPC_PLIST"
  for u in $ANFS_RPC_UNITS; do
    [[ -f "$ANFS_RPC_UNIT_DIR/$u" ]] && had=true
    rm -f "$ANFS_RPC_UNIT_DIR/$u"
  done
  if $had; then
    _anfs_rpc_systemctl daemon-reload >/dev/null 2>&1 || true
    rmdir "$ANFS_RPC_UNIT_DIR" "$(dirname "$ANFS_RPC_UNIT_DIR")" 2>/dev/null || true
  fi
  return 0
}
