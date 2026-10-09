#!/usr/bin/env bash
# pcm library: running compose for a service: flags, env, fnox/varlock, health, mounts
# Sourced by ~/.local/bin/pcm; defines functions only.

compose_file() {
  echo "$(svc_dir "$1")/compose.yml"
}

# Everything pcm creates carries these labels (set by the override compose_flags writes):
#   io.pcm.id      source/name of the definition it was started from
#   io.pcm.name    the service name, its runtime identity
#   io.pcm.source  the source
# and runs as compose project <name>: pcm passes -p, so a definition's `name:` is ignored.
PCM_LABEL_ID=io.pcm.id
PCM_LABEL_NAME=io.pcm.name
PCM_LABEL_SOURCE=io.pcm.source

# Compose project name: the service name
project_name() {
  svc_name "$1"
}

# Names of the containers of service $1's name, whichever definition started them ([-a]: stopped too)
project_containers() {
  local all=()
  [[ "${2:-}" == "-a" ]] && all=(-a)
  podman ps ${all[@]+"${all[@]}"} --filter "label=$PCM_LABEL_NAME=$(svc_name "$1")" --format '{{.Names}}'
}

# The pcm id a container was started from
container_pcm_id() {
  podman inspect --format "{{index .Config.Labels \"$PCM_LABEL_ID\"}}" "$1" 2>/dev/null
}

# Refuse to start service $1 while its name runs from another definition (e.g. other/postgres
# while core/postgres is up). One service of a name runs at a time.
check_not_running_elsewhere() {
  local id="$1" container running
  container=$(project_containers "$id" | head -n1) || true
  [[ -n "$container" ]] || return 0
  running=$(container_pcm_id "$container") || true
  [[ -z "$running" || "$running" == "$id" ]] && return 0
  echo "pcm: $(svc_name "$id") is already running from $running; stop it first (pcm down $(svc_name "$id"))" >&2
  return 1
}

# The generated override for service $1
override_file() {
  echo "$PCM_CACHE_HOME/$(svc_name "$1").override.yml"
}

# Resolve compose -f flags for a service into FLAGS: its compose.yml, then a generated override
# that labels every compose service and, when attached, joins the shared network
compose_flags() {
  local service="$1" name
  local file
  file=$(compose_file "$service")
  name=$(svc_name "$service")

  FLAGS=(-f "$file")

  # Attach to the shared network if listed in PCM_ATTACHED_SERVICES (by name or source/name) or
  # it has pcm dependencies
  local attached=false network="" s
  for s in ${PCM_ATTACHED_SERVICES-postgres valkey}; do
    [[ "$s" == "$name" || "$s" == "$service" ]] && attached=true
  done
  [[ -n "$(service_deps "$service")" ]] && attached=true
  # A role provider (the proxy) reaches the services that use it over the shared network
  [[ -n "$(service_role "$service")" ]] && attached=true
  if [[ "$attached" == true ]]; then
    network="${PCM_SHARED_NETWORK:-dev-net}"
    podman network exists "$network" 2>/dev/null || podman network create "$network" >/dev/null || return 1
  fi

  # The ingress hosts may come from the service's env
  has_ingress "$service" && { load_env "$service" 2>/dev/null || true; }

  # A role provider is reachable on the shared network by its name (http://traefik:80 for an
  # edge), whatever the compose provider names its container. One compose service only, so the
  # alias is unambiguous.
  local alias=""
  if [[ -n "$network" && -n "$(service_role "$service")" && "$(yq eval '.services // {} | length' "$file")" == 1 ]]; then
    alias="$name"
  fi

  # Compose providers run as separate processes, so the override must be a real file.
  # Labels are in map form; compose merges them with the definition's own (list or map).
  # Attached services keep the project's default network; podman-compose requires it declared.
  local override key
  override=$(override_file "$service")
  mkdir -p "$(dirname "$override")"
  {
    echo "services:"
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      printf '  %s:\n    labels:\n      %s: "%s"\n      %s: "%s"\n      %s: "%s"\n' "$key" \
        "$PCM_LABEL_ID" "$service" "$PCM_LABEL_NAME" "$name" "$PCM_LABEL_SOURCE" "$(svc_src "$service")"
      ingress_labels "$service" "$key"
      if [[ -n "$network" && -n "$alias" ]]; then
        printf '    networks:\n      default: {}\n      %s:\n        aliases:\n          - %s\n' "$network" "$alias"
      elif [[ -n "$network" ]]; then
        printf '    networks:\n      - default\n      - %s\n' "$network"
      fi
      _override_mount_sets "$service" "$key"
      _override_snapshot_image "$service" "$key"
    done < <(yq eval '.services | keys | .[]' "$file")
    [[ -n "$network" ]] && printf 'networks:\n  default: {}\n  %s:\n    external: true\n' "$network"
  } > "$override"

  FLAGS+=(-f "$override")
}

