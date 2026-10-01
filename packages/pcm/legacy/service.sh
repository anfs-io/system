#!/usr/bin/env bash
# Service backend — install/remove profile functions

# Install a service: create instance directory, link service definition
profile_install() {
  local asset_dir="$1" asset_name="$2"

  _require_podman

  # Determine the network for this service
  local network
  network=$(_resolve_network "$asset_dir" "${_PSM_INSTALL_NETWORK:-}")

  # Ensure the network exists
  _ensure_network "$network"

  local instance_dir="${PSM_SERVICES_HOME}/${network}/${asset_name}"

  # Skip if already installed at this network location
  if [[ -d "$instance_dir/data" ]]; then
    debug "$asset_name already installed on network $network"
    PROFILE_STOWED_FILES=""
    return 0
  fi

  # System scope requires root
  if [[ "$PSM_SCOPE" == "system" && $EUID -ne 0 ]]; then
    echo "psm: System services require root. Use: sudo psm install ${asset_name} --system" >&2
    exit 1
  fi

  # Create instance directory structure
  mkdir -p "${instance_dir}/config"
  mkdir -p "${instance_dir}/data"

  # Link the service definition from the source repo
  ln -sfn "$asset_dir" "${instance_dir}/service"

  echo "  network:  $network"
  echo "  data:     ${instance_dir}/data"
  echo "  config:   ${instance_dir}/config"

  # Generate Quadlet for system scope
  if [[ "$PSM_SCOPE" == "system" ]]; then
    _generate_quadlet "$asset_name" "$network" "$instance_dir" "$asset_dir"
    systemctl daemon-reload
    systemctl enable "psm-${network}-${asset_name}" 2>/dev/null || true
    echo "  systemd:  psm-${network}-${asset_name}.service (enabled)"
  fi

  # No stowed files for services — tracking is directory-based
  PROFILE_STOWED_FILES=""
}

# Remove a service: stop containers, remove instance directory
profile_remove() {
  local asset_dir="$1" asset_name="$2"

  local network
  network=$(_resolve_network "$asset_dir" "${_PSM_INSTALL_NETWORK:-}")

  local instance_dir="${PSM_SERVICES_HOME}/${network}/${asset_name}"

  if [[ ! -d "$instance_dir" ]]; then
    debug "$asset_name not installed on network $network"
    return 0
  fi

  # Stop containers if running
  if [[ -L "$instance_dir/service" || -d "$instance_dir/service" ]]; then
    local compose_file
    compose_file=$(_find_compose_file "$instance_dir/service" 2>/dev/null) || true
    if [[ -n "$compose_file" ]]; then
      debug "Stopping containers for $asset_name"
      _compose_run "$asset_name" "$network" down 2>/dev/null || true
    fi
  fi

  # Remove the instance directory (data preserved)
  rm -f "${instance_dir}/service"
  rmdir "${instance_dir}/config" 2>/dev/null || true

  # Remove Quadlet for system scope
  if [[ "$PSM_SCOPE" == "system" ]]; then
    _remove_quadlet "$asset_name" "$network" "$instance_dir"
  fi

  echo "  Removed instance (data preserved at ${instance_dir}/data)"
}

# --- Lifecycle commands ---

# Service-specific command dispatch
backend_command() {
  local cmd="$1"
  shift

  case "$cmd" in
    up)      cmd_up "$@" ;;
    down)    cmd_down "$@" ;;
    restart) cmd_restart "$@" ;;
    logs)    cmd_logs "$@" ;;
    status)  cmd_status "$@" ;;
    *)       return 1 ;;
  esac
}

