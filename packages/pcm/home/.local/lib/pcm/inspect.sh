#!/usr/bin/env bash
# pcm library: inspecting what pcm runs; the ps and show commands
# Sourced by ~/.local/bin/pcm; defines functions only.

# Every container pcm created (running or not), one per line: id|name|state|pcm-id|status.
# Fails when podman is unreachable, so callers can degrade instead of erroring.
pcm_containers() {
  local json
  json=$(podman ps -a --filter "label=$PCM_LABEL_ID" --format json 2>/dev/null) || return 1
  [[ -n "$json" ]] || return 0
  yq -p json -o tsv '.[] | [.Id, .Names[0], .State, .Labels["'"$PCM_LABEL_ID"'"], .Status] | join("|")' <<< "$json" |
    tr -d '\t'
}

# $HOME shown as ~
tilde() { anfs_display "$1"; }

# `pcm ps [service...] [podman ps flags]`: podman ps limited to pcm's containers, or to the
# named services' (by name, whichever definition started them)
cmd_ps() {
  local -a names=() flags=() filters=()
  local arg id c
  for arg in "$@"; do
    if id=$(canon "$arg"); then names+=("$(svc_name "$id")"); else flags+=("$arg"); fi
  done

  if [[ ${#names[@]} -eq 0 ]]; then
    exec podman ps --filter "label=$PCM_LABEL_ID" ${flags[@]+"${flags[@]}"}
  fi

  # Repeated label filters AND in podman, repeated id filters OR: select by id
  for arg in "${names[@]}"; do
    while IFS= read -r c; do
      [[ -n "$c" ]] && filters+=(--filter "id=$c")
    done < <(podman ps -aq --filter "label=$PCM_LABEL_NAME=$arg")
  done
  if [[ ${#filters[@]} -eq 0 ]]; then
    anfs_warn "no containers for ${names[*]}"
    return 0
  fi
  exec podman ps "${filters[@]}" ${flags[@]+"${flags[@]}"}
}

# State of a service name's containers: running, stopped (created but none running), or empty
name_state() {
  local name="$1" containers="$2" _id cname state pid _status any=false
  while IFS='|' read -r _id cname state pid _status; do
    [[ -n "$pid" && "$(svc_name "$pid")" == "$name" ]] || continue
    [[ "$state" == running ]] && { echo running; return; }
    any=true
  done <<< "$containers"
  $any && echo stopped
  return 0
}

# One line per id: `id (state)` or just the id
ids_with_state() {
  local containers="$1" id state out=""
  shift
  for id in "$@"; do
    state=$(name_state "$(svc_name "$id")" "$containers")
    out+="${out:+, }$id${state:+ ($state)}"
  done
  echo "${out:-—}"
}

# Images of service $1, one per line: compose-service|image, expanded with its resolved env;
# a service with build: gives "built from <context>/<dockerfile>" (Containerfile by default)
service_images() {
  local id="$1" key image ctx file
  while IFS='|' read -r key image ctx file; do
    [[ -n "$key" ]] || continue
    if [[ -n "$image" && -z "$ctx" ]]; then
      ctx=$(expand_vars "$id" "$image")
      # An env that does not resolve leaves ":"; the declared form says more
      [[ "$ctx" == :* || -z "$ctx" ]] && ctx="$image"
      echo "$key|$ctx"
    elif [[ -n "$ctx" ]]; then
      echo "$key|built from ${ctx%/}/${file:-Containerfile}"
    fi
  done < <(yq eval '.services // {} | to_entries | .[] | .key + "|" + (.value.image // "") + "|" +
    ((.value.build | select(tag == "!!str")) // .value.build.context // "") + "|" +
    (.value.build.dockerfile // "")' "$(compose_file "$id")" 2>/dev/null)
}

# Names service $1's .env.schema declares (never values): "env|NAME" or "secret|NAME" lines,
# secret when the item (or the header's @defaultSensitive=true) marks it sensitive
schema_names() {
  local schema line def=false sens=""
  schema="$(svc_dir "$1")/.env.schema"
  [[ -f "$schema" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      *@defaultSensitive=true*) def=true ;;
    esac
    if [[ "$line" =~ ^#.*@sensitive=false ]]; then sens=false
    elif [[ "$line" =~ ^#.*@sensitive([[:space:]]|=true|$) ]]; then sens=true
    elif [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
      [[ "${sens:-$def}" == true ]] && echo "secret|${BASH_REMATCH[1]}" || echo "env|${BASH_REMATCH[1]}"
      sens=""
    elif [[ -z "$line" ]]; then sens=""
    fi
  done < "$schema"
}

# `pcm show <service>`: the definition, its images, env names, dependencies, data, and its
# containers with ports and mounts; when nothing is created yet, the ports and mounts it declares
cmd_show() {
  local id
  if ! id=$(canon "$1"); then
    anfs_warn "unknown service '$1' (see: pcm list)"
    return 1
  fi

  local name dir winner other containers="" reachable=true
  name=$(svc_name "$id")
  dir=$(svc_dir "$id")
  winner=$(canon "$name")
  containers=$(pcm_containers) || reachable=false

  local -a deps=() users=() others=()
  while IFS= read -r other; do [[ -n "$other" ]] && deps+=("$other"); done < <(dep_ids "$id")
  while IFS= read -r other; do [[ -n "$other" ]] && users+=("$other"); done < <(service_dependents "$id")
  while IFS= read -r other; do
    [[ "$other" != "$id" && "$(svc_name "$other")" == "$name" ]] && others+=("$other")
  done < <(all_ids)

  # Which definition the containers came from, when not this one
  local state from="" _cid _cname _state pid _status
  state=$(name_state "$name" "$containers")
  while IFS='|' read -r _cid _cname _state pid _status; do
    [[ -n "$pid" && "$(svc_name "$pid")" == "$name" && "$pid" != "$id" ]] && { from="$pid"; break; }
  done <<< "$containers"

  local data="$PCM_VOLUMES_HOME/$name" size=""
  [[ -d "$data" ]] && size=$(du -sh "$data" 2>/dev/null | cut -f1)

  printf '%s  %s\n' "$id" "$(tilde "$dir")"
  local mk mi=0
  manifest_fields "$id"
  for mk in $PCM_MANIFEST_KEYS; do
    [[ -n "${MANIFEST[$mi]}" ]] && printf '  %-12s %s\n' "$mk" "${MANIFEST[$mi]}"
    [[ "$mk" == version && -z "${MANIFEST[$mi]}" ]] && printf '  %-12s %s\n' version "- (no container.yml)"
    mi=$((mi + 1))
  done
  load_env "$id" 2>/dev/null || true
  local images ikey img
  images=$(service_images "$id")
  while IFS='|' read -r ikey img; do
    [[ -n "$ikey" ]] && printf '  %-12s %s%s\n' image "$img" \
      "$([[ $(grep -c . <<< "$images") -gt 1 ]] && echo " in $ikey")"
  done <<< "$images"
  local status="unknown (podman unreachable)"
  $reachable && status="${state:-not created}${from:+ from $from}"
  printf '  %-12s %s\n' status "$status"
  [[ "$winner" != "$id" ]] && printf '  %-12s %s\n' "shadowed by" "$winner"
  [[ ${#others[@]} -gt 0 ]] && printf '  %-12s %s\n' "also in" "${others[*]}"
  printf '  %-12s %s\n' "depends on" "$(ids_with_state "$containers" ${deps[@]+"${deps[@]}"})"
  printf '  %-12s %s\n' "used by" "$(ids_with_state "$containers" ${users[@]+"${users[@]}"})"
  printf '  %-12s %s\n' data "$(tilde "$data")${size:+  $size}$([[ -d "$data" ]] || echo '  (none yet)')"
  local settings
  settings=$(pcm_local_env "$id")
  [[ -f "$settings" ]] && printf '  %-12s %s\n' settings "$(tilde "$settings")"
  local names vars secrets
  names=$(schema_names "$id")
  vars=$(sed -n 's/^env|//p' <<< "$names" | paste -sd ' ' -)
  secrets=$(sed -n 's/^secret|//p' <<< "$names" | paste -sd ' ' -)
  [[ -n "$vars" ]] && printf '  %-12s %s\n' "reads env" "$vars"
  [[ -n "$secrets" ]] && printf '  %-12s %s\n' secrets "$secrets"
  local role icsvc iport proxy
  role=$(service_role "$id")
  [[ -n "$role" ]] && printf '  %-12s %s\n' provides "$role"
  if has_ingress "$id"; then
    IFS='|' read -r icsvc iport _ _ < <(service_ingress "$id") || true
    proxy=$(active_proxy) || proxy="no proxy"
    printf '  %-12s %s -> %s:%s (via %s)\n' ingress "$(ingress_hosts "$id" | sed 's/,/, /g')" "$icsvc" "$iport" "$proxy"
  fi
  local pkey preason pset pcsvc ptarget pro snaps
  while IFS='|' read -r pkey preason; do
    [[ -n "$pkey" ]] && printf '  %-12s %s: %s\n' privilege "$pkey" "$preason"
  done < <(declared_privileges "$id")
  while IFS='|' read -r pset pcsvc ptarget pro; do
    [[ -n "$pset" ]] && printf '  %-12s %s at %s%s%s\n' mounts "$pset" "$ptarget" \
      "$([[ "$pro" == true ]] && echo ' (read-only)')" "${pcsvc:+ in $pcsvc}"
  done < <(mount_sets "$id")
  snaps=$(cmd_snapshot "$id" | paste -sd ' ' - | tr -s ' ')
  [[ -z "${snaps// /}" ]] || printf '  %-12s %s\n' snapshots "$snaps"

  if [[ -n "$state" ]]; then
    echo
    echo containers
    podman ps -a --filter "label=$PCM_LABEL_NAME=$name" --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' |
      column -t -s $'\t'
    local c mounts
    mounts=$(
      while IFS= read -r c; do
        podman inspect --format '{{range .Mounts}}{{$.Name}}	{{.Source}} -> {{.Destination}}{{if not .RW}} (ro){{end}}
{{end}}' "$c"
      done < <(project_containers "$id" -a) | sed "s|$HOME|~|g; /^$/d; s/^/  /"
    )
    if [[ -n "$mounts" ]]; then
      echo mounts
      column -t -s $'\t' <<< "$mounts"
    fi
  else
    show_declared "$id"
  fi
}

# The ports and mounts service $1 declares, expanded with its resolved env
show_declared() {
  local id="$1" key entry type src target ro
  load_env "$id" 2>/dev/null || true
  echo
  echo "declared (not created)"
  {
  while IFS='|' read -r key entry; do
    printf '  %s\tport\t%s\n' "$key" "$(expand_vars "$id" "$entry")"
  done < <(yq eval '.services // {} | to_entries | .[] | .key as $k | (.value.ports // [])[] |
    ((select(tag != "!!map") | $k + "|" + tostring),
     (select(tag == "!!map") | $k + "|" + ((.published // "") | tostring) + ":" + (.target | tostring)))' "$(compose_file "$id")")
  while IFS='|' read -r key type src target ro; do
    [[ "$type" == tmpfs ]] && continue
    src=$(expand_vars "$id" "$src")
    printf '  %s\tmount\t%s -> %s%s\n' "$key" "$(tilde "$src")" "$target" "$([[ "$ro" == true ]] && echo ' (ro)')"
  done < <(service_mounts "$id")
  } 2>/dev/null | column -t -s $'\t'
}
