#!/usr/bin/env bash
# anfs: the bus, NATS with JetStream and anfsd, as their packages (core/nats, core/anfsd) install
# them and `anfs bus` (core/anfsd's anfs-bus) runs them. One definition of each service, of NATS's
# rendered config and of where anfsd's binary is, so the hooks and anfs bus never disagree.
#
#   NATS     ~/.local/state/nats/ (0700): server.conf (0600, rendered from nats.env: never edit),
#            users/{anfsd,admin,reader,<layer>...} (a password each, 64 hex, made once), port,
#            jetstream/ (the store), nats-server.log (macOS). Listens on 127.0.0.1:$ANFS_NATS_PORT
#            (47222: not 4222, which apps in containers publish), monitoring on
#            127.0.0.1:$ANFS_NATS_HTTP_PORT. Users: anfsd (publishes anfs.>, keeps the stream ANFS
#            and its consumers), admin (the person's CLI: anfs bus nats), reader (subscribes to
#            anfs.>, reads ANFS and keeps its own consumers; never publishes anfs.>: 03 hands it to
#            the ui), and a publisher per layer in ANFS_BUS_LAYERS (nats.env: cnfs, lgat), named
#            after its namespace: it publishes its layer's subjects only, anfs.*.<layer>.> (never
#            anfs's anfs.*.anfs.> or another layer's), and reads as reader does (the spec,
#            anfs-io/events SPEC.md "The publisher user per layer"). Subjects are
#            anfs.<scope>.<type without io.>: anfs.<id>.anfs.report.filed, anfs.<id>.cnfs.<...>.
#   anfsd    ~/.local/share/anfsd/<version>/anfsd (the pinned release, linked from ~/.local/bin),
#            or ANFSD_BIN (anfsd.local.env: one built from source); ~/.local/state/anfsd/
#            (cursors.json, anfsd.pid, anfsd.log on macOS).
#   units    io.anfs.nats / anfs-nats.service; io.anfs.anfsd / anfsd.service (after NATS,
#            KillMode=process). lib/anfs/service.sh writes, loads and asks them.
#
# Functions and variables only, the bash floor. Needs paths.sh and service.sh; anfs_bus_paths
# loads nats.env and anfsd.env (anfs_tool_paths).

ANFS_BUS_NATS_USERS="anfsd admin reader"
# The JetStream API a consumer of ANFS needs (its own durable consumers, fetch, ack): reader's and
# every layer's publisher's; never stream management
ANFS_BUS_CONSUMER_API='"$JS.API.INFO", "$JS.API.STREAM.INFO.ANFS",
          "$JS.API.CONSUMER.*.ANFS.>", "$JS.API.CONSUMER.DURABLE.CREATE.ANFS.>",
          "$JS.API.CONSUMER.MSG.NEXT.ANFS.>", "$JS.ACK.ANFS.>"'

# The layers' publisher users (ANFS_BUS_LAYERS, nats.env: space-separated namespaces) into
# ANFS_BUS_LAYER_USERS; with "warn", one line for each name that cannot be one (not
# [a-z][a-z0-9-]*, anfs's own, or a user of the bus's)
anfs_bus_layers() {
  local l
  ANFS_BUS_LAYER_USERS=()
  for l in ${ANFS_BUS_LAYERS:-}; do
    if [[ ! "$l" =~ ^[a-z][a-z0-9-]*$ || " anfs $ANFS_BUS_NATS_USERS " == *" $l "* ]]; then
      [[ "${1:-}" != warn ]] || echo "anfs: ANFS_BUS_LAYERS: '$l' is not a layer's namespace (a-z, 0-9, -; not anfs, anfsd, admin or reader): no user for it" >&2
      continue
    fi
    [[ " ${ANFS_BUS_LAYER_USERS[*]} " == *" $l "* ]] || ANFS_BUS_LAYER_USERS+=("$l")
  done
  return 0
}

# The paths and settings of both (NATS_*_HOME, ANFSD_*_HOME; nats.env, anfsd.env), and the two
# service specs: ANFS_BUS_SVC_NATS, ANFS_BUS_SVC_ANFSD
anfs_bus_paths() {
  anfs_tool_paths nats
  anfs_tool_paths anfsd
  : "${ANFS_NATS_PORT:=47222}" "${ANFS_NATS_HTTP_PORT:=47223}"
  : "${ANFS_NATS_MAX_FILE:=2GiB}" "${ANFS_NATS_MAX_MEM:=64MiB}"
  declare -gA ANFS_BUS_SVC_NATS=(
    [label]=io.anfs.nats [unit]=anfs-nats.service [by]=core/nats
    [desc]="NATS with JetStream, the anfs bus" [log]="$NATS_STATE_HOME/nats-server.log"
  )
  declare -gA ANFS_BUS_SVC_ANFSD=(
    [label]=io.anfs.anfsd [unit]=anfsd.service [by]=core/anfsd
    [desc]="anfsd, the anfs daemon (the shipper)" [log]="$ANFSD_STATE_HOME/anfsd.log"
    [after]=anfs-nats.service [killmode]=process
  )
}

# A NATS config string: quoted, \ and " escaped
_anfs_bus_q() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }

# STATE for NATS: the directory (0700), a password per user (made once, kept by a reinstall)
anfs_bus_nats_users() {
  local u f
  mkdir -p -- "$NATS_STATE_HOME/users"
  chmod 700 "$NATS_STATE_HOME" "$NATS_STATE_HOME/users"
  anfs_bus_layers
  for u in $ANFS_BUS_NATS_USERS ${ANFS_BUS_LAYER_USERS[@]+"${ANFS_BUS_LAYER_USERS[@]}"}; do
    f="$NATS_STATE_HOME/users/$u"
    [[ -s "$f" ]] || ( umask 077; od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$f" )
    chmod 600 "$f"
  done
}

# Render server.conf (0600) and the port file from the settings; the users must exist
anfs_bus_nats_conf() {
  local f="$NATS_STATE_HOME/server.conf" tmp
  local -A pw=()
  local u layers=""
  [[ "$ANFS_NATS_PORT" =~ ^[0-9]+$ && "$ANFS_NATS_HTTP_PORT" =~ ^[0-9]+$ ]] ||
    { echo "anfs: ANFS_NATS_PORT and ANFS_NATS_HTTP_PORT are ports: $ANFS_NATS_PORT, $ANFS_NATS_HTTP_PORT" >&2; return 1; }
  [[ "$ANFS_NATS_MAX_FILE" =~ ^[0-9]+([KMGT]i?B?)?$ && "$ANFS_NATS_MAX_MEM" =~ ^[0-9]+([KMGT]i?B?)?$ ]] ||
    { echo "anfs: ANFS_NATS_MAX_FILE and ANFS_NATS_MAX_MEM are sizes (2GiB, 64MiB): $ANFS_NATS_MAX_FILE, $ANFS_NATS_MAX_MEM" >&2; return 1; }
  anfs_bus_layers warn
  for u in $ANFS_BUS_NATS_USERS ${ANFS_BUS_LAYER_USERS[@]+"${ANFS_BUS_LAYER_USERS[@]}"}; do
    pw[$u]=$(< "$NATS_STATE_HOME/users/$u") || return 1
  done
  for u in ${ANFS_BUS_LAYER_USERS[@]+"${ANFS_BUS_LAYER_USERS[@]}"}; do
    layers+="
    {
      user: \"$u\", password: \"${pw[$u]}\"
      permissions: {
        subscribe: {allow: [\"anfs.>\", \"_INBOX.>\"]}
        publish: {allow: [
          \"anfs.*.$u.>\",
          $ANFS_BUS_CONSUMER_API
        ]}
      }
    }"
  done
  tmp=$(mktemp "$NATS_STATE_HOME/.server.conf.XXXXXX") || return 1
  chmod 600 "$tmp"
  cat > "$tmp" <<CONF
# Written by core/nats (lib/anfs/bus.sh) from ~/.config/nats/nats.env and nats.local.env;
# anfs bus restart nats writes it again. Never edit: change the settings.
listen: 127.0.0.1:$ANFS_NATS_PORT
http: 127.0.0.1:$ANFS_NATS_HTTP_PORT
server_name: anfs
max_payload: 64KB
jetstream {
  store_dir: $(_anfs_bus_q "$NATS_STATE_HOME")
  max_file_store: $ANFS_NATS_MAX_FILE
  max_memory_store: $ANFS_NATS_MAX_MEM
}
authorization {
  users: [
    {user: "anfsd", password: "${pw[anfsd]}"}
    {user: "admin", password: "${pw[admin]}"}
    {
      user: "reader", password: "${pw[reader]}"
      permissions: {
        subscribe: {allow: ["anfs.>", "_INBOX.>"]}
        publish: {allow: [
          $ANFS_BUS_CONSUMER_API
        ]}
      }
    }$layers
  ]
}
CONF
  mv -f -- "$tmp" "$f"
  printf '%s\n' "$ANFS_NATS_PORT" > "$NATS_STATE_HOME/port"
}

# The client URL and the admin password (for anfs bus nats), into NATS_URL_FOR and NATS_ADMIN_PW;
# 1 when NATS is not set up here
anfs_bus_nats_admin() {
  local port
  port=$(cat "$NATS_STATE_HOME/port" 2>/dev/null) || return 1
  NATS_ADMIN_PW=$(cat "$NATS_STATE_HOME/users/admin" 2>/dev/null) || return 1
  NATS_URL_FOR="nats://127.0.0.1:$port"
}

# Write NATS's unit
anfs_bus_nats_unit() {
  local bin="$ANFS_BIN_DIR/nats-server"
  [[ -L "$bin" ]] && bin=$(readlink -- "$bin")
  anfs_service_write ANFS_BUS_SVC_NATS "$bin" -c "$NATS_STATE_HOME/server.conf"
}

# The anfsd the unit runs, into REPLY, and ANFS_BUS_ANFSD_FROM (source, release): ANFSD_BIN when
# set, else the release ~/.local/bin/anfsd links to. 1 when neither is there.
anfs_bus_anfsd_bin() {
  ANFS_BUS_ANFSD_FROM=""
  if [[ -n "${ANFSD_BIN:-}" ]]; then
    REPLY="$ANFSD_BIN" ANFS_BUS_ANFSD_FROM=source
    [[ -x "$REPLY" && ! -d "$REPLY" ]]
    return
  fi
  REPLY=""
  [[ -L "$ANFS_BIN_DIR/anfsd" ]] || return 1
  REPLY=$(readlink -- "$ANFS_BIN_DIR/anfsd") ANFS_BUS_ANFSD_FROM=release
  [[ -x "$REPLY" ]]
}

# Write anfsd's unit (for the anfsd anfs_bus_anfsd_bin names); 1 when there is none
anfs_bus_anfsd_unit() {
  anfs_bus_anfsd_bin || return 1
  mkdir -p -- "$ANFSD_STATE_HOME"
  chmod 700 "$ANFSD_STATE_HOME"
  anfs_service_write ANFS_BUS_SVC_ANFSD "$REPLY" run
}
