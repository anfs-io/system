#!/usr/bin/env bash
# anfs: callbacks — a tool tells whoever registered that something changed, without knowing them
#
# A tool EMITS an event by calling anfs_callbacks_run at the end of a command. A LISTENER is
# whatever registered a handler with that tool. ppm emits install/remove with the packages a run
# touched (core/psm listens, to sync skills); wsm emits install/remove with the levels.
#
#   anfs_callback_register   <tool> <name> <handler>   add or replace <name>'s registration
#   anfs_callback_unregister <tool> <name>
#   anfs_callbacks_run       <tool> <event> <arg>...   emit: call every listener of <tool>
#   anfs_callbacks_ls        [tool]                    tool, name, state, handler (tab-separated)
#
# Registrations live in $ANFS_STATE_HOME/callbacks/<tool>.yml as `name: handler`, one file per
# emitting tool. They are anfs's, not the tool's, because a registration belongs to the listener:
# it lasts as long as the listener is installed, so a tool's own implode (which deletes that
# tool's state, and leaves both it and its listeners installed) must not drop it.
#
# A handler is a command line: it runs as `<handler> <event> <arg>...`. A tool whose handlers are
# something else defines <tool>_callback_invoke <name> <handler> <event> <arg>... to run one
# (ppm's are functions of the registering package's install.sh), and may define
# <tool>_callback_state <name> <handler> to say `ok` or `stale` for anfs_callbacks_ls.
#
# Each handler runs in a subshell. One that fails is reported and the rest still run.
#
# A listener in another package registers from its install.sh, which ppm runs with this loaded:
#
#   post_install() { anfs_callback_register wsm "$PPM_CURRENT_PACKAGE" "pvm link apply --event"; }
#   post_remove()  { anfs_callback_unregister wsm "$PPM_CURRENT_PACKAGE"; }
#
# Requires log.sh. Functions only; written for the bash floor (5.2, see bash.sh).

# Usage: anfs_callbacks_file <tool>   Prints the registrations file
anfs_callbacks_file() {
  printf '%s/callbacks/%s.yml\n' "${ANFS_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/anfs}" "$1"
}

anfs_callback_register() {
  local tool="${1:-}" name="${2:-}" handler="${3:-}" file
  [[ -n "$tool" && -n "$name" && -n "$handler" ]] ||
    { anfs_warn "anfs_callback_register needs <tool> <name> <handler>"; return 1; }
  file=$(anfs_callbacks_file "$tool")
  mkdir -p "${file%/*}"
  [[ -s "$file" ]] || echo '{}' > "$file"
  N="$name" H="$handler" yq -i '.[strenv(N)] = strenv(H)' "$file"
  anfs_debug "callbacks: $name registered with $tool: $handler"
}

anfs_callback_unregister() {
  local tool="${1:-}" name="${2:-}" file
  [[ -n "$tool" && -n "$name" ]] || return 0
  file=$(anfs_callbacks_file "$tool")
  [[ -f "$file" ]] || return 0
  N="$name" yq -i 'del(.[strenv(N)])' "$file"
  anfs_debug "callbacks: $name unregistered from $tool"
}

# The default: the handler is a command line. Returns 127 when its command is not on PATH.
_anfs_callback_invoke() {
  local name="$1" handler="$2"
  shift 2
  local -a words
  read -ra words <<< "$handler"
  if ! command -v -- "${words[0]:-}" >/dev/null 2>&1; then
    anfs_debug "callbacks: $name is stale: '${words[0]:-}' is not on PATH"
    return 127
  fi
  eval "$handler"' "$@"'
}

_anfs_callback_state() {
  local -a words
  read -ra words <<< "$2"
  command -v -- "${words[0]:-}" >/dev/null 2>&1 && echo ok || echo stale
}

anfs_callbacks_run() {
  local tool="${1:-}" event="${2:-}" file name handler invoke rc
  [[ -n "$tool" && -n "$event" ]] || return 0
  shift 2
  [[ $# -gt 0 ]] || return 0
  file=$(anfs_callbacks_file "$tool")
  [[ -s "$file" ]] || return 0
  invoke=_anfs_callback_invoke
  ! declare -F "${tool}_callback_invoke" >/dev/null || invoke="${tool}_callback_invoke"

  # fd 3 keeps a handler that reads stdin from consuming the registrations
  while IFS=$'\t' read -r -u 3 name handler; do
    [[ -n "$name" && -n "$handler" ]] || continue
    anfs_debug "callbacks: $tool $event -> $name ($# arg(s)): $handler"
    rc=0
    ( "$invoke" "$name" "$handler" "$event" "$@" ) || rc=$?
    case "$rc" in
      0) ;;
      127) [[ "$invoke" != _anfs_callback_invoke ]] && anfs_warn "callback of $name for $tool $event failed (exit 127)" ;;
      *) anfs_warn "callback of $name for $tool $event failed (exit $rc): $handler" ;;
    esac
  done 3< <(yq -r 'to_entries | .[] | .key + "\t" + .value' "$file" 2>/dev/null)
  return 0
}

# Every registration, of <tool> or of every tool that has any
anfs_callbacks_ls() {
  local tool file name handler state
  local -a tools=()
  if [[ -n "${1:-}" ]]; then
    tools=("$1")
  else
    file=$(anfs_callbacks_file x)
    for file in "${file%/*}"/*.yml; do
      [[ -f "$file" ]] || continue
      tool="${file##*/}"
      tools+=("${tool%.yml}")
    done
  fi
  for tool in "${tools[@]}"; do
    file=$(anfs_callbacks_file "$tool")
    [[ -s "$file" ]] || continue
    while IFS=$'\t' read -r name handler; do
      [[ -n "$name" ]] || continue
      if declare -F "${tool}_callback_state" >/dev/null; then
        state=$("${tool}_callback_state" "$name" "$handler")
      else
        state=$(_anfs_callback_state "$name" "$handler")
      fi
      printf '%s\t%s\t%s\t%s\n' "$tool" "$name" "$state" "$handler"
    done < <(yq -r 'to_entries | .[] | .key + "\t" + .value' "$file" 2>/dev/null)
  done
}
