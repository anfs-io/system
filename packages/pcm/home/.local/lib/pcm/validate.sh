#!/usr/bin/env bash
# pcm library: validation against pcm conventions; the validate command
# Sourced by ~/.local/bin/pcm; defines functions only.

# Cache service $1's env as resolved by varlock (KEY=value lines); fails if the
# env doesn't pass its .env.schema. Call from the main shell: $(...) loses the cache.
load_env() {
  local var="RESOLVED_ENV_${1//[^A-Za-z0-9_]/_}" out
  [[ -z "${!var+x}" ]] || return 0
  out=$(in_service_dir "$1" varlock load --format env 2>/dev/null) || return 1
  printf -v "$var" '%s' "$out"
}

# Value of variable $2 for service $1: the environment first, then the env
# load_env resolved (.env over .env.schema defaults)
env_value() {
  local name="$2" var="RESOLVED_ENV_${1//[^A-Za-z0-9_]/_}" line
  if [[ -n "${!name+x}" ]]; then
    echo "${!name}"
    return 0
  fi
  line=$(grep -E "^${name}=" <<< "${!var-}" | tail -n1) || true
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  echo "$line"
}

# Expand ${VAR} and ${VAR:-default} in $2 as compose would for service $1
expand_vars() {
  local svc="$1" s="$2" out="" name def val
  local re='^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)(:?-([^}]*))?\}(.*)$'
  while [[ "$s" =~ $re ]]; do
    out+="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    def="${BASH_REMATCH[4]}"
    s="${BASH_REMATCH[5]}"
    val=$(env_value "$svc" "$name")
    out+="${val:-$def}"
  done
  echo "$out$s"
}

