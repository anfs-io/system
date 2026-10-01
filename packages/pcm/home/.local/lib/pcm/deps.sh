#!/usr/bin/env bash
# pcm library: x-pcm.depends_on: resolution, provisioning, start and shutdown order
# Sourced by ~/.local/bin/pcm; defines functions only.

# Services listed in x-pcm.depends_on (list or map form), as written
service_deps() {
  yq eval '.["x-pcm"].depends_on | select(. != null) | ((select(tag == "!!seq") | .[]), (select(tag == "!!map") | keys | .[]))' "$(compose_file "$1")"
}

# Ids of service $1's dependencies. Unknown ones are skipped.
dep_ids() {
  local spec
  while IFS= read -r spec; do
    [[ -n "$spec" ]] && canon "$spec"
  done < <(service_deps "$1")
  return 0
}

# key=value settings service $1 declares for dependency $2 (as written; map form only)
dep_settings() {
  yq eval ".[\"x-pcm\"].depends_on | select(tag == \"!!map\") | .[\"$2\"] | select(tag == \"!!map\") | to_entries | .[] | .key + \"=\" + (.value | tostring)" "$(compose_file "$1")"
}

# Hooks a definition may ship for the services that depend on it, each an executable file in
# its directory, run from there under varlock with the dependency's resolved env:
#   provision    on `up` of a dependent, once the dependency is healthy; prints KEY=VALUE
#   deprovision  on `remove` of a dependent, after it is down; undoes what provision created
# Both get the dependent's settings for it (x-pcm.depends_on map form) as key=value args, and
# PCM_SERVICE, PCM_PROJECT (the dependency) and PCM_DEPENDENT (the service) in the environment.

has_hook() {
  [[ -x "$(svc_dir "$2")/$1" ]]
}

# Run hook $1 of dependency $3 for service $2, whose depends_on names it as $4. Prints the hook's
# stdout (unredacted: provision's carries connection details).
run_hook() {
  local hook_name="$1" service="$2" dep="$3" spec="$4" hook line
  hook="$(svc_dir "$dep")/$hook_name"
  [[ -x "$hook" ]] || return 0

  local -a settings=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && settings+=("$line")
  done < <(dep_settings "$service" "$spec")

  (
    export PCM_SERVICE="$(svc_name "$dep")" PCM_PROJECT="$(project_name "$dep")" PCM_DEPENDENT="$(svc_name "$service")"
    service_run "$dep" --no-redact-stdout -- "$hook" ${settings[@]+"${settings[@]}"}
  )
}

# Run dependency $2's provision hook for service $1 ($3: the spec as written).
# Hook output lines KEY=VALUE are appended to PROVISIONED as PCM_<DEP>_<KEY>=VALUE.
provision() {
  local service="$1" dep="$2" spec="$3" output line
  has_hook provision "$dep" || return 0
  output=$(run_hook provision "$service" "$dep" "$spec") || {
    echo "pcm: provisioning $dep for $service failed" >&2
    return 1
  }

  local prefix var
  prefix="PCM_$(tr '[:lower:]-' '[:upper:]_' <<< "$(svc_name "$dep")")_"
  while IFS= read -r line; do
    [[ "$line" =~ ^[A-Z][A-Z0-9_]*= ]] || continue
    var="$prefix${line%%=*}"
    [[ -n "${!var+x}" ]] && continue  # a value already in the environment wins
    PROVISIONED+=("$var=${line#*=}")
  done <<< "$output"
}

# Start and provision a service's x-pcm dependencies (recursively).
# Leaves the provisioned env for the service in PROVISIONED.
start_deps() {
  local service="$1" chain="${2:-}"
  local -a specs=() collected=()
  local spec dep

  if [[ " $chain " == *" $service "* ]]; then
    echo "pcm: dependency cycle:$chain $service" >&2
    return 1
  fi

  while IFS= read -r spec; do
    [[ -n "$spec" ]] && specs+=("$spec")
  done < <(service_deps "$service")

  for spec in ${specs[@]+"${specs[@]}"}; do
    if ! dep=$(canon "$spec"); then
      echo "pcm: $service depends on unknown service '$spec'" >&2
      return 1
    fi

    if [[ -n "$(project_containers "$dep")" ]]; then
      check_not_running_elsewhere "$dep" || return 1
    else
      start_deps "$dep" "$chain $service" || return 1
      echo "pcm: starting $dep (required by $service)" >&2
      compose_flags "$dep" || return 1
      ensure_mount_dirs "$dep"
      compose_run "$dep" "${FLAGS[@]}" up -d || return 1
    fi

    wait_healthy "$dep" || return 1
    PROVISIONED=()
    provision "$service" "$dep" "$spec" || return 1
    collected+=(${PROVISIONED[@]+"${PROVISIONED[@]}"})
  done

  PROVISIONED=(${collected[@]+"${collected[@]}"})
}

# Append $1 and its x-pcm dependencies (recursively) to CLOSURE
dep_closure() {
  local dep
  local -a deps=()
  if [[ " ${CLOSURE[*]-} " == *" $1 "* ]]; then return 0; fi
  CLOSURE+=("$1")
  while IFS= read -r dep; do
    [[ -n "$dep" ]] && deps+=("$dep")
  done < <(dep_ids "$1")
  for dep in ${deps[@]+"${deps[@]}"}; do
    dep_closure "$dep"
  done
  return 0
}

# Services whose x-pcm.depends_on includes $1
service_dependents() {
  local svc
  local deps
  while IFS= read -r svc; do
    # Not `dep_ids | grep -q`: grep exits at the first match, and under pipefail the SIGPIPE
    # dep_ids then takes on a later dependency makes the match look like a miss
    deps=$'\n'"$(dep_ids "$svc")"$'\n'
    [[ "$deps" == *$'\n'"$1"$'\n'* ]] && echo "$svc"
  done < <(effective_ids)
  return 0
}

# Append to ORDER the running dependents of $1 (recursively, deepest first), then $1.
# Services not in NAMED are only included if running.
shutdown_order() {
  local service="$1" chain="${2:-}" dep
  local -a dependents=()

  if [[ " $chain " == *" $service "* ]]; then
    echo "pcm: dependency cycle:$chain $service" >&2
    return 1
  fi
  if [[ " ${ORDER[*]-} " == *" $service "* ]]; then return 0; fi

  while IFS= read -r dep; do
    [[ -n "$dep" ]] && dependents+=("$dep")
  done < <(service_dependents "$service")

  for dep in ${dependents[@]+"${dependents[@]}"}; do
    shutdown_order "$dep" "$chain $service" || return 1
  done

  if [[ "$NAMED" == *" $service "* || -n "$(project_containers "$service")" ]]; then
    ORDER+=("$service")
  fi
}
