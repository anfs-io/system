#!/usr/bin/env bash
# anfs: events — space ids, anfs_emit (one JSON line per event, appended to the space's log in
# STATE), and `events ls`, the one list command `wsm events ls` and `anfs events ls` share (as
# repo.sh's push is `anfs src push` and `wsm repo push`).
#
#   anfs_emit [--at DIR|--host] <type> <subject> [key=value...]
#
# THE LOG: ${XDG_STATE_HOME:-~/.local/state}/anfs/events/<space id>/<YYYY-MM>.jsonl (UTC month),
# events/host/ for the host scope. One CloudEvent per line (1.0, structured JSON), never rewritten:
# the spool a shipper (anfsd: NATS JetStream) sends as is, and a mirror grep reads. Beside each
# month file, <YYYY-MM>.bus.jsonl is anfsd's recorder's: the events published to NATS directly
# (another layer's producers), never written here and never shipped. The spec (anfsv 1, every
# layer's events, language-neutral): https://github.com/anfs-io/events (SPEC.md). What this writes:
#
#   {"specversion":"1.0","id":"<UUIDv7>","source":"/anfs/spaces/<space id>"|"/anfs/host",
#    "type":"io.anfs.<noun>.<verb>","subject":"...","time":"<UTC, ms>Z",
#    "datacontenttype":"application/json","actor":"<who>","actorspace":"<space id>",
#    "actorrole":"<role>","spacepath":"<wsm path>","anfsv":1,"data":{<string>:<string>...}}
#
# subject, actorspace, actorrole and spacepath are left out when they have no value. Nothing in it
# depends on the host or a file path: the space id is the identity, spacepath only says what wsm
# called the space when it was written. anfs_emit takes the short type (report.filed). Attribute
# strings (subject, actor, spacepath) hold no control character; data values may (escaped); no
# string holds DEL, a C1 control or bytes that are not UTF-8: such an emit is refused, a warning.
# The reader takes any layer's events (io.cnfs.*, /cnfs/spaces/<id>/...; data any JSON object).
#
# THE SPACE: --host; --at DIR (the nearest space.yml at or above DIR); else ANFS_SPACE (a space
# path, anfs-dev or cnfs/apps); else the nearest space.yml at or above the current directory; else
# the host scope. A space with no id goes to the host scope, with a warning.
# THE ACTOR: ANFS_ACTOR (when it is <kind>[:<name>]: else a warning, and the detection); else
# Claude Code (CLAUDECODE=1: claude:<8 of CLAUDE_CODE_SESSION_ID>); else AI_AGENT's first part;
# else shell:$USER; the first of them that is a valid actor, else shell. AS: ANFS_AS=<space
# path>/<role>.
#
# ATOMIC, NO LOCKS: a line is at most 4096 bytes (larger is refused) and goes out in one write(2)
# with O_APPEND (cat): bash's printf writes through a 1 KB stdio buffer on macOS and would split it.
# Emitting never fails the caller: an error is a warning. ANFS_EVENTS=off writes nothing.
#
# A RUN'S SPOOL: inside a run anfsd started (agents/02d), ANFS_EVENTS_SPOOL is the run's own
# directory (~/.local/state/anfsd/runs/<run id>/events): emits go to
# $ANFS_EVENTS_SPOOL/<space id>|host/<YYYY-MM>.jsonl instead of the log, and anfsd moves them into
# the log under the run's identity (it stamps actor, actorspace, actorrole, actorrun, and keeps a
# differing claim in actorclaimed). The line may then be at most 4096 - 512 bytes, the room the
# stamp needs. Reading (events ls, report wait) still reads the log: a run sees its own events
# there once anfsd has ingested them, a second or so later.
#
# Functions only, the bash floor (5.2: EPOCHREALTIME, SRANDOM), no tool's code. Needs paths.sh,
# log.sh, and for events ls cli.sh and table.sh.

ANFS_EVENTS_HOME="$ANFS_STATE_HOME/events"
ANFS_EVENT_MAX=4096
# What a line written into a run's spool (ANFS_EVENTS_SPOOL) leaves for anfsd's stamp
ANFS_EVENT_STAMP_RESERVE=512
# The namespaces other layers own (the spec's REGISTRY.md): io.<ns>.* is theirs, its short type
# <ns>.<rest>; anfs's own types never start with one
ANFS_EVENT_NAMESPACES="cnfs lgat rws roteoh"
# The types toolkit code emits, anfsd's run.*, container.*, pod.* and podman.* included (completion; a glob of each noun is offered too)
ANFS_EVENT_TYPES="report.filed report.closed source.updated package.installed package.removed package.failed run.submitted run.working run.completed run.failed run.canceled run.rejected container.created container.started container.stopped container.died container.removed container.paused container.unpaused container.health pod.created pod.started pod.stopped pod.removed podman.connected podman.disconnected"

# --- space ids ------------------------------------------------------------------------------

# A new space id into REPLY: 10 characters of a-z2-7 (ovm's vault ids' alphabet), from SRANDOM
anfs_space_id_new() {
  local a=abcdefghijklmnopqrstuvwxyz234567 i
  REPLY=""
  for (( i = 0; i < 10; i++ )); do REPLY+="${a:SRANDOM % 32:1}"; done
}