# Mounts for service $1, one per line: key|type|source|target|read_only
# type is tmpfs, anonymous, invalid, or the declared/short-syntax type; source is unexpanded
service_mounts() {
  local file kind key a b c d
  file=$(compose_file "$1")
  local re='^((\$\{[^}]*\}|[^:$])*):([^:]+)(:([^:]*))?$'
  while IFS='|' read -r kind key a b c d; do
    if [[ "$kind" == "M" ]]; then
      if [[ -z "$b" && "$a" != "tmpfs" ]]; then a="anonymous"; fi
      echo "$key|$a|$b|$c|$d"
    elif [[ "$a" != *:* ]]; then
      echo "$key|anonymous||$a|false"
    elif [[ "$a" =~ $re ]]; then
      if [[ ",${BASH_REMATCH[5]}," == *,ro,* ]]; then d=true; else d=false; fi
      echo "$key|bind|${BASH_REMATCH[1]}|${BASH_REMATCH[3]}|$d"
    else
      echo "$key|invalid|$a||false"
    fi
  done < <(yq eval '.services // {} | to_entries | .[] | .key as $k | (.value.volumes // [])[] |
    ((select(tag == "!!str") | "S|" + $k + "|" + .),
     (select(tag == "!!map") | "M|" + $k + "|" + (.type // "volume") + "|" + (.source // "") + "|" + (.target // "") + "|" + ((.read_only // false) | tostring)))' "$file")
}

# Host ports published by service $1, one per line
service_ports() {
  local svc="$1" key entry port
  while IFS='|' read -r key entry; do
    entry=$(expand_vars "$svc" "$entry")
    entry="${entry%/*}"
    case "$entry" in
      *:*:*) port="${entry#*:}"; port="${port%%:*}" ;;
      *:*)   port="${entry%%:*}" ;;
      *)     continue ;;
    esac
    [[ -n "$port" ]] && echo "$port"
  done < <(yq eval '.services // {} | to_entries | .[] | .key as $k | (.value.ports // [])[] |
    ((select(tag != "!!map") | $k + "|" + tostring),
     (select(tag == "!!map" and .published != null) | $k + "|" + (.published | tostring) + ":" + (.target | tostring)))' "$(compose_file "$svc")")
  return 0
}

v_error() {
  echo "pcm: $1: error: $2" >&2
  VALIDATE_ERRORS=$((VALIDATE_ERRORS + 1))
}

v_warn() {
  echo "pcm: $1: warning: $2" >&2
}

# The service's env must resolve and pass its .env.schema
check_env() {
  local svc="$1"
  if [[ ! -f "$(svc_dir "$svc")/.env.schema" ]]; then
    if grep -q '\${' "$(compose_file "$svc")"; then
      v_error "$svc" "compose.yml uses variables but there is no .env.schema"
    fi
    return 0
  fi
  if ! command -v varlock >/dev/null 2>&1; then
    v_error "$svc" "varlock is not installed; it resolves .env.schema"
    return 0
  fi
  if ! load_env "$svc"; then
    in_service_dir "$svc" varlock load >&2 || true
    v_error "$svc" "env does not pass .env.schema (details above)"
  fi
  return 0
}

# Volumes must be bind mounts under ${PCM_VOLUMES_HOME}/<service>/,
# or read-only mounts from the service directory
check_volumes() {
  local svc="$1" key type src target ro path where name line dir vols
  local -a allowed=()
  dir=$(svc_dir "$svc")
  name=$(svc_name "$svc")
  vols="$PCM_VOLUMES_HOME/$name"

  # x-pcm.allow_mounts: extra host paths this service may mount
  while IFS= read -r line; do
    [[ -n "$line" ]] && allowed+=("$(expand_vars "$svc" "$line")")
  done < <(yq eval '.["x-pcm"].allow_mounts // [] | .[]' "$(compose_file "$svc")")

  while IFS='|' read -r key type src target ro; do
    where="services.$key.volumes $target"
    case "$type" in
      tmpfs) continue ;;
      invalid) v_error "$svc" "services.$key.volumes: can't parse '$src'"; continue ;;
      anonymous) v_error "$svc" "$where: anonymous volume; bind mount it from \${PCM_VOLUMES_HOME}/$name/"; continue ;;
    esac

    path=$(expand_vars "$svc" "$src")
    case "$path" in
      "~"*) path="$HOME${path:1}" ;;
      .*)   path="$dir/$path" ;;
    esac

    if [[ -z "$path" ]]; then
      v_error "$svc" "$where: '$src' expands to an empty path"
      continue
    fi

    if in_list "$path" ${allowed[@]+"${allowed[@]}"}; then
      # On macOS sources live in the podman machine VM, so they can't be checked from here
      if [[ "$OSTYPE" != darwin* && ! -e "$path" ]]; then
        if [[ "$path" == */podman.sock ]]; then
          v_error "$svc" "$where: podman API socket $path not found; enable it with: systemctl --user enable --now podman.socket"
        else
          v_error "$svc" "$where: allowed mount '$src' ($path) does not exist"
        fi
      fi
      continue
    fi

    if [[ "$path" != /* ]]; then
      v_error "$svc" "$where: named volume '$src'; bind mount it from \${PCM_VOLUMES_HOME}/$name/"
    elif [[ "$path" == */../* || "$path" == */.. ]]; then
      v_error "$svc" "$where: '$src' must not contain '..'"
    elif under "$path" "$vols"; then
      :
    elif [[ "$ro" == "true" ]] && under "$path" "$dir"; then
      :
    elif [[ "$ro" == "true" ]]; then
      v_error "$svc" "$where: read-only mount '$src' must come from the service directory"
    else
      v_error "$svc" "$where: '$src' is outside \${PCM_VOLUMES_HOME}/$name/ (read-only mounts may use the service directory)"
    fi
  done < <(service_mounts "$svc")

  while IFS= read -r line; do
    [[ -n "$line" ]] && v_error "$svc" "declares named volume '$line' under top-level volumes:"
  done < <(yq eval '.volumes // {} | keys | .[]' "$(compose_file "$svc")")
  return 0
}

# VOLUMEs declared by an image (if pulled) must be covered by a mount,
# otherwise podman creates a new anonymous volume on every container create
check_image_volumes() {
  local svc="$1" key image vol target covered
  local -a targets
  while IFS='|' read -r key image; do
    [[ -n "$image" ]] || continue
    image=$(expand_vars "$svc" "$image")
    podman image exists "$image" 2>/dev/null || continue

    targets=()
    while IFS='|' read -r _ _ _ target _; do
      [[ -n "$target" ]] && targets+=("${target%/}")
    done < <(service_mounts "$svc" | grep "^$key|")

    while IFS= read -r vol; do
      [[ -n "$vol" ]] || continue
      covered=false
      for target in ${targets[@]+"${targets[@]}"}; do
        if under "$vol" "$target"; then covered=true; break; fi
      done
      if [[ "$covered" != true ]]; then
        v_warn "$svc" "services.$key: image $image declares VOLUME $vol but nothing is mounted there; podman creates a new anonymous volume for every container"
      fi
    done < <(podman image inspect --format '{{json .Config.Volumes}}' "$image" | yq -p json '. // {} | keys | .[]')
  done < <(yq eval '.services // {} | to_entries | .[] | .key + "|" + (.value.image // "")' "$(compose_file "$svc")")
  return 0
}