# The volumes x-pcm.mounts generates for compose service $2 of service $1, as override lines
_override_mount_sets() {
  local svc="$1" key="$2" set csvc target ro lines=""
  while IFS='|' read -r set csvc target ro; do
    [[ -n "$set" && ( -z "$csvc" || "$csvc" == "$key" ) ]] || continue
    case "$set" in
      anfs-sources) lines+="$(mount_set_anfs_sources "$target" "$ro")"$'\n' ;;
    esac
  done < <(mount_sets "$svc")
  [[ -n "${lines//$'\n'/}" ]] || return 0
  printf '    volumes:\n%s' "$lines"
}

# Every anfs source, at <target>/<alias>: the clone (or the directory a local source links to)
# resolved, since a link inside the container would point at a host path
mount_set_anfs_sources() {
  local target="${1%/}" ro="$2" i name dir suffix=""
  [[ "$ro" == true ]] && suffix=":ro"
  gitsrc_collect
  for i in ${GITSRC_NAMES[@]+"${!GITSRC_NAMES[@]}"}; do
    name="${GITSRC_NAMES[$i]}"
    dir=$(cd -P "$(gitsrc_dir "$name")" 2>/dev/null && pwd) || continue
    printf '      - "%s:%s/%s%s"\n' "$dir" "$target" "$name" "$suffix"
  done
}

# The image a snapshot saved for compose service $2, while service $1 runs from a snapshot
_override_snapshot_image() {
  local image
  image=$(snapshot_active_image "$1" "$2") || return 0
  printf '    image: "%s"\n' "$image"
}

# True if a fnox config applies to service directory $1
uses_fnox() {
  local dir name
  for dir in "$1" "$PCM_CONFIG_HOME" "$PCM_CONTAINERS_HOME"; do
    for name in fnox.toml .fnox.toml fnox.local.toml; do
      [[ -f "$dir/$name" ]] && return 0
    done
  done
  return 1
}

