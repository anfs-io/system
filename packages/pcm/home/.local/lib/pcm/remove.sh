#!/usr/bin/env bash
# pcm library: the remove command
# Sourced by ~/.local/bin/pcm; defines functions only.

# Delete a service's data dir. Rootless podman on Linux leaves files owned by subuids, which only
# `podman unshare` can remove; on macOS the files are the user's.
remove_data_dir() {
  local dir="$1"
  [[ -e "$dir" ]] || return 0
  if [[ "$OSTYPE" != darwin* ]] && command -v podman >/dev/null 2>&1; then
    podman unshare rm -rf "$dir"
  else
    rm -rf "$dir"
  fi
}

# Whether service $1's definition builds an image (a service with build:)
builds_images() {
  yq eval -e '[.services[] | select(has("build"))] | length > 0' "$(compose_file "$1")" >/dev/null 2>&1
}

# What `remove` will do to service $1, for the confirmation
remove_summary() {
  local id="$1" name c spec dep size data users=""
  name=$(svc_name "$id")
  echo "$id:"

  local containers
  containers=$(project_containers "$id" -a | paste -sd ' ' -) || true
  echo "  containers   ${containers:-none}"
  containers=$(oneoff_containers "$id" | paste -sd ' ' -) || true
  [[ -z "$containers" ]] || echo "  one-offs     $containers"

  data="$PCM_VOLUMES_HOME/$name"
  if [[ -d "$data" ]]; then
    size=$(du -sh "$data" 2>/dev/null | cut -f1)
    echo "  data         $(tilde "$data")  $size  (deleted)"
  fi
  [[ ! -f "$(pcm_state_env "$id")" ]] || echo "  state        $(tilde "$(pcm_state_env "$id")")  (deleted; fetched again on up)"

  if builds_images "$id"; then
    echo "  images       the ones compose built (pulled images are kept)"
  fi

  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    dep=$(canon "$spec") || continue
    has_hook deprovision "$dep" || continue
    if [[ -n "$(project_containers "$dep")" ]]; then
      echo "  deprovision  $dep $(dep_settings "$id" "$spec" | paste -sd ' ' -)"
    else
      echo "  deprovision  $dep is not running; what it provisioned is left in place"
    fi
  done < <(service_deps "$id")

  while IFS= read -r c; do users+="${users:+, }$c"; done < <(service_dependents "$id")
  [[ -z "$users" ]] || echo "  used by      $users  (anything they keep in $name goes with it)"
  return 0
}

# `pcm remove <service>... [-y] [-f|--force]`: stop the services and delete everything pcm created
# for them — containers (`pcm run`'s one-offs too), networks, anonymous volumes, images compose built, their data dir and
# generated override, what pcm recorded for them (state.env) — and run each dependency's
# deprovision hook. Running dependents are stopped first, which needs --force. The definition, its
# local.env and its source are never touched.
cmd_remove() {
  local yes=${CLI_OPT[yes]:-false} force=${CLI_OPT[force]:-false} arg id
  local -a services=()
  for arg in "$@"; do
    if ! id=$(canon "$arg"); then
      anfs_warn "unknown service '$arg' (see: pcm list)"
      return 1
    fi
    services+=("$id")
  done

  # Running dependents stop first, as with down
  NAMED=" ${services[*]} "
  ORDER=()
  for id in "${services[@]}"; do
    shutdown_order "$id" || return 1
  done
  local -a dependents=()
  for id in "${ORDER[@]}"; do
    [[ "$NAMED" == *" $id "* ]] || dependents+=("$id")
  done
  if [[ ${#dependents[@]} -gt 0 && "$force" != true ]]; then
    anfs_warn "not removing ${services[*]}: running services depend on it: ${dependents[*]}"
    anfs_warn "stop those first, or pass --force to stop them before removing"
    return 1
  fi

  {
    for id in "${services[@]}"; do remove_summary "$id"; done
    [[ ${#dependents[@]} -eq 0 ]] || echo "stopped first (not removed): ${dependents[*]}"
  } >&2

  $yes || anfs_confirm "remove deletes data" "Remove?"

  export_podman_socket "${ORDER[@]}"
  local spec dep oneoffs rc=0
  local -a rmi
  for id in "${ORDER[@]}"; do
    PROVISIONED=()
    compose_flags "$id" || return 1

    if [[ "$NAMED" != *" $id "* ]]; then
      anfs_warn "stopping dependent service $id"
      compose_run "$id" "${FLAGS[@]}" down || { anfs_warn "failed to stop $id; nothing more removed"; return 1; }
      continue
    fi

    anfs_warn "removing $id"
    # pcm run's one-offs first, whatever the compose provider's down does with them
    oneoffs=$(oneoff_containers "$id" | paste -sd ' ' -) || true
    [[ -z "$oneoffs" ]] || podman rm -f $oneoffs >/dev/null || { anfs_warn "failed to remove $id's one-offs: $oneoffs"; rc=1; }
    # --rmi local only with something compose built: podman-compose takes the images from the
    # project's containers and runs `podman rmi` even with none ("image name or ID must be specified")
    rmi=()
    if builds_images "$id" && [[ -n "$(project_containers "$id" -a)" ]]; then rmi=(--rmi local); fi
    compose_run "$id" "${FLAGS[@]}" down --volumes --remove-orphans ${rmi[@]+"${rmi[@]}"} || {
      anfs_warn "failed to remove $id's containers; its data is kept"
      rc=1
      continue
    }

    # After the service is down, so nothing holds what is being deprovisioned open
    while IFS= read -r spec; do
      [[ -n "$spec" ]] || continue
      dep=$(canon "$spec") || continue
      has_hook deprovision "$dep" || continue
      [[ -n "$(project_containers "$dep")" ]] || continue
      run_hook deprovision "$id" "$dep" "$spec" >&2 || { anfs_warn "deprovisioning $dep for $id failed"; rc=1; }
    done < <(service_deps "$id")
    edges_unpublish "$id" || rc=1

    remove_data_dir "$PCM_VOLUMES_HOME/$(svc_name "$id")" || { anfs_warn "could not delete $id's data"; rc=1; }
    rm -f "$(override_file "$id")" "$(ONEOFF=true override_file "$id")"
    # what pcm recorded for it (a tunnel token: fetched again on the next up)
    rm -rf "${PCM_STATE_HOME:?}/containers/$(svc_name "$id")"
    snapshot_forget "$id"
  done
  return $rc
}