# Parse network/service syntax
# Sets _lc_network and _lc_service in caller's scope
_parse_service_arg() {
  local arg="$1"
  _lc_network=""
  _lc_service=""

  if [[ "$arg" == */* ]]; then
    _lc_network="${arg%%/*}"
    _lc_service="${arg##*/}"
  else
    _lc_service="$arg"
  fi
}

# Find which network a service is installed on
_find_installed_network() {
  local service="$1"
  local found=()

  if [[ -d "$PSM_SERVICES_HOME" ]]; then
    for network_dir in "$PSM_SERVICES_HOME"/*/; do
      [[ -d "$network_dir" ]] || continue
      local network=$(basename "$network_dir")
      if [[ -d "$network_dir/$service" ]]; then
        found+=("$network")
      fi
    done
  fi

  if [[ ${#found[@]} -eq 0 ]]; then
    echo "psm: Service '$service' is not installed" >&2
    return 1
  elif [[ ${#found[@]} -eq 1 ]]; then
    echo "${found[0]}"
  else
    echo "psm: Service '$service' exists on multiple networks: ${found[*]}" >&2
    echo "psm: Specify with: psm <command> <network>/$service" >&2
    return 1
  fi
}

# Resolve network for a lifecycle command
# Uses explicit network/service syntax, or finds the installed network
_resolve_lifecycle_network() {
  local service="$1" explicit_network="$2"

  if [[ -n "$explicit_network" ]]; then
    echo "$explicit_network"
    return
  fi

  # Try to resolve from dep tree (service definition)
  collect_repos
  local found
  found=$(find_package_dir "$service" 2>/dev/null) || true
  if [[ -n "$found" ]]; then
    local pkg_dir="${found#*	}"
    pkg_dir="${pkg_dir#*	}"
    local net
    net=$(_resolve_network "$pkg_dir")
    echo "$net"
    return
  fi

  # Fall back to scanning installed dirs
  _find_installed_network "$service"
}

cmd_up() {
  local arg="${1:-}"
  [[ -z "$arg" ]] && { echo "Usage: psm up <service>"; exit 1; }
  shift

  _parse_service_arg "$arg"
  local service="$_lc_service"
  local network_override="$_lc_network"

  _require_podman
  collect_repos
  resolve_deps "$service"

  # Determine network from the top-level service
  local top_dir
  top_dir=$(find_package_dir "$service") || { echo "psm: Service '$service' not found" >&2; exit 1; }
  top_dir="${top_dir#*	}"; top_dir="${top_dir#*	}"
  local network
  if [[ -n "$network_override" ]]; then
    network="$network_override"
  else
    network=$(_resolve_network "$top_dir")
  fi

  _ensure_network "$network"

  for i in "${!RESOLVE_ORDER[@]}"; do
    local qualified="${RESOLVE_ORDER[$i]}"
    local svc_name="${qualified##*/}"
    local svc_asset_dir="${RESOLVE_DIRS[$i]}"

    local instance_dir="${PSM_SERVICES_HOME}/${network}/${svc_name}"

    # Auto-install if not installed
    if [[ ! -d "$instance_dir/data" ]]; then
      debug "Auto-installing $svc_name"
      _PSM_INSTALL_NETWORK="$network" profile_install "$svc_asset_dir" "$svc_name"
      # Track the auto-install
      local repo_name="${qualified%%/*}"
      meta_mark_installed "$repo_name" "$svc_name" "$svc_asset_dir" ""
    fi

    # Skip services with no compose file (meta-services / bundles)
    local compose_file
    compose_file=$(_find_compose_file "$instance_dir/service" 2>/dev/null) || {
      debug "No compose file for $svc_name — skipping start"
      continue
    }

    if [[ "$PSM_SCOPE" == "system" ]]; then
      local unit_name="psm-${network}-${svc_name}"
      echo "Starting $svc_name (systemd)"
      systemctl start "$unit_name"
    else
      echo "Starting $svc_name"
      _compose_run "$svc_name" "$network" up -d "$@"
    fi
  done
}

