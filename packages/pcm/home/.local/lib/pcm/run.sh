#!/usr/bin/env bash
# pcm library: the run command, a one-off container from a service's definition
# Sourced by ~/.local/bin/pcm; defines functions only.
#
# `pcm run <service> [-s NAME] [-u USER] [--keep] [--] [cmd...]` is `podman compose run` with what
# `pcm up` gives the service: its compose.yml and pcm's override (the one-off's own file, see
# compose_flags: labelled io.pcm.oneoff, no ingress labels, no network alias), its env (the schema,
# local.env, state.env, fnox, what its dependencies' provision hooks print). It is named
# <name>-run-<hex> and removed on exit unless --keep. The commands that mean the service's own
# containers leave one-offs out (label!=io.pcm.oneoff); ps shows them, show names the kept ones,
# remove and implode delete them. A stock image has no `pcm run`: `podman run --rm <image>`.
#
# What it starts first is what the definition says it requires, as up starts it: x-pcm.depends_on
# (started, waited for, provisioned) but not the implicit proxy and edges of an ingress service (a
# one-off gets no route), and the compose service's own depends_on, started through the service's
# ordinary override when not running. The one-off itself runs --no-deps.

# The one-offs of service $1's name, running or not
oneoff_containers() {
  podman ps -a --filter "label=$PCM_LABEL_NAME=$(svc_name "$1")" --filter "label=$PCM_LABEL_ONEOFF" \
    --format '{{.Names}}'
}

# Compose services of service $1
_run_compose_services() {
  yq eval '.services // {} | keys | .[]' "$(compose_file "$1")"
}

# What compose service $2 of service $1 lists in its depends_on (list or map form)
_run_compose_deps() {
  yq eval ".services[\"$2\"].depends_on | select(. != null) |
    ((select(tag == \"!!seq\") | .[]), (select(tag == \"!!map\") | keys | .[]))" "$(compose_file "$1")"
}

# True when compose service $2 of service $1 has a running container of its own (not a one-off)
_run_sibling_running() {
  [[ -n "$(podman ps --filter "label=$PCM_LABEL_NAME=$(svc_name "$1")" \
    --filter "label=com.docker.compose.service=$2" --filter "label!=$PCM_LABEL_ONEOFF" \
    --format '{{.Names}}')" ]]
}

cmd_run() {
  local id csvc="${CLI_OPT[service]:-}" user="${CLI_OPT[user]:-}" keep=${CLI_OPT[keep]:-false}
  id=$(canon "${1:-}") || cli_usage_err "unknown service '${1:-}' (see: pcm list)"
  shift
  [[ "${1:-}" != -- ]] || shift

  local -a csvcs=()
  mapfile -t csvcs < <(_run_compose_services "$id")
  if [[ -z "$csvc" ]]; then
    (( ${#csvcs[@]} == 1 )) || cli_usage_err "$id has several compose services; pick one with -s: ${csvcs[*]}"
    csvc="${csvcs[0]}"
  elif ! in_list "$csvc" ${csvcs[@]+"${csvcs[@]}"}; then
    cli_usage_err "$id has no compose service '$csvc' (it has: ${csvcs[*]})"
  fi

  pcm_podman_ready || return 1
  # Checked as up checks: the service and what it requires, with what those require
  local spec dep
  CLOSURE=("$id")
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    if dep=$(canon "$spec"); then dep_closure "$dep"; fi
  done < <(declared_deps "$id")
  export_podman_socket "${CLOSURE[@]}"
  if ! validate_services "${CLOSURE[@]}"; then
    anfs_warn "not running $id: validation failed with $VALIDATE_ERRORS error(s)"
    return 1
  fi
  check_memory "${CLOSURE[@]}" || return 1
  check_not_running_elsewhere "$id" || return 1
  local key reason
  while IFS='|' read -r key reason; do
    [[ -n "$key" ]] && anfs_warn "$id runs with $key: $reason"
  done < <(declared_privileges "$id")

  PROVISIONED=()
  start_deps "$id" "" declared || return 1
  ensure_mount_dirs "$id"

  # The compose service's siblings it depends on, as pcm up makes them
  local -a missing=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    _run_sibling_running "$id" "$dep" || missing+=("$dep")
  done < <(_run_compose_deps "$id" "$csvc")
  if (( ${#missing[@]} )); then
    anfs_warn "starting ${missing[*]} of $id (required by $csvc)"
    compose_flags "$id" || return 1
    compose_run "$id" "${FLAGS[@]}" up -d "${missing[@]}" >&2 || return 1
    wait_healthy "$id" || return 1
  fi

  local name rc=0
  name="$(svc_name "$id")-run-$(printf '%04x%02x' "$RANDOM" "$((RANDOM % 256))")"
  local -a args=(run --name "$name" --no-deps)
  $keep || args+=(--rm)
  [[ -z "$user" ]] || args+=(-u "$user")
  [[ -t 0 && -t 1 ]] || args+=(-T)
  PCM_ONEOFF=true compose_flags "$id" || return 1
  compose_run "$id" "${FLAGS[@]}" "${args[@]}" "$csvc" "$@" || rc=$?
  ! $keep || anfs_warn "kept $name (pcm remove $(svc_name "$id") deletes it, or: podman rm $name)"
  return $rc
}