# The id: line of a space.yml into REPLY. 0 a valid id (10 of a-z0-9); 1 none (or no file); 2 a
# value that is not one (REPLY holds it). Top-level `id:` only, read without yq.
anfs_space_id_read() {
  local line re='^id:[[:space:]]*["'"'"']?([^"'"'"'#[:space:]]*)["'"'"']?[[:space:]]*(#.*)?$'
  REPLY=""
  [[ -f "$1" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == id:* && "$line" =~ $re ]] || continue
    REPLY="${BASH_REMATCH[1]}"
    [[ "$REPLY" =~ ^[a-z0-9]{10}$ ]] && return 0
    return 2
  done < "$1"
  return 1
}

# Write `id: <id>` into a space.yml (a real file, not a link) that has no id: before its first line
# that is neither a comment nor blank; a {} file becomes the id alone; another flow mapping is
# rewritten by yq. Atomic (a temp file beside it, then mv). 1 on any failure.
anfs_space_id_write() {
  local f="$1" id="$2" tmp line done=false body=""
  [[ -f "$f" && ! -L "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] || { body="$line"; break; }
  done < "$f"
  if [[ "$body" == "{"* && ! "$body" =~ ^\{[[:space:]]*\}[[:space:]]*$ ]]; then
    ID="$id" yq -i -P '.id = strenv(ID)' "$f"
    return
  fi
  tmp=$(mktemp "${f%/*}/.space.yml.XXXXXX") || return 1
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      if ! $done && [[ ! "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
        done=true
        printf 'id: %s\n' "$id"
        [[ "$line" =~ ^\{[[:space:]]*\}[[:space:]]*$ ]] && continue
      fi
      printf '%s\n' "$line"
    done < "$f"
    $done || printf 'id: %s\n' "$id"
  } > "$tmp" && mv -f -- "$tmp" "$f" || { rm -f -- "$tmp"; return 1; }
}

# --- where a space is -------------------------------------------------------------------------

# The root wsm installs into, as written (WSM_SPACES_HOME: the environment, else wsm's settings
# files, else ~/spaces), into REPLY
_ANFS_EV_ROOT=""
_anfs_ev_root() {
  if [[ -z "$_ANFS_EV_ROOT" ]]; then
    local d="${WSM_SPACES_HOME:-}" f i
    if [[ -z "$d" ]]; then
      _anfs_conf_dir wsm
      for f in "$REPLY/wsm.local.env" "$REPLY/wsm.env"; do
        _anfs_conf_parse "$f"
        for i in "${!_ANFS_CONF_NAMES[@]}"; do
          [[ "${_ANFS_CONF_NAMES[$i]}" == WSM_SPACES_HOME ]] && { d="${_ANFS_CONF_VALUES[$i]}"; break 2; }
        done
      done
    fi
    d="${d:-$HOME/spaces}"
    case "$d" in
      "~"|"~/"*)          d="$HOME${d#\~}" ;;
      '$HOME'|'$HOME/'*)  d="$HOME${d#\$HOME}" ;;
    esac
    _ANFS_EV_ROOT="${d%/}"
  fi
  REPLY="$_ANFS_EV_ROOT"
}

# The wsm path of a directory holding a space.yml, into REPLY ("" when it is in neither the tree
# nor a source's spaces/): below the root, or <sources>/<alias>/spaces/<rest>
_anfs_ev_path_try() {
  local d="$1" root="$2" r
  REPLY=""
  if [[ "$d" == "$root"/* ]]; then REPLY="${d#"$root"/}"; return 0; fi
  if [[ "$d" == "$ANFS_SOURCES_HOME"/*/spaces || "$d" == "$ANFS_SOURCES_HOME"/*/spaces/* ]]; then
    r="${d#"$ANFS_SOURCES_HOME"/}"
    REPLY="${r%%/*}"
    r="${r#*/spaces}"
    REPLY+="${r}"
    return 0
  fi
  return 1
}
_anfs_ev_path_of() {
  local d="$1" root c cr
  _anfs_ev_root; root="$REPLY"
  _anfs_ev_path_try "$d" "$root" && return 0
  # Through links: both sides canonical
  c=$(cd -P -- "$d" 2>/dev/null && pwd -P) || { REPLY=""; return 0; }
  cr=$(cd -P -- "$root" 2>/dev/null && pwd -P) || cr="$root"
  _anfs_ev_path_try "$c" "$cr" && return 0
  # A local source: <sources>/<alias> is a link to it
  local s sc
  for s in "$ANFS_SOURCES_HOME"/*; do
    [[ -L "$s" && -d "$s/spaces" ]] || continue
    sc=$(cd -P -- "$s/spaces" 2>/dev/null && pwd -P) || continue
    if [[ "$c" == "$sc" || "$c" == "$sc"/* ]]; then
      REPLY="${s##*/}${c#"$sc"}"
      return 0
    fi
  done
  REPLY=""
  return 0
}

# The space at or above <dir>: ANFS_EV_SPATH, ANFS_EV_SID ("" when none or invalid; ANFS_EV_SIDRC is
# anfs_space_id_read's status), ANFS_EV_SFILE. 1 when no space.yml is at or above it.
anfs_events_space_at() {
  local d="$1"
  ANFS_EV_SPATH="" ANFS_EV_SID="" ANFS_EV_SFILE="" ANFS_EV_SIDRC=1
  [[ "$d" == /* ]] || d="$PWD/$d"
  while :; do
    if [[ -f "$d/space.yml" ]]; then
      ANFS_EV_SFILE="$d/space.yml"
      _anfs_ev_path_of "${d:-/}"; ANFS_EV_SPATH="$REPLY"
      anfs_space_id_read "$ANFS_EV_SFILE" && ANFS_EV_SID="$REPLY" ANFS_EV_SIDRC=0 || ANFS_EV_SIDRC=$?
      return 0
    fi
    [[ -n "$d" && "$d" != / ]] || return 1
    d="${d%/*}"
  done
}

# The space a wsm path names (installed, else in its source): the same variables; 1 when none
anfs_events_space_named() {
  local p="${1%/}" f
  ANFS_EV_SPATH="" ANFS_EV_SID="" ANFS_EV_SFILE="" ANFS_EV_SIDRC=1
  [[ -n "$p" && "$p" != /* && "$p" != *..* ]] || return 1
  _anfs_ev_root
  for f in "$REPLY/$p/space.yml" "$ANFS_SOURCES_HOME/${p%%/*}/spaces${p#"${p%%/*}"}/space.yml"; do
    [[ -f "$f" ]] || continue
    ANFS_EV_SFILE="$f" ANFS_EV_SPATH="$p"
    anfs_space_id_read "$f" && ANFS_EV_SID="$REPLY" ANFS_EV_SIDRC=0 || ANFS_EV_SIDRC=$?
    return 0
  done
  return 1
}

# --- emit -------------------------------------------------------------------------------------

# A JSON string for <text>, quotes included, into REPLY: every control character escaped
_anfs_ev_str() {
  local LC_ALL=C s="$1" out="" c i
  s="${s//\\/\\\\}" s="${s//\"/\\\"}" s="${s//$'\n'/\\n}" s="${s//$'\t'/\\t}" s="${s//$'\r'/\\r}"
  if [[ "$s" == *[$'\x01'-$'\x1f']* ]]; then
    for (( i = 0; i < ${#s}; i++ )); do
      c="${s:i:1}"
      if [[ "$c" == [$'\x01'-$'\x1f'] ]]; then printf -v c '\\u%04x' "'$c"; fi
      out+="$c"
    done
    s="$out"
  fi
  REPLY="\"$s\""
}

# Whether <text> may be in an event; the reason into _ANFS_EV_WHY when not. Valid UTF-8, no DEL
# and no C1 control (U+007F-U+009F) anywhere; with <attr> (an attribute's name) no C0 control
# either (the spec's attr.control: data's strings may hold them, escaped). Bytes, no fork: under
# LC_ALL=C, each well-formed UTF-8 sequence is replaced by one ASCII byte, and a byte >= 0x80 left
# is one that is not UTF-8 (bash's own patterns: macOS's regcomp refuses high-byte ranges).
_anfs_ev_text_ok() {
  local LC_ALL=C s="$1" attr="${2:-}" c=$'[\x80-\xbf]'
  if [[ -n "$attr" && "$s" == *[$'\x01'-$'\x1f']* ]]; then _ANFS_EV_WHY="$attr has a control character"; return 1; fi
  if [[ "$s" == *$'\x7f'* || "$s" == *$'\xc2'[$'\x80'-$'\x9f']* ]]; then
    _ANFS_EV_WHY="${attr:-a data value} has a DEL or C1 control character"; return 1
  fi
  [[ "$s" == *[$'\x80'-$'\xff']* ]] || return 0
  s="${s//$'\xf0'[$'\x90'-$'\xbf']$c$c/u}" s="${s//[$'\xf1'-$'\xf3']$c$c$c/u}" s="${s//$'\xf4'[$'\x80'-$'\x8f']$c$c/u}"
  s="${s//$'\xe0'[$'\xa0'-$'\xbf']$c/u}" s="${s//[$'\xe1'-$'\xec'$'\xee'$'\xef']$c$c/u}" s="${s//$'\xed'[$'\x80'-$'\x9f']$c/u}"
  s="${s//[$'\xc2'-$'\xdf']$c/u}"
  [[ "$s" != *[$'\x80'-$'\xff']* ]] && return 0
  _ANFS_EV_WHY="${attr:-a data value} is not UTF-8"
  return 1
}

# Whether <actor> is the spec's: <kind>[:<name>], the kind [a-z][a-z0-9-]*, the name no space or
# control character, at most 128 bytes
_anfs_ev_actor_ok() {
  local LC_ALL=C a="$1"
  (( ${#a} <= 128 )) && [[ "$a" =~ ^[a-z][a-z0-9-]*(:.+)?$ && "$a" != *[$'\x01'-$'\x20']* ]] &&
    _anfs_ev_text_ok "$a" actor
}

# Who acts, into REPLY (see the header): the first valid of ANFS_ACTOR (else a warning), Claude
# Code, AI_AGENT, shell:$USER; shell when none is
_anfs_ev_actor() {
  local c
  if [[ -n "${ANFS_ACTOR:-}" ]]; then
    REPLY="$ANFS_ACTOR"
    _anfs_ev_actor_ok "$REPLY" && return 0
    _anfs_ev_warn "ANFS_ACTOR=$(LC_ALL=C; printf '%q' "$ANFS_ACTOR") is not <kind>[:<name>]: the actor is detected instead"
  fi
  for c in claude agent shell; do
    case "$c" in
      claude) [[ "${CLAUDECODE:-}" == 1 ]] || continue
              REPLY=claude
              [[ -z "${CLAUDE_CODE_SESSION_ID:-}" ]] || REPLY+=":${CLAUDE_CODE_SESSION_ID:0:8}" ;;
      agent)  [[ -n "${AI_AGENT:-}" ]] || continue; REPLY="${AI_AGENT%%_*}" ;;
      shell)  REPLY="shell:${USER:-${LOGNAME:-unknown}}" ;;
    esac
    _anfs_ev_actor_ok "$REPLY" && return 0
  done
  REPLY=shell
}

# A UUIDv7 (RFC 9562) for <ms> into REPLY: 48 bits of time, version 7, 12 random bits, variant
# 10, 62 random bits. SRANDOM is the kernel's CSPRNG (getrandom/arc4random), with no fork.
anfs_uuid7() {
  local ts
  printf -v ts '%012x' "$1"
  printf -v REPLY '%s-%s-7%03x-%04x-%04x%08x' "${ts:0:8}" "${ts:8:4}" \
    $(( SRANDOM & 0xfff )) $(( 0x8000 | (SRANDOM & 0x3fff) )) $(( SRANDOM & 0xffff )) "$SRANDOM"
}

# THE ENVELOPE, built here and only here, into REPLY: a CloudEvents 1.0 event in the structured JSON
# format, our profile version 1 (anfsv). Readers go through _anfs_ev_parse. Arguments: <id> <time>
# <space id> <space path> <short type> <subject> <actor> <as: "<space id> <role>" or ""> <data: the
# members, already JSON>. Empty is absent: an optional attribute with no value is left out. data
# is last, which the bash reader relies on.
_anfs_ev_envelope() {
  local id="$1" t="$2" sid="$3" spath="$4" type="$5" subject="$6" actor="$7" as="$8" data="$9" l
  l="{\"specversion\":\"1.0\",\"id\":\"$id\",\"source\":\""
  if [[ -n "$sid" ]]; then l+="/anfs/spaces/$sid\""; else l+="/anfs/host\""; fi
  l+=",\"type\":\"io.anfs.$type\""
  if [[ -n "$subject" ]]; then _anfs_ev_str "$subject"; l+=",\"subject\":$REPLY"; fi
  l+=",\"time\":\"$t\",\"datacontenttype\":\"application/json\""
  _anfs_ev_str "$actor"; l+=",\"actor\":$REPLY"
  if [[ -n "$as" ]]; then
    [[ -z "${as% *}" ]] || l+=",\"actorspace\":\"${as% *}\""
    l+=",\"actorrole\":\"${as##* }\""
  fi
  if [[ -n "$spath" ]]; then _anfs_ev_str "$spath"; l+=",\"spacepath\":$REPLY"; fi
  REPLY="$l,\"anfsv\":1,\"data\":{$data}}"
}

# Warn without needing log.sh's state
_anfs_ev_warn() {
  if declare -F anfs_warn >/dev/null; then anfs_warn "$*"; else echo "${CLI_TOOL:-anfs}: $*" >&2; fi
}

anfs_emit() {
  [[ "${ANFS_EVENTS:-on}" != off ]] || return 0
  _anfs_emit "$@" || _anfs_ev_warn "event ${1:-?} not recorded${_ANFS_EV_WHY:+: $_ANFS_EV_WHY}"
  return 0
}

_anfs_emit() {
  local at="" host=false type subject sid="" spath="" actor as="" data="" kv k v line dir us ms t file n
  _ANFS_EV_WHY=""
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --host) host=true; shift ;;
      --at) at="${2:-}"; shift 2 || return 1 ;;
      *) _ANFS_EV_WHY="unknown option $1"; return 1 ;;
    esac
  done
  [[ $# -ge 2 ]] || { _ANFS_EV_WHY="usage: anfs_emit [--at DIR|--host] <type> <subject> [key=value...]"; return 1; }
  type="$1" subject="$2"
  shift 2
  [[ "$type" =~ ^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$ ]] || { _ANFS_EV_WHY="'$type' is not <noun>.<verb>"; return 1; }
  # io.anfs.cnfs.* would read as cnfs's short type (the spec, "Types and namespaces")
  [[ " $ANFS_EVENT_NAMESPACES " != *" ${type%%.*} "* ]] ||
    { _ANFS_EV_WHY="'$type' starts with ${type%%.*}, another layer's namespace"; return 1; }
  if [[ -n "$subject" ]]; then _anfs_ev_text_ok "$subject" subject || return 1; fi

  # The space
  if ! $host; then
    local found=false
    if [[ -n "$at" ]]; then anfs_events_space_at "$at" && found=true
    elif [[ -n "${ANFS_SPACE:-}" ]]; then
      if anfs_events_space_named "$ANFS_SPACE"; then found=true
      else _anfs_ev_warn "ANFS_SPACE=$ANFS_SPACE names no space: the event goes to the host scope"
      fi
    else anfs_events_space_at "$PWD" && found=true
    fi
    if $found; then
      spath="$ANFS_EV_SPATH" sid="$ANFS_EV_SID"
      if [[ -n "$spath" ]]; then _anfs_ev_text_ok "$spath" spacepath || return 1; fi
      [[ -n "$sid" ]] || _anfs_ev_warn "the space ${spath:-at $(anfs_display "${ANFS_EV_SFILE%/*}")} has no id (wsm id --new ${spath:-<space>}): the event goes to the host scope"
    fi
  fi

  # Who, and as what
  _anfs_ev_actor; actor="$REPLY"
  if [[ -n "${ANFS_AS:-}" ]]; then
    local role="${ANFS_AS##*/}" asp="${ANFS_AS%/*}" asid=""
    if [[ "$ANFS_AS" != */* || ! "$role" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
      _anfs_ev_warn "ANFS_AS=$ANFS_AS is not <space path>/<role>: recorded without it"
    else
      if anfs_events_space_named "$asp" && [[ -n "$ANFS_EV_SID" ]]; then asid="$ANFS_EV_SID"
      else _anfs_ev_warn "ANFS_AS: no space with an id at $asp: the role is recorded without actorspace"
      fi
      as="$asid $role"
    fi
  fi

  # What changed
  for kv in "$@"; do
    k="${kv%%=*}" v="${kv#*=}"
    [[ "$kv" == *=* && "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { _ANFS_EV_WHY="'$kv' is not key=value"; return 1; }
    _anfs_ev_text_ok "$v" || { _ANFS_EV_WHY="data.$k: ${_ANFS_EV_WHY#a data value }"; return 1; }
    _anfs_ev_str "$v"
    data+="${data:+,}\"$k\":$REPLY"
  done

  # When: milliseconds (a test may fix them)
  if [[ -n "${ANFS_EVENTS_TEST_MS:-}" ]]; then ms="$ANFS_EVENTS_TEST_MS"
  else us="${EPOCHREALTIME//[!0-9]/}"; ms=$(( 10#$us / 1000 ))
  fi
  anfs_uuid7 "$ms"; local id="$REPLY"
  TZ=UTC printf -v t '%(%Y-%m-%dT%H:%M:%S)T' $(( ms / 1000 ))
  printf -v t '%s.%03dZ' "$t" $(( ms % 1000 ))

  _anfs_ev_envelope "$id" "$t" "$sid" "$spath" "$type" "$subject" "$actor" "$as" "$data"
  line="$REPLY"

  local max=$ANFS_EVENT_MAX root="$ANFS_EVENTS_HOME"
  if [[ -n "${ANFS_EVENTS_SPOOL:-}" ]]; then
    root="${ANFS_EVENTS_SPOOL%/}" max=$(( ANFS_EVENT_MAX - ANFS_EVENT_STAMP_RESERVE ))
  fi
  n=$(LC_ALL=C; printf '%s' "${#line}")
  if (( n + 1 > max )); then
    _ANFS_EV_WHY="$(( n + 1 )) bytes, over $max: keep data small"
    return 1
  fi
  dir="$root/${sid:-host}"
  file="$dir/${t:0:7}.jsonl"
  if [[ ! -d "$dir" ]]; then
    mkdir -p -- "$dir" 2>/dev/null || { _ANFS_EV_WHY="cannot make $(anfs_display "$dir")"; return 1; }
  fi
  # One write(2), O_APPEND
  cat >> "$file" <<< "$line" 2>/dev/null || { _ANFS_EV_WHY="cannot append to $(anfs_display "$file")"; return 1; }
}

# --- events ls ----------------------------------------------------------------------------------

# Declare `<tool> events list` (alias ls) with the shared options; extra cli_cmd words (anfs's
# --all) go on the end
anfs_events_cli() {
  local what="$1"
  shift
  cli_group events "The event log: what happened, in which space, by whom"
  cli_cmd "events list" "The events of $what, oldest first: EVENT (time, type), SUBJECT,
SPACE, BY. -f keeps printing new ones; -f --once ends at the
first match (how an agent waits: wsm events ls -f --once
--type report.closed --subject <report id>)" --alias ls \
    --opt "--type EVENT-TYPE: Only these types (a glob; short, report.*, or full, io.anfs.report.*)" \
    --opt "--subject SUBJECT: Only events about this (exact)" \
    --opt "--since WHEN: Only since then: 30s, 10m, 2h, 7d, or YYYY-MM-DD[THH:MM[:SS]] (UTC)" \
    --opt "--by ACTOR: Only events by this actor (a glob: claude:*)" \
    --opt "--after ID: Only events after this event id" \
    --opt "-f --follow: Keep printing new events as they are appended" \
    --opt "--once: With -f, print the first match and exit 0" \
    "$@" --arg "[spec...]"
}

complete_event_type() {
  local t
  local -A seen=()
  for t in $ANFS_EVENT_TYPES; do
    printf '%s\n' "$t"
    [[ -n "${seen[${t%%.*}]:-}" ]] || { seen[${t%%.*}]=1; printf '%s.*\n' "${t%%.*}"; }
  done
}

# THE ACCESSOR: an event line's attributes into EV_* (ID TIME SID SPATH TYPE (short: without
# io.anfs. for anfs's types, without io. for another layer's) FULLTYPE SUBJECT ACTOR ROLE); 1 when
# it is not one of ours (specversion 1.0, anfsv 1). Everything that reads the log goes through
# this. Any layer's event: SID is the space id of any /<layer>/spaces/<id>[/...] source. The
# attributes are looked for before "data", which the spec's canonical form puts last (whatever
# data holds: another layer's is any JSON object); a quote inside a string is always escaped, so
# `,"name":"` can only be an attribute.
_anfs_ev_unq() {
  local s="$1"
  s="${s//\\\"/\"}" s="${s//\\n/ }" s="${s//\\t/ }" s="${s//\\\\/\\}"
  REPLY="$s"
}
_anfs_ev_attr() {
  local re='[{,]"'"$1"'":"(([^"\\]|\\.)*)"'
  REPLY=""
  [[ "$2" =~ $re ]] || return 0
  _anfs_ev_unq "${BASH_REMATCH[1]}"
}
_anfs_ev_parse() {
  local head="${1%%,\"data\":*}"
  [[ "$1" == "{"*"}" && "$head" == *'"specversion":"1.0"'* && "$head" == *'"anfsv":1'* ]] || return 1
  _anfs_ev_attr id "$head"; EV_ID="$REPLY"
  [[ -n "$EV_ID" ]] || return 1
  _anfs_ev_attr time "$head"; EV_TIME="$REPLY"
  _anfs_ev_attr type "$head"; EV_FULLTYPE="$REPLY" EV_TYPE="$REPLY"
  case "$REPLY" in io.anfs.*) EV_TYPE="${REPLY#io.anfs.}" ;; io.*) EV_TYPE="${REPLY#io.}" ;; esac
  _anfs_ev_attr source "$head"; EV_SID=""
  [[ ! "$REPLY" =~ ^/[a-z][a-z0-9-]*/spaces/([a-z0-9]{10})(/|$) ]] || EV_SID="${BASH_REMATCH[1]}"
  _anfs_ev_attr subject "$head"; EV_SUBJECT="$REPLY"
  _anfs_ev_attr actor "$head"; EV_ACTOR="$REPLY"
  _anfs_ev_attr actorrole "$head"; EV_ROLE="$REPLY"
  _anfs_ev_attr spacepath "$head"; EV_SPATH="$REPLY"
  return 0
}

# Whether a line passes the filters (_EVF_*)
_anfs_ev_match() {
  _anfs_ev_parse "$1" || return 1
  [[ -z "$_EVF_TYPE" || "$EV_FULLTYPE" == $_EVF_TYPE || "$EV_TYPE" == $_EVF_TYPE ]] || return 1
  [[ -z "$_EVF_SUBJECT" || "$EV_SUBJECT" == "$_EVF_SUBJECT" ]] || return 1
  [[ -z "$_EVF_BY" || "$EV_ACTOR" == $_EVF_BY ]] || return 1
  [[ -z "$_EVF_SINCE" || ! "$EV_TIME" < "$_EVF_SINCE" ]] || return 1
  [[ -z "$_EVF_AFTER" || "$EV_ID" > "$_EVF_AFTER" ]] || return 1
}

# One matching line as it is printed
_anfs_ev_out() {
  if $_EVF_JSON; then printf '%s\n' "$1"; return; fi
  local space="${EV_SPATH:-$EV_SID}"
  [[ -n "$EV_SID$EV_SPATH" ]] || space=host
  anfs_row "${EV_TIME:0:19}Z $EV_TYPE" "$EV_SUBJECT" "$space" "$EV_ACTOR${EV_ROLE:+ as $EV_ROLE}"
}

# Print rows (the non-follow form goes through anfs_table, aligned on a terminal)
_anfs_ev_print() {
  if $_EVF_JSON; then printf '%s' "$1"; return; fi
  printf '%s' "$1" | ANFS_TABLE="${_EVF_FORM:-${ANFS_TABLE:-}}" anfs_table "EVENT SUBJECT SPACE BY" "event subject space by"
}

# A scope directory's month files, oldest month first, into _EV_FILES (<YYYY-MM>.jsonl and the
# recorder's <YYYY-MM>.bus.jsonl), and its newest month into _EV_MONTH ("" when none)
_anfs_ev_files() {
  local f n
  _EV_FILES=() _EV_MONTH=""
  for f in "$1"/*.jsonl; do
    n="${f##*/}"
    [[ -f "$f" && "$n" =~ ^[0-9]{4}-[0-9]{2}(\.bus)?\.jsonl$ ]] || continue
    _EV_FILES+=("$f")
    [[ "${n:0:7}" < "$_EV_MONTH" ]] || _EV_MONTH="${n:0:7}"
  done
  return 0
}

# The scope directories: ANFS_EVENTS_DIRS, or with ANFS_EVENTS_EVERY every one under the log
ANFS_EVENTS_DIRS=() ANFS_EVENTS_EVERY=false
_anfs_ev_scopes() {
  local d
  _EV_SCOPES=()
  if $ANFS_EVENTS_EVERY; then
    for d in "$ANFS_EVENTS_HOME"/*/; do [[ -d "$d" ]] && _EV_SCOPES+=("${d%/}"); done
  else
    _EV_SCOPES=(${ANFS_EVENTS_DIRS[@]+"${ANFS_EVENTS_DIRS[@]}"})
  fi
  return 0
}

# A sleep of a second with no process: read -t on a FIFO only we hold. A read that returns early
# (no FIFO) falls back to sleep 1, so the loop can never spin.
_EV_SLEEP_FD=""
_anfs_ev_tick() {
  local t0="${EPOCHREALTIME//[!0-9]/}" t1 d
  if [[ -z "$_EV_SLEEP_FD" ]]; then
    if d=$(mktemp -d "${TMPDIR:-/tmp}/anfs-events.XXXXXX") && mkfifo "$d/tick" && exec {_EV_SLEEP_FD}<>"$d/tick"; then :
    else _EV_SLEEP_FD=none
    fi
    [[ -z "${d:-}" ]] || rm -rf -- "$d"
  fi
  [[ "$_EV_SLEEP_FD" == none ]] || read -r -t 1 -u "$_EV_SLEEP_FD" _ 2>/dev/null || true
  t1="${EPOCHREALTIME//[!0-9]/}"
  (( 10#$t1 - 10#$t0 >= 900000 )) || sleep 1
}

# `events ls`, over the scopes the caller set (ANFS_EVENTS_DIRS, or ANFS_EVENTS_EVERY=true)
anfs_events_ls() {
  local follow=${CLI_OPT[follow]:-false} once=${CLI_OPT[once]:-false} since="${CLI_OPT[since]:-}"
  local d f files name line out="" nfiles=0 now
  local -a lines=() matched=()
  _EVF_TYPE="${CLI_OPT[type]:-}" _EVF_SUBJECT="${CLI_OPT[subject]:-}" _EVF_BY="${CLI_OPT[by]:-}"
  _EVF_AFTER="${CLI_OPT[after]:-}" _EVF_SINCE="" _EVF_JSON=false _EVF_FORM=""
  anfs_json_on && _EVF_JSON=true
  $follow && _EVF_FORM=tsv
  ! $once || $follow || cli_usage_err "--once goes with -f"
  [[ -z "$_EVF_AFTER" || "$_EVF_AFTER" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    cli_usage_err "--after takes an event id (a UUID)"
  if [[ -n "$since" ]]; then
    if [[ "$since" =~ ^([0-9]+)([smhd])$ ]]; then
      local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}" m=1
      case "$u" in m) m=60 ;; h) m=3600 ;; d) m=86400 ;; esac
      TZ=UTC printf -v _EVF_SINCE '%(%Y-%m-%dT%H:%M:%S)T' $(( EPOCHSECONDS - 10#$n * m ))
    elif [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2})?)?Z?$ ]]; then
      _EVF_SINCE="${since%Z}"
    else
      cli_usage_err "--since takes 30s, 10m, 2h, 7d, or YYYY-MM-DD[THH:MM[:SS]]"
    fi
  fi

  # The backlog: every month file (from --since's month), both of a month (the spool's and the
  # recorder's .bus.jsonl), oldest first. With -f, each scope's newest month's files are read
  # through descriptors kept open, so following carries on where this ends.
  declare -gA _EV_CUR=() _EV_FD=() _EV_PEND=()
  _anfs_ev_scopes
  for d in ${_EV_SCOPES[@]+"${_EV_SCOPES[@]}"}; do
    _anfs_ev_files "$d"
    (( ${#_EV_FILES[@]} )) || continue
    ! $follow || _EV_CUR[$d]="$_EV_MONTH"
    for f in "${_EV_FILES[@]}"; do
      name="${f##*/}"
      [[ -z "$_EVF_SINCE" || ! "${name:0:7}" < "${_EVF_SINCE:0:7}" ]] || continue
      if $follow && [[ "${name:0:7}" == "$_EV_MONTH" ]]; then
        exec {_EV_FD[$f]}<"$f"
        _EV_PEND[$f]=""
        mapfile -t -u "${_EV_FD[$f]}" lines
      else
        mapfile -t lines < "$f"
      fi
      nfiles=$(( nfiles + 1 ))
      for line in ${lines[@]+"${lines[@]}"}; do
        _anfs_ev_match "$line" && matched+=("$EV_ID$ANFS_US$line")
      done
    done
  done
  # By id (a UUIDv7: by time), through the parser, not the line's layout
  if (( nfiles > 1 && ${#matched[@]} > 1 )); then
    mapfile -t matched < <(printf '%s\n' "${matched[@]}" | LC_ALL=C sort -t"$ANFS_US" -k1,1)
  fi
  matched=(${matched[@]+"${matched[@]#*"$ANFS_US"}"})
  if $once && (( ${#matched[@]} )); then
    _anfs_ev_parse "${matched[0]}"
    _anfs_ev_print "$(_anfs_ev_out "${matched[0]}")"$'\n'
    return 0
  fi
  for line in ${matched[@]+"${matched[@]}"}; do
    _anfs_ev_parse "$line"
    out+="$(_anfs_ev_out "$line")"$'\n'
  done
  [[ -z "$out" ]] || _anfs_ev_print "$out"
  $follow || return 0

  anfs_events_follow _anfs_ev_ls_line
}

# A followed line, for events ls: printed when it matches; 0 (stop) with --once
_anfs_ev_ls_line() {
  _anfs_ev_match "$1" || return 1
  _anfs_ev_print "$(_anfs_ev_out "$1")"$'\n'
  ${CLI_OPT[once]:-false}
}

# Position on each scope's newest month's files at their ends, so anfs_events_follow reads only what is
# appended from now (anfs report wait: the state is read after this, so nothing falls between)
anfs_events_follow_init() {
  local d f
  local -a files got
  declare -gA _EV_CUR=() _EV_FD=() _EV_PEND=()
  _anfs_ev_scopes
  for d in ${_EV_SCOPES[@]+"${_EV_SCOPES[@]}"}; do
    _anfs_ev_files "$d"
    [[ -n "$_EV_MONTH" ]] || continue
    _EV_CUR[$d]="$_EV_MONTH"
    for f in "$d/$_EV_MONTH.jsonl" "$d/$_EV_MONTH.bus.jsonl"; do
      [[ -f "$f" ]] || continue
      exec {_EV_FD[$f]}<"$f"
      _EV_PEND[$f]=""
      mapfile -u "${_EV_FD[$f]}" got
      (( ${#got[@]} )) && [[ "${got[-1]}" != *$'\n' ]] && _EV_PEND[$f]="${got[-1]}"
    done
  done
  return 0
}

# Follow the scopes (ANFS_EVENTS_DIRS, or every one with ANFS_EVENTS_EVERY=true) from where
# anfs_events_ls's backlog or anfs_events_follow_init left each: a tick a second, the lines each
# scope's newest month's files (its .jsonl and .bus.jsonl) gained handed to <fn> one by one; a new
# month's file, a new scope or a file that did not exist is read from its start. 0 when <fn> returns 0 for a line (stop), 1
# when the deadline (epoch seconds) passes. The tick sleeps (_anfs_ev_tick): no loop spins.
# Usage: anfs_events_follow <fn> [deadline]
anfs_events_follow() {
  local fn="$1" deadline="${2:-}" d f
  while :; do
    [[ -z "$deadline" ]] || (( EPOCHSECONDS < deadline )) || return 1
    _anfs_ev_tick
    _anfs_ev_scopes
    for d in ${_EV_SCOPES[@]+"${_EV_SCOPES[@]}"}; do
      _anfs_ev_files "$d"
      [[ -n "$_EV_MONTH" ]] || continue
      if [[ "${_EV_CUR[$d]:-}" != "$_EV_MONTH" ]]; then
        # a newer month: what the old month's files gained first, then they are closed
        if [[ -n "${_EV_CUR[$d]:-}" ]]; then
          for f in "$d/${_EV_CUR[$d]}.jsonl" "$d/${_EV_CUR[$d]}.bus.jsonl"; do
            [[ -n "${_EV_FD[$f]:-}" ]] || continue
            _anfs_ev_drain "$f" "$fn" && return 0
            exec {_EV_FD[$f]}<&-
            unset '_EV_FD[$f]' '_EV_PEND[$f]'
          done
        fi
        _EV_CUR[$d]="$_EV_MONTH"
      fi
      for f in "$d/$_EV_MONTH.jsonl" "$d/$_EV_MONTH.bus.jsonl"; do
        [[ -f "$f" ]] || continue
        if [[ -z "${_EV_FD[$f]:-}" ]]; then
          exec {_EV_FD[$f]}<"$f"
          _EV_PEND[$f]=""
        fi
        _anfs_ev_drain "$f" "$fn" && return 0
      done
    done
  done
}

# Hand what a followed file gained to <fn>, line by line; 0 when <fn> said stop
_anfs_ev_drain() {
  local f="$1" fn="$2" el line
  local -a got=()
  mapfile -u "${_EV_FD[$f]}" got
  for el in ${got[@]+"${got[@]}"}; do
    if [[ "$el" != *$'\n' ]]; then _EV_PEND[$f]+="$el"; continue; fi
    line="${_EV_PEND[$f]:-}${el%$'\n'}"
    _EV_PEND[$f]=""
    "$fn" "$line" && return 0
  done
  return 1
}
