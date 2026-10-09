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

# What `remove` will do to service $1, for the confirmation
remove_summary() {
  local id="$1" name c spec dep size data users=""
  name=$(svc_name "$id")
  echo "$id:"

  local containers
  containers=$(project_containers "$id" -a | paste -sd ' ' -) || true
  echo "  containers   ${containers:-none}"

  data="$PCM_VOLUMES_HOME/$name"
  if [[ -d "$data" ]]; then
    size=$(du -sh "$data" 2>/dev/null | cut -f1)
    echo "  data         $(tilde "$data")  $size  (deleted)"
  fi

  if yq eval -e '[.services[] | select(has("build"))] | length > 0' "$(compose_file "$id")" >/dev/null 2>&1; then
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
# for them — containers, networks, anonymous volumes, images compose built, their data dir and
# generated override — and run each dependency's deprovision hook. Running dependents are stopped
# first, which needs --force. The definition, its env override and its source are never touched.
cmd_remove() {
  local yes=false force=false arg id
  local -a services=()
  for arg in "$@"; do
    case "$arg" in
      -y|--yes)   yes=true ;;
      -f|--force) force=true ;;
      -*)         echo "pcm: remove: unknown option '$arg'" >&2; return 1 ;;
      *)
        if ! id=$(canon "$arg"); then
          echo "pcm: unknown service '$arg' (see: pcm list)" >&2
          return 1
        fi
        services+=("$id")
        ;;
    esac
  done
  if [[ ${#services[@]} -eq 0 ]]; then
    echo "Usage: pcm remove [-y] [-f|--force] <service>..." >&2
    return 1
  fi

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
    echo "pcm: not removing ${services[*]}: running services depend on it: ${dependents[*]}" >&2
    echo "pcm: stop those first, or pass --force to stop them before removing" >&2
    return 1
  fi

  {
    for id in "${services[@]}"; do remove_summary "$id"; done
    [[ ${#dependents[@]} -eq 0 ]] || echo "stopped first (not removed): ${dependents[*]}"
  } >&2

  if ! $yes; then
    if [[ ! -t 0 ]]; then
      echo "pcm: remove deletes data; pass -y to confirm without a terminal" >&2
      return 1
    fi
    local answer
    read -r -p "Remove? [y/N] " answer
    [[ "$answer" == [yY]* ]] || { echo "pcm: nothing removed" >&2; return 1; }
  fi

  export_podman_socket "${ORDER[@]}"
  local spec dep rc=0
  for id in "${ORDER[@]}"; do
    PROVISIONED=()
    compose_flags "$id" || return 1

    if [[ "$NAMED" != *" $id "* ]]; then
      echo "pcm: stopping dependent service $id" >&2
      compose_run "$id" "${FLAGS[@]}" down || { echo "pcm: failed to stop $id; nothing more removed" >&2; return 1; }
      continue
    fi

    echo "pcm: removing $id" >&2
    compose_run "$id" "${FLAGS[@]}" down --volumes --remove-orphans --rmi local || {
      echo "pcm: failed to remove $id's containers; its data is kept" >&2
      rc=1
      continue
    }

    # After the service is down, so nothing holds what is being deprovisioned open
    while IFS= read -r spec; do
      [[ -n "$spec" ]] || continue
      dep=$(canon "$spec") || continue
      has_hook deprovision "$dep" || continue
      [[ -n "$(project_containers "$dep")" ]] || continue
      run_hook deprovision "$id" "$dep" "$spec" >&2 || { echo "pcm: deprovisioning $dep for $id failed" >&2; rc=1; }
    done < <(service_deps "$id")
    edges_unpublish "$id" || rc=1

    remove_data_dir "$PCM_VOLUMES_HOME/$(svc_name "$id")" || { echo "pcm: could not delete $id's data" >&2; rc=1; }
    rm -f "$(override_file "$id")"
    snapshot_forget "$id"
  done
  return $rc
}
