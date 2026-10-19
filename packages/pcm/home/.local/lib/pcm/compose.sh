#!/usr/bin/env bash
# pcm library: up, down and the `podman compose --pcm` wrapper
# Sourced by ~/.local/bin/pcm; defines functions only.

# Run a compose subcommand against each named service
# PRE holds compose global options that belong before the subcommand
compose_command() {
  local subcmd="$1"
  shift

  local -a services=() args=()
  local arg id
  for arg in "$@"; do
    if id=$(canon "$arg"); then services+=("$id"); else args+=("$arg"); fi
  done

  if [[ ${#services[@]} -eq 0 ]]; then
    echo "Usage: pcm $subcmd [options] <service>..." >&2
    echo "Available services:" >&2
    cmd_list >&2
    return 1
  fi

  if [[ "$subcmd" == "up" && " ${args[*]-} " != *" -d "* && " ${args[*]-} " != *" --detach "* ]]; then
    args+=(-d)
  fi

  # up: validate the services and everything they depend on before touching podman
  if [[ "$subcmd" == "up" ]]; then
    pcm_podman_ready || return 1
    CLOSURE=()
    for arg in "${services[@]}"; do
      dep_closure "$arg"
    done
    export_podman_socket "${CLOSURE[@]}"
    if ! validate_services "${CLOSURE[@]}"; then
      anfs_warn "not starting ${services[*]}: validation failed with $VALIDATE_ERRORS error(s)"
      return 1
    fi
    # Room for what starts: memory: (container.yml), against the host or the podman machine
    check_memory "${CLOSURE[@]}" || return 1
    # Nothing elevated starts unannounced: each privilege, with the reason it was declared
    local key reason
    for arg in "${CLOSURE[@]}"; do
      while IFS='|' read -r key reason; do
        [[ -n "$key" ]] && anfs_warn "$arg runs with $key: $reason"
      done < <(declared_privileges "$arg")
    done
  fi

  # down: running dependents are stopped first, which needs --force unless they were named too
  if [[ "$subcmd" == "down" ]]; then
    local force=false
    local -a kept=()
    for arg in ${args[@]+"${args[@]}"}; do
      if [[ "$arg" == "--force" ]]; then force=true; else kept+=("$arg"); fi
    done
    args=(${kept[@]+"${kept[@]}"})

    NAMED=" ${services[*]} "
    ORDER=()
    for arg in "${services[@]}"; do
      shutdown_order "$arg" || return 1
    done

    local -a dependents=()
    for arg in "${ORDER[@]}"; do
      [[ "$NAMED" == *" $arg "* ]] || dependents+=("$arg")
    done
    if [[ ${#dependents[@]} -gt 0 && "$force" != true ]]; then
      anfs_warn "not stopping ${services[*]}: running services depend on it: ${dependents[*]}"
      anfs_warn "stop those first, or pass --force to stop them before ${services[*]}"
      return 1
    fi

    services=("${ORDER[@]}")
  fi

  export_podman_socket "${services[@]}"

  # One compose invocation per service so each keeps its own project
  local service rc=0
  local -a service_args
  for service in "${services[@]}"; do
    service_args=(${args[@]+"${args[@]}"})
    PROVISIONED=()
    if [[ "$subcmd" == "up" ]]; then
      check_not_running_elsewhere "$service" || { rc=1; continue; }
      # Before its dependencies start: an edge's own service may need what add sets up
      edges_publish "$service" || { rc=1; continue; }
      start_deps "$service" || { rc=1; continue; }
      ensure_mount_dirs "$service"
    elif [[ "$subcmd" == "down" && "$NAMED" != *" $service "* ]]; then
      # Options like -v apply only to the services the user named
      anfs_warn "stopping dependent service $service"
      service_args=()
    fi
    compose_flags "$service" || { rc=1; continue; }
    compose_run "$service" ${PRE[@]+"${PRE[@]}"} "${FLAGS[@]}" "$subcmd" ${service_args[@]+"${service_args[@]}"} || {
      rc=$?
      # An orderly shutdown stops at the first failure
      if [[ "$subcmd" == "down" ]]; then
        anfs_warn "failed to stop $service; not stopping the rest"
        return $rc
      fi
    }
  done
  return $rc
}

# Internal: entry point for `podman compose --pcm ...` (--pcm already stripped).
# Falls back to plain compose with a warning when no pcm service is named.
compose_wrapper() {
  PRE=()
  while [[ $# -gt 0 && "$1" == -* ]]; do PRE+=("$1"); shift; done

  local arg named=false
  for arg in "$@"; do
    is_service "$arg" && { named=true; break; }
  done

  if [[ $# -eq 0 || "$named" == false ]]; then
    anfs_warn "--pcm given but no pcm service named; running plain ${RUNNER[*]}"
    exec "${RUNNER[@]}" ${PRE[@]+"${PRE[@]}"} "$@"
  fi

  compose_command "$@"
}

cmd_up()   { compose_command up "$@"; }
cmd_down() {
  # --force is pcm's (dependents stop first), read by compose_command among the arguments
  if ${CLI_OPT[force]:-false}; then compose_command down --force "$@"; else compose_command down "$@"; fi
}
