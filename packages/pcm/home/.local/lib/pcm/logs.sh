#!/usr/bin/env bash
# pcm library: the logs command
# Sourced by ~/.local/bin/pcm; defines functions only.
#
# `pcm logs <service> [-s NAME] [-f] [--tail N] [--since T] [-- options...]` is `podman compose
# logs` for the service's project, run as up runs compose (compose_flags, compose_run): every
# compose service's containers, or -s NAME's. A plain command, so it works from any shell; the
# `podman compose --pcm logs` wrapper in pcm.zsh comes here too (compose_wrapper). Compose logs
# reads the containers the compose file defines, so `pcm run`'s one-offs are left out; -s with a
# one-off's name (<name>-run-<hex>, see pcm ps) shows that one with podman logs.

# The containers of service $1's name, stopped too, of compose service $2 if given; no one-offs
_logs_containers() {
  local filter=()
  [[ -z "${2:-}" ]] || filter=(--filter "label=com.docker.compose.service=$2")
  podman ps -a --filter "label=$PCM_LABEL_NAME=$(svc_name "$1")" ${filter[@]+"${filter[@]}"} \
    --filter "label!=$PCM_LABEL_ONEOFF" --format '{{.Names}}'
}

cmd_logs() {
  local id csvc="${CLI_OPT[service]:-}" ctrs running=""
  id=$(canon "${1:-}") || cli_usage_err "unknown service '${1:-}' (see: pcm list)"
  shift
  local -a opts=() oneoffs=() csvcs=()
  ! ${CLI_OPT[follow]:-false} || opts+=(-f)
  [[ -z "${CLI_OPT[tail]:-}" ]] || opts+=(--tail "${CLI_OPT[tail]}")
  [[ -z "${CLI_OPT[since]:-}" ]] || opts+=(--since "${CLI_OPT[since]}")
  [[ "${1:-}" != -- ]] || shift
  opts+=("$@")

  if [[ -n "$csvc" ]]; then
    mapfile -t oneoffs < <(oneoff_containers "$id")
    if in_list "$csvc" ${oneoffs[@]+"${oneoffs[@]}"}; then
      podman logs ${opts[@]+"${opts[@]}"} "$csvc"
      return
    fi
    mapfile -t csvcs < <(_run_compose_services "$id")
    in_list "$csvc" ${csvcs[@]+"${csvcs[@]}"} ||
      cli_usage_err "$id has no compose service '$csvc' (it has: ${csvcs[*]})"
  fi

  ctrs=$(_logs_containers "$id" "$csvc")
  if [[ -z "$ctrs" ]]; then
    anfs_warn "$id has no containers${csvc:+ of compose service $csvc} (pcm up $(svc_name "$id"))"
    return 1
  fi
  # The definition its containers were started from, when another source's is running
  running=$(container_pcm_id "${ctrs%%$'\n'*}") || true
  if [[ -n "$running" && "$running" != "$id" ]] && running=$(canon "$running"); then id="$running"; fi

  compose_flags "$id" || return 1
  compose_run "$id" "${FLAGS[@]}" logs ${opts[@]+"${opts[@]}"} ${csvc:+"$csvc"}
}