# Print a dependency path from $2 back to $1, if one exists
find_cycle() {
  local start="$1" cur="$2" chain="$3" dep
  local -a deps=()
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && deps+=("$dep")
  done < <(dep_ids "$cur")
  for dep in ${deps[@]+"${deps[@]}"}; do
    if [[ "$dep" == "$start" ]]; then
      echo "$chain $dep"
      return 0
    fi
    if [[ " $chain " != *" $dep "* ]] && find_cycle "$start" "$dep" "$chain $dep"; then
      return 0
    fi
  done
  return 1
}

# x-pcm.depends_on must name existing services, at most one per name, without cycles
check_deps() {
  local svc="$1" spec dep cycle names=" "
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    if ! dep=$(canon "$spec"); then
      v_error "$svc" "x-pcm.depends_on: unknown service '$spec'"
    elif [[ "$names" == *" $(svc_name "$dep") "* ]]; then
      v_error "$svc" "x-pcm.depends_on: depends on '$(svc_name "$dep")' twice; only one runs at a time"
    else
      names+="$(svc_name "$dep") "
    fi
  done < <(service_deps "$svc")
  if cycle=$(find_cycle "$svc" "$svc" "$svc"); then
    v_error "$svc" "x-pcm.depends_on: dependency cycle: $cycle"
  fi
  return 0
}

