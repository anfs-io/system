#!/usr/bin/env bash
# Service backend — compose runner and env injection

_require_podman() {
  for cmd in podman podman-compose; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "psm: '$cmd' is not installed" >&2
      exit 1
    fi
  done
}

# Find the compose file in a service directory
_find_compose_file() {
  local dir="$1"
  for name in compose.yml compose.yaml docker-compose.yml docker-compose.yaml; do
    if [[ -f "${dir}/${name}" ]]; then
      echo "${dir}/${name}"
      return
    fi
  done
  echo "psm: No compose file found in ${dir}" >&2
  return 1
}

# Run a compose command for a service instance
# PSM vars are exported into the subshell environment.
# The service's .env is auto-loaded by podman-compose from the service dir.
# If varlock is present with .env.schema, it wraps the compose call.
_compose_run() {
  local service="$1" network="$2"
  shift 2

  _require_podman
  _ensure_network "$network"

  local instance_dir="${PSM_SERVICES_HOME}/${network}/${service}"
  local service_dir="${instance_dir}/service"

  if [[ ! -L "$service_dir" && ! -d "$service_dir" ]]; then
    echo "psm: Service '${service}' is not installed on network '${network}'. Run: psm install ${service}" >&2
    return 1
  fi

  local compose_file
  compose_file=$(_find_compose_file "$service_dir") || return 1

  local project_name="${network}-${service}"

  # Run in a subshell with PSM vars exported
  (
    export PSM_DATA="${instance_dir}/data"
    export PSM_CONFIG="${instance_dir}/config"
    export PSM_CACHE="${PPM_CACHE_HOME:-$HOME/.cache/psm}/${network}/${service}"
    export PSM_SERVICE="$service"
    export PSM_NETWORK="$network"
    export PSM_TYPE="$PSM_SCOPE"

    cd "$service_dir"

    if [[ -z "${PSM_SKIP_VALIDATION:-}" ]] \
       && command -v varlock >/dev/null 2>&1 \
       && [[ -f ".env.schema" ]]; then
      debug "varlock detected — wrapping compose call"
      varlock run -- podman-compose \
        -f "$compose_file" \
        -p "$project_name" \
        "$@"
    else
      [[ -n "${PSM_SKIP_VALIDATION:-}" ]] && debug "Validation skipped (--skip-validation)"
      podman-compose -f "$compose_file" -p "$project_name" "$@"
    fi
  )
}
