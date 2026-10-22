#!/usr/bin/env bash
# pcm library: the provision and deprovision commands, a service's hooks for a consumer that is
# not a pcm definition (a Rails app run on the host, partitia's `pt services`)
# Sourced by ~/.local/bin/pcm; defines functions only.
#
#   pcm provision   <service> [--as NAME] [key=value...]   (--json: one object)
#   pcm deprovision <service> [--as NAME] [key=value...]
#
# The hook runs as `up` and `remove` run it for a dependent (hook_run, deps.sh): from the service's
# directory under varlock, with PCM_SERVICE, PCM_PROJECT and PCM_DEPENDENT (NAME, default
# `external`), and the key=value settings as its arguments, as a dependent's depends_on map gives
# them. provision starts the service first as `pcm up` does when it is not running, and waits for
# it to be healthy; deprovision never starts it. provision's stdout is only the hook's KEY=VALUE
# lines. They are secrets: nothing logs them; the log names the keys.

PCM_EXTERNAL_DEPENDENT=external

# The checks both commands make: the service, the hook, --as and the settings. Leaves the id in
# HOOK_ID, the dependent's name in HOOK_AS and the settings in HOOK_SETTINGS.
_hook_command_args() {
  local hook_name="$1" arg
  shift
  HOOK_ID=$(canon "${1:-}") || cli_usage_err "unknown service '${1:-}' (see: pcm list)"
  shift
  HOOK_AS="${CLI_OPT[as]:-$PCM_EXTERNAL_DEPENDENT}"
  [[ "$HOOK_AS" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] ||
    cli_usage_err "--as is a name of letters, digits and ._/:@- (e.g. partitia/shop), not '$HOOK_AS'"
  HOOK_SETTINGS=()
  for arg in "$@"; do
    [[ "$arg" =~ ^[A-Za-z_][A-Za-z0-9_.-]*= ]] || cli_usage_err "not a key=value setting: '$arg'"
    HOOK_SETTINGS+=("$arg")
  done
  if ! has_hook "$hook_name" "$HOOK_ID"; then
    anfs_warn "$HOOK_ID has no $hook_name hook (nothing to $hook_name for $HOOK_AS)"
    return 1
  fi
}

cmd_provision() {
  local output pairs line keys=""
  _hook_command_args provision "$@" || return 1

  if [[ -n "$(project_containers "$HOOK_ID")" ]]; then
    check_not_running_elsewhere "$HOOK_ID" || return 1
  else
    anfs_warn "starting $HOOK_ID (to provision for $HOOK_AS)"
    compose_command up "$HOOK_ID" >&2 || { anfs_warn "could not start $HOOK_ID"; return 1; }
  fi
  wait_healthy "$HOOK_ID" || return 1

  PROVISIONED=()
  output=$(hook_run provision "$HOOK_ID" "$HOOK_AS" ${HOOK_SETTINGS[@]+"${HOOK_SETTINGS[@]}"}) || {
    anfs_warn "provisioning $HOOK_ID for $HOOK_AS failed"
    return 1
  }
  pairs=$(hook_pairs <<< "$output")
  while IFS= read -r line; do
    [[ -n "$line" ]] && keys+=" ${line%%=*}"
  done <<< "$pairs"
  # The key names only: the values are secrets, and anfs_warn logs
  anfs_warn "provisioned $HOOK_ID for $HOOK_AS:${keys:- (it printed no KEY=VALUE)}"

  if anfs_json_on; then
    local -a kv=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && kv+=("${line%%=*}" "${line#*=}")
    done <<< "$pairs"
    if (( ${#kv[@]} )); then anfs_result "${kv[@]}"; else echo '{}'; fi
  elif [[ -n "$pairs" ]]; then
    printf '%s\n' "$pairs"
  fi
}

cmd_deprovision() {
  _hook_command_args deprovision "$@" || return 1

  if [[ -z "$(project_containers "$HOOK_ID")" ]]; then
    anfs_warn "$HOOK_ID is not running; what it provisioned for $HOOK_AS${HOOK_SETTINGS[*]+ (${HOOK_SETTINGS[*]})} is left in place"
    return 1
  fi
  check_not_running_elsewhere "$HOOK_ID" || return 1

  PROVISIONED=()
  hook_run deprovision "$HOOK_ID" "$HOOK_AS" ${HOOK_SETTINGS[@]+"${HOOK_SETTINGS[@]}"} >&2 || {
    anfs_warn "deprovisioning $HOOK_ID for $HOOK_AS failed"
    return 1
  }
  anfs_warn "deprovisioned $HOOK_ID for $HOOK_AS"
}