# Host ports shouldn't clash with other pcm services
check_ports() {
  local svc="$1" other port
  local -a mine=()
  while IFS= read -r port; do
    [[ -n "$port" ]] && mine+=("$port")
  done < <(service_ports "$svc")
  [[ ${#mine[@]} -gt 0 ]] || return 0

  while IFS= read -r other; do
    [[ -n "$other" && "$(svc_name "$other")" != "$(svc_name "$svc")" ]] || continue
    load_env "$other" || true
    while IFS= read -r port; do
      if [[ " ${mine[*]} " == *" $port "* ]]; then
        v_warn "$svc" "host port $port is also published by $other"
      fi
    done < <(service_ports "$other")
  done < <(effective_ids)
  return 0
}

# pcm runs every service as compose project <name>, so a different top-level name: is ignored
check_project_name() {
  local svc="$1" declared
  declared=$(yq eval '.name // ""' "$(compose_file "$svc")")
  if [[ -n "$declared" && "$declared" != "$(svc_name "$svc")" ]]; then
    v_warn "$svc" "top-level name: '$declared' is ignored; pcm runs it as project '$(svc_name "$svc")'"
  fi
  return 0
}

# Compose keys that give a container more than the default isolation. Each must be declared under
# x-pcm.privileges with the reason it is needed, so nothing elevated runs without someone having
# said why. pid, network_mode and ipc only count when they share the host's namespace.
PCM_PRIVILEGE_KEYS="privileged devices cap_add security_opt pid network_mode ipc userns_mode"

# The elevated keys service $1's compose services use, one "key|compose-service" per line.
# yq only reads the fields; the decisions are bash's (yq emits a literal even after an empty
# select, so `select(cond) | "key|" + $k` would report every key).
service_privileges() {
  local k priv dev cap sec pid net ipc userns
  while IFS='|' read -r k priv dev cap sec pid net ipc userns; do
    [[ -n "$k" ]] || continue
    [[ "$priv" == true ]] && echo "privileged|$k"
    [[ "$dev" != 0 ]] && echo "devices|$k"
    [[ "$cap" != 0 ]] && echo "cap_add|$k"
    [[ "$sec" != 0 ]] && echo "security_opt|$k"
    [[ "$pid" == host ]] && echo "pid|$k"
    [[ "$net" == host ]] && echo "network_mode|$k"
    [[ "$ipc" == host ]] && echo "ipc|$k"
    [[ -n "$userns" ]] && echo "userns_mode|$k"
  done < <(yq eval '.services // {} | to_entries | .[] | [.key,
      ((.value.privileged // false) | tostring),
      ((.value.devices // []) | length | tostring),
      ((.value.cap_add // []) | length | tostring),
      ((.value.security_opt // []) | length | tostring),
      (.value.pid // ""), (.value.network_mode // ""), (.value.ipc // ""), (.value.userns_mode // "")] | join("|")' "$(compose_file "$1")")
  return 0
}

# The privileges service $1 declares, one "key|reason" per line
declared_privileges() {
  yq eval '.["x-pcm"].privileges // {} | to_entries | .[] | .key + "|" + (.value | tostring)' "$(compose_file "$1")"
}

# Every elevated key must be declared with a reason; a declaration nothing uses is a warning
check_privileges() {
  local svc="$1" key csvc reason declared used=" "
  declared=$(declared_privileges "$svc")
  while IFS='|' read -r key reason; do
    [[ -n "$key" ]] || continue
    if [[ " $PCM_PRIVILEGE_KEYS " != *" $key "* ]]; then
      v_error "$svc" "x-pcm.privileges: unknown privilege '$key' (known: $PCM_PRIVILEGE_KEYS)"
    elif [[ -z "$reason" || "$reason" == null ]]; then
      v_error "$svc" "x-pcm.privileges.$key: give the reason it is needed"
    fi
  done <<< "$declared"
  while IFS='|' read -r key csvc; do
    [[ -n "$key" ]] || continue
    used+="$key "
    grep -q "^$key|" <<< "$declared" ||
      v_error "$svc" "services.$csvc uses $key; declare it with the reason under x-pcm.privileges.$key"
  done < <(service_privileges "$svc")
  while IFS='|' read -r key reason; do
    [[ -n "$key" && " $PCM_PRIVILEGE_KEYS " == *" $key "* && "$used" != *" $key "* ]] &&
      v_warn "$svc" "x-pcm.privileges.$key is declared but no service uses it"
  done <<< "$declared"
  return 0
}

# Mount sets pcm generates (x-pcm.mounts), one "set|compose-service|target|readonly" per line;
# an empty compose-service means every service of the definition. readonly is true unless it says
# false (not `// true`: yq's // treats an explicit false as missing)
mount_sets() {
  yq eval '.["x-pcm"].mounts // [] | .[] | (.set // "") + "|" + (.service // "") + "|" + (.target // "") + "|" + ((.readonly == false) | not | tostring)' "$(compose_file "$1")"
}

PCM_MOUNT_SETS="anfs-sources"

check_mount_sets() {
  local svc="$1" set csvc target ro services
  services=" $(yq eval '.services // {} | keys | .[]' "$(compose_file "$svc")" | paste -sd ' ' -) "
  while IFS='|' read -r set csvc target ro; do
    [[ -n "$set$target" ]] || continue
    if [[ " $PCM_MOUNT_SETS " != *" $set "* ]]; then
      v_error "$svc" "x-pcm.mounts: unknown set '$set' (known: $PCM_MOUNT_SETS)"
    elif [[ "$target" != /* ]]; then
      v_error "$svc" "x-pcm.mounts ($set): target must be an absolute path in the container"
    elif [[ -n "$csvc" && "$services" != *" $csvc "* ]]; then
      v_error "$svc" "x-pcm.mounts ($set): no service '$csvc' in compose.yml"
    fi
  done < <(mount_sets "$svc")
  return 0
}

# Validate services; fails if there were errors (warnings don't fail)
validate_services() {
  local svc
  VALIDATE_ERRORS=0
  for svc in "$@"; do
    check_env "$svc"
    check_project_name "$svc"
    check_volumes "$svc"
    check_privileges "$svc"
    check_mount_sets "$svc"
    check_image_volumes "$svc"
    check_deps "$svc"
    check_ingress "$svc"
    check_ports "$svc"
  done
  [[ $VALIDATE_ERRORS -eq 0 ]]
}

cmd_validate() {
  local -a services=()
  local svc id
  if [[ $# -eq 0 ]]; then
    while IFS= read -r svc; do
      [[ -n "$svc" ]] && services+=("$svc")
    done < <(effective_ids)
  else
    for svc in "$@"; do
      if ! id=$(canon "$svc"); then
        echo "pcm: unknown service '$svc'" >&2
        return 1
      fi
      services+=("$id")
    done
  fi

  if [[ ${#services[@]} -eq 0 ]]; then
    echo "No services found (see: anfs src list)" >&2
    return 1
  fi

  export_podman_socket "${services[@]}"
  if ! validate_services "${services[@]}"; then
    echo "pcm: validation failed with $VALIDATE_ERRORS error(s)" >&2
    return 1
  fi
  echo "pcm: valid: ${services[*]}"
}