# Export the KEY=VALUE lines of $PCM_ENV_HOME/<name>.env for service $1, except variables
# already in the environment: they sit where a .env would, below the environment
export_env_overrides() {
  local file line key val
  file="$PCM_ENV_HOME/$(svc_name "$1").env"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#export }"
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    if [[ "$val" == \"*\" || "$val" == \'*\' ]]; then val="${val:1:${#val}-2}"; fi
    [[ -n "${!key+x}" ]] || export "$key=$val"
  done < "$file"
}

# Run a command from service $1's directory with PROVISIONED and the local env overrides
# exported and, when fnox is installed and configured, fnox secrets loaded
in_service_dir() {
  local dir id="$1"
  dir=$(svc_dir "$id")
  shift
  (
    cd "$dir"
    [[ ${#PROVISIONED[@]} -eq 0 ]] || export "${PROVISIONED[@]}"
    export_env_overrides "$id"
    if command -v fnox >/dev/null 2>&1 && uses_fnox "$dir"; then
      exec fnox exec -- "$@"
    fi
    exec "$@"
  )
}

# Run a command for service $1 with its env resolved and validated by varlock.
# varlock refuses a directory with nothing to load, so a service without an
# .env.schema (one whose compose.yml uses no variables) runs the command as is.
# Extra `varlock run` options may come before a `--`.
service_run() {
  local service="$1"
  shift
  local -a opts=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do opts+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift

  if [[ -f "$(svc_dir "$service")/.env.schema" ]]; then
    in_service_dir "$service" varlock run --inject vars ${opts[@]+"${opts[@]}"} -- "$@"
  else
    in_service_dir "$service" "$@"
  fi
}

# Run compose for service $1, as project <name>
compose_run() {
  local service="$1"
  shift
  service_run "$service" -- "${RUNNER[@]}" -p "$(svc_name "$service")" "$@"
}

# Wait until every container in a service's project that has a healthcheck is healthy
wait_healthy() {
  local service="$1" deadline=$((SECONDS + PCM_HEALTH_TIMEOUT))
  local name status waiting
  while true; do
    waiting=""
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      status=$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null || true)
      if [[ -n "$status" && "$status" != "healthy" ]]; then
        waiting+=" $name"
        # Rootless podman without systemd timers never runs checks on its own
        podman healthcheck run "$name" >/dev/null 2>&1 || true
      fi
    done < <(project_containers "$service")

    [[ -z "$waiting" ]] && return 0
    if (( SECONDS >= deadline )); then
      echo "pcm: timed out after ${PCM_HEALTH_TIMEOUT}s waiting for${waiting} to become healthy" >&2
      return 1
    fi
    sleep 2
  done
}

# Make sure podman can run containers. On macOS that needs the podman machine VM, which nothing
# creates at install time: the first `pcm up` initializes it and every later one starts it if it
# is stopped, after sizing it to PCM_MACHINE_MEMORY. On Linux podman runs natively and there is
# nothing to do.
pcm_podman_ready() {
  command -v podman >/dev/null 2>&1 || { echo "pcm: podman is not installed (it ships with anfs: ppm install core/podman)" >&2; return 1; }
  [[ "$OSTYPE" == darwin* ]] || return 0
  if [[ -n "${PCM_MACHINE_MEMORY:-}" && ! "$PCM_MACHINE_MEMORY" =~ ^[0-9]+$ ]]; then
    echo "pcm: PCM_MACHINE_MEMORY is the podman machine's memory in MiB (e.g. 4096), not '$PCM_MACHINE_MEMORY'" >&2
    return 1
  fi
  if [[ -n "$(podman machine list --format '{{.Name}}' 2>/dev/null)" ]]; then
    pcm_machine_memory || return 1
    podman info >/dev/null 2>&1 && return 0
  else
    echo "pcm: creating the podman machine (once)" >&2
    # Ours to remove on implode (a machine that was already there is not), recorded before init so
    # a machine that fails to init or start is still removed. "clean": podman had no machine state
    # before this, so implode may delete what podman wrote for it too.
    mkdir -p "$PCM_STATE_HOME"
    # A machine's config is a json file; `podman machine list` (above) creates the empty dirs itself
    if ls "${XDG_CONFIG_HOME:-$HOME/.config}"/containers/podman/machine/*/*.json >/dev/null 2>&1; then
      echo existing > "$PCM_STATE_HOME/machine-created"
    else
      echo clean > "$PCM_STATE_HOME/machine-created"
    fi
    podman machine init ${PCM_MACHINE_MEMORY:+--memory "$PCM_MACHINE_MEMORY"} >&2 ||
      { echo "pcm: podman machine init failed" >&2; return 1; }
  fi
  echo "pcm: starting the podman machine" >&2
  podman machine start >&2 || { echo "pcm: podman machine start failed" >&2; return 1; }
}

# Give the podman machine PCM_MACHINE_MEMORY MiB when it has another amount. Memory can only be
# set on a stopped machine, so a running one is stopped first, which stops every container in it;
# pcm_podman_ready starts it again. Unset means leave the machine as it is.
pcm_machine_memory() {
  local want="${PCM_MACHINE_MEMORY:-}" have running
  [[ -n "$want" ]] || return 0
  have=$(podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null) || return 0
  [[ "$have" == "$want" ]] && return 0

  echo "pcm: the podman machine has $have MiB; PCM_MACHINE_MEMORY is $want: resizing it" >&2
  if [[ "$(podman machine inspect --format '{{.State}}' 2>/dev/null)" == running ]]; then
    running=$(podman ps --format '{{.Names}}' 2>/dev/null | paste -sd ' ' -)
    [[ -z "$running" ]] || echo "pcm: restarting the machine stops these containers: $running" >&2
    podman machine stop >&2 || { echo "pcm: podman machine stop failed" >&2; return 1; }
  fi
  podman machine set --memory "$want" >&2 || { echo "pcm: podman machine set --memory $want failed" >&2; return 1; }
}

# Export PCM_PODMAN_SOCKET if any of the given services use it: the podman API
# socket as seen by the engine running containers (local on Linux, inside the
# podman machine VM on macOS)
export_podman_socket() {
  [[ -z "${PCM_PODMAN_SOCKET:-}" ]] || return 0
  local svc
  for svc in "$@"; do
    if grep -q 'PCM_PODMAN_SOCKET' "$(compose_file "$svc")"; then
      PCM_PODMAN_SOCKET=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null) || true
      PCM_PODMAN_SOCKET="${PCM_PODMAN_SOCKET#unix://}"
      export PCM_PODMAN_SOCKET
      return 0
    fi
  done
  return 0
}

# Create missing bind mount directories under ${PCM_VOLUMES_HOME}/<name>/
ensure_mount_dirs() {
  local key type src target ro path
  while IFS='|' read -r key type src target ro; do
    [[ "$type" == "bind" ]] || continue
    path=$(expand_vars "$1" "$src")
    if under "$path" "$PCM_VOLUMES_HOME/$(svc_name "$1")" && [[ ! -e "$path" ]]; then
      mkdir -p "$path"
    fi
  done < <(service_mounts "$1")
  return 0
}