cmd_down() {
  local arg="${1:-}"
  [[ -z "$arg" ]] && { echo "Usage: psm down <service>"; exit 1; }

  _parse_service_arg "$arg"
  local service="$_lc_service"
  local network_override="$_lc_network"

  _require_podman
  collect_repos
  resolve_deps "$service"

  local top_dir
  top_dir=$(find_package_dir "$service") || { echo "psm: Service '$service' not found" >&2; exit 1; }
  top_dir="${top_dir#*	}"; top_dir="${top_dir#*	}"
  local network
  if [[ -n "$network_override" ]]; then
    network="$network_override"
  else
    network=$(_resolve_network "$top_dir")
  fi

  # Reverse order — stop dependents first
  local count=${#RESOLVE_ORDER[@]}
  local i=$((count - 1))
  while [[ $i -ge 0 ]]; do
    local qualified="${RESOLVE_ORDER[$i]}"
    local svc_name="${qualified##*/}"

    local instance_dir="${PSM_SERVICES_HOME}/${network}/${svc_name}"
    if [[ -d "$instance_dir/service" ]] || [[ -L "$instance_dir/service" ]]; then
      local compose_file
      compose_file=$(_find_compose_file "$instance_dir/service" 2>/dev/null) || { i=$((i - 1)); continue; }

      if [[ "$PSM_SCOPE" == "system" ]]; then
        local unit_name="psm-${network}-${svc_name}"
        echo "Stopping $svc_name (systemd)"
        systemctl stop "$unit_name" 2>/dev/null || true
      else
        echo "Stopping $svc_name"
        _compose_run "$svc_name" "$network" down 2>/dev/null || true
      fi
    fi
    i=$((i - 1))
  done
}

cmd_restart() {
  local arg="${1:-}"
  [[ -z "$arg" ]] && { echo "Usage: psm restart <service>"; exit 1; }

  cmd_down "$arg"
  cmd_up "$arg"
}

cmd_logs() {
  local arg="${1:-}"
  [[ -z "$arg" ]] && { echo "Usage: psm logs <service> [-f]"; exit 1; }
  shift

  _parse_service_arg "$arg"
  local service="$_lc_service"
  local network

  if [[ -n "$_lc_network" ]]; then
    network="$_lc_network"
  else
    network=$(_find_installed_network "$service") || exit 1
  fi

  _compose_run "$service" "$network" logs "$@"
}

cmd_status() {
  local arg="${1:-}"

  _require_podman

  if [[ "$PSM_SCOPE" == "system" && -z "$arg" ]]; then
    # System scope: show systemd unit status
    echo "PSM services (systemd):"
    systemctl list-units 'psm-*' --no-pager --no-legend 2>/dev/null || echo "  No PSM units found"
    return
  fi

  if [[ -z "$arg" ]]; then
    # Show all PSM services grouped by network
    echo "PSM services:"
    if [[ -d "$PSM_SERVICES_HOME" ]]; then
      for network_dir in "$PSM_SERVICES_HOME"/*/; do
        [[ -d "$network_dir" ]] || continue
        local network=$(basename "$network_dir")
        echo ""
        echo "  $network:"
        for svc_dir in "$network_dir"/*/; do
          [[ -d "$svc_dir" ]] || continue
          [[ -L "$svc_dir/service" || -d "$svc_dir/service" ]] || continue
          local svc_name=$(basename "$svc_dir")
          local project_name="${network}-${svc_name}"
          local status="stopped"
          if podman ps --filter "label=com.docker.compose.project=${project_name}" --format "{{.Status}}" 2>/dev/null | grep -qi "up\|running"; then
            status="running"
          fi
          printf "    %-20s %s\n" "$svc_name" "$status"
        done
      done
    fi
  else
    _parse_service_arg "$arg"
    local service="$_lc_service"
    local network

    if [[ -n "$_lc_network" ]]; then
      network="$_lc_network"
    else
      network=$(_find_installed_network "$service") || exit 1
    fi

    _compose_run "$service" "$network" ps
  fi
}

# Enhanced show output for services
# Called after the generic show output
backend_show() {
  local asset_dir="$1" asset_name="$2" repo_name="$3"

  # Service metadata from service.yml (description, ports, tags)
  local svc_meta="$asset_dir/$PPM_ASSET_META"
  if [[ -f "$svc_meta" ]] && command -v yq >/dev/null 2>&1; then
    local desc
    desc=$(yq -r '.description // ""' "$svc_meta" 2>/dev/null)
    [[ -n "$desc" && "$desc" != "null" ]] && echo "About:       $desc"

    local ports
    ports=$(yq -r '.ports[]? // ""' "$svc_meta" 2>/dev/null)
    if [[ -n "$ports" ]]; then
      echo "Ports:"
      echo "$ports" | while IFS= read -r p; do
        [[ -n "$p" ]] && echo "  $p"
      done
    fi
  fi

  # Network
  local network
  network=$(_service_network "$asset_dir")
  if [[ -n "$network" ]]; then
    echo "Network:     $network (isolated)"
  else
    echo "Network:     default (shared)"
  fi

  # PCM credentials
  if [[ -f "$asset_dir/pcm.yml" ]]; then
    echo "Credentials: pcm.yml present"
  fi

  # Resolved dependency tree
  echo ""
  collect_repos
  resolve_deps "$asset_name"
  if [[ ${#RESOLVE_ORDER[@]} -gt 1 ]]; then
    echo "Resolved install order:"
    for pkg in "${RESOLVE_ORDER[@]}"; do
      local marker=""
      [[ "$(basename "$pkg")" == "$asset_name" ]] && marker=" (this)"
      echo "  $(basename "$pkg")${marker}"
    done
  fi

  # Installed instance status
  echo ""
  local found_instances=false
  if [[ -d "$PSM_SERVICES_HOME" ]]; then
    for network_dir in "$PSM_SERVICES_HOME"/*/; do
      [[ -d "$network_dir" ]] || continue
      local net=$(basename "$network_dir")
      local instance_dir="$network_dir/$asset_name"
      [[ -d "$instance_dir" ]] || continue

      found_instances=true
      local status="stopped"
      local project_name="${net}-${asset_name}"
      if podman ps --filter "label=com.docker.compose.project=${project_name}" --format "{{.Status}}" 2>/dev/null | grep -qi "up\|running"; then
        status="running"
      fi

      echo "Instance:    $net/$asset_name ($status)"
      echo "  data:      $instance_dir/data"
      echo "  config:    $instance_dir/config"
    done
  fi

  if ! $found_instances; then
    echo "Installed:   no"
    echo "  Install with: psm install $asset_name"
  fi
}

# Zsh completion output for PSM commands
backend_completion() {
  local shell="${1:-zsh}"
  case "$shell" in
    zsh)
      cat <<'COMP'
#compdef psm

_psm() {
    local -a subcommands
    local state

    subcommands=(
        'install:Install a service'
        'remove:Remove a service'
        'update:Update service repositories'
        'list:List available services'
        'ls:List available services (alias)'
        'show:Show service information'
        'deps:Show dependency tree'
        'src:Manage service sources'
        'up:Start a service'
        'down:Stop a service'
        'restart:Restart a service'
        'logs:View service logs'
        'status:Show service status'
        'path:Output path to a service directory'
        'cd:Change to a service directory'
        'config:Show PSM configuration'
        'help:Show help'
    )

    _arguments -C \
        '(-v)-v[Verbose output]' \
        '(-s --skip-validation)-s[Skip validation]' \
        '--skip-validation[Skip validation]' \
        '--user[Force user scope]' \
        '--system[Force system scope]' \
        '1: :->command' \
        '*: :->args'

    case $state in
        command)
            _describe 'command' subcommands
            ;;
        args)
            case ${words[2]} in
                src)
                    if [[ ${#words[@]} -eq 3 ]]; then
                        local -a src_cmds
                        src_cmds=('add:Add a service source' 'remove:Remove a service source' 'list:List configured sources')
                        _describe 'subcommand' src_cmds
                    fi
                    ;;
                install|remove|show|deps|up|down|restart|logs|status|path|cd)
                    _psm_services_available
                    ;;
            esac
            ;;
    esac
}

_psm_services_available() {
    local -a services
    local psm_data_home="${XDG_DATA_HOME:-$HOME/.local/share}/psm"

    # Available from repos
    for repo_dir in "$psm_data_home"/*/services; do
        [[ -d "$repo_dir" ]] || continue
        local repo_name="${repo_dir%/services}"
        repo_name="${repo_name##*/}"
        for svc_dir in "$repo_dir"/*/; do
            [[ -d "$svc_dir" ]] || continue
            local svc_name="${svc_dir%/}"
            svc_name="${svc_name##*/}"
            services+=("${svc_name}")
        done
    done

    # Installed instances (network/service)
    local services_home="${XDG_STATE_HOME:-$HOME/.local/state}/psm"
    if [[ -d "$services_home" ]]; then
        for network_dir in "$services_home"/*/; do
            [[ -d "$network_dir" ]] || continue
            local network="${network_dir%/}"
            network="${network##*/}"
            for svc_dir in "$network_dir"/*/; do
                [[ -d "$svc_dir" ]] || continue
                local svc_name="${svc_dir%/}"
                svc_name="${svc_name##*/}"
                services+=("${network}/${svc_name}")
            done
        done
    fi

    _describe 'service' services
}

compdef _psm psm
COMP
      ;;
    *)
      echo "# Completion for $shell not yet implemented" ;;
  esac
}
