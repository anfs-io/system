#!/usr/bin/env bash
# Service backend — Podman Quadlet generation for systemd (system scope)

# Count the number of services defined in a compose file
_compose_service_count() {
  local compose_file="$1"
  yq -r '.services | keys | length' "$compose_file" 2>/dev/null
}

# Extract the image from the first service in a compose file
_compose_first_image() {
  local compose_file="$1"
  yq -r '.services[].image' "$compose_file" 2>/dev/null | head -1
}

# Extract volume mounts from the first service in a compose file
# Outputs one mount per line in source:dest format
_compose_first_volumes() {
  local compose_file="$1"
  local first_svc
  first_svc=$(yq -r '.services | keys | .[0]' "$compose_file" 2>/dev/null)
  [[ -z "$first_svc" || "$first_svc" == "null" ]] && return
  yq -r ".services[\"$first_svc\"].volumes[]? // \"\"" "$compose_file" 2>/dev/null
}

# Generate a Podman Quadlet .container file for systemd management
# Usage: _generate_quadlet <service_name> <network> <instance_dir> <asset_dir>
_generate_quadlet() {
  local service="$1" network="$2" instance_dir="$3" asset_dir="$4"

  local compose_file
  compose_file=$(_find_compose_file "$asset_dir" 2>/dev/null) || return 0  # skip meta-services

  # Check for multi-container services
  local svc_count
  svc_count=$(_compose_service_count "$compose_file")
  if [[ "$svc_count" -gt 1 ]]; then
    echo "  Warning: $service has $svc_count containers — Quadlet not generated, use podman-compose" >&2
    return 0
  fi

  local quadlet_dir="/etc/containers/systemd"
  mkdir -p "$quadlet_dir"

  local unit_name="psm-${network}-${service}"
  local env_file="${instance_dir}/config/quadlet.env"

  # Write a persistent env file with PSM vars + service .env
  _build_quadlet_env "$service" "$instance_dir" "$asset_dir" "$network" > "$env_file"

  # Extract image from compose file
  local image
  image=$(_compose_first_image "$compose_file")

  # Extract volume mounts
  local volume_lines=""
  local vol
  while IFS= read -r vol; do
    [[ -z "$vol" || "$vol" == "null" ]] && continue
    volume_lines="${volume_lines}Volume=${vol}\n"
  done < <(_compose_first_volumes "$compose_file")

  # Build dependency directives from service.yml
  local after_lines=""
  local requires_lines=""
  local deps
  deps=$(resolve_package_deps "$asset_dir")
  if [[ -n "$deps" ]]; then
    for dep in $deps; do
      local dep_name="${dep##*/}"
      after_lines="${after_lines}After=psm-${network}-${dep_name}.service\n"
      requires_lines="${requires_lines}Requires=psm-${network}-${dep_name}.service\n"
    done
  fi

  cat > "${quadlet_dir}/${unit_name}.container" <<EOF
[Unit]
Description=PSM service: ${service} (${network})
$(echo -en "$after_lines")$(echo -en "$requires_lines")
[Container]
ContainerName=${network}-${service}
Image=${image}
Network=${network}
EnvironmentFile=${env_file}
$(echo -en "$volume_lines")
[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

  debug "Generated Quadlet: ${quadlet_dir}/${unit_name}.container"
}

# Build a persistent env file for Quadlet
# Combines PSM vars with the service's .env defaults
_build_quadlet_env() {
  local service="$1" instance_dir="$2" asset_dir="$3" network="$4"

  # PSM-provided variables
  cat <<EOF
PSM_DATA=${instance_dir}/data
PSM_CONFIG=${instance_dir}/config
PSM_CACHE=${PPM_CACHE_HOME:-$HOME/.cache/psm}/${network}/${service}
PSM_SERVICE=${service}
PSM_NETWORK=${network}
PSM_TYPE=${PSM_SCOPE}
EOF

  # Service .env defaults
  local dot_env="${asset_dir}/.env"
  if [[ -f "$dot_env" ]]; then
    cat "$dot_env"
  fi
}

# Remove Quadlet files and systemd unit for a service
# Usage: _remove_quadlet <service_name> <network> <instance_dir>
_remove_quadlet() {
  local service="$1" network="$2" instance_dir="$3"
  local unit_name="psm-${network}-${service}"

  systemctl disable "$unit_name" 2>/dev/null || true
  systemctl stop "$unit_name" 2>/dev/null || true
  rm -f "/etc/containers/systemd/${unit_name}.container"
  rm -f "${instance_dir}/config/quadlet.env"
  systemctl daemon-reload
  echo "  Removed systemd unit: ${unit_name}"
}
