#!/usr/bin/env bash
# Service backend — Podman network management

PSM_DEFAULT_NETWORK="default"

# Ensure a named Podman network exists
_ensure_network() {
  local network="${1:-$PSM_DEFAULT_NETWORK}"
  # "default" is Podman's built-in network — skip creation
  [[ "$network" == "default" ]] && return 0
  if ! podman network exists "$network" 2>/dev/null; then
    debug "Creating Podman network: $network"
    podman network create "$network" >/dev/null
  fi
}

# Read the network key from a service's package.yml
_service_network() {
  local asset_dir="$1"
  local meta="$asset_dir/$PPM_ASSET_META"
  [[ -f "$meta" ]] || return 0
  local net
  net=$(yq -r '.network // ""' "$meta" 2>/dev/null)
  [[ "$net" == "null" ]] && net=""
  echo "$net"
}

# Resolve the effective network for a service
# If the service declares a network, use it. Otherwise use the context
# network (passed during dep resolution) or fall back to default.
_resolve_network() {
  local asset_dir="$1" context="${2:-}"
  local declared
  declared=$(_service_network "$asset_dir")

  if [[ -n "$declared" ]]; then
    echo "$declared"
  elif [[ -n "$context" ]]; then
    echo "$context"
  else
    echo "$PSM_DEFAULT_NETWORK"
  fi
}
