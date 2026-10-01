#!/usr/bin/env bash
# pcm library: the implode command
# Sourced by ~/.local/bin/pcm; defines functions only.

# `pcm implode [-y]`: delete everything pcm has created on this machine, whichever definition it
# came from. Unlike remove it works from the runtime labels, not the definitions, so containers
# whose definition is gone (a source removed, a link dangling) go too. Deprovision hooks are not
# run: whatever they would undo lives in a dependency that is being deleted as well.
#   - every container labelled io.pcm.name, and the compose networks and volumes of those projects
#   - the shared network
#   - $PCM_DATA_HOME (service data), $PCM_STATE_HOME, $PCM_CACHE_HOME, $PCM_CONFIG_HOME
#   - on macOS, the podman machine, when pcm created it (a machine that predates pcm is kept)
# Pulled images and podman itself are left alone (podman goes with ppm's implode).
cmd_implode() {
  local yes=false arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) yes=true ;;
      *) echo "Usage: pcm implode [-y]" >&2; return 1 ;;
    esac
  done

  local have_podman=false projects="" network="dev-net" machine=false
  [[ "$OSTYPE" == darwin* && -f "$PCM_STATE_HOME/machine-created" ]] && command -v podman >/dev/null 2>&1 && machine=true
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    have_podman=true
    projects=$(podman ps -a --filter "label=$PCM_LABEL_NAME" \
      --format "{{index .Labels \"$PCM_LABEL_NAME\"}}" 2>/dev/null | sort -u | paste -sd ' ' -) || true
  fi
  [[ -f "$PCM_CONFIG_HOME/registry.yml" ]] \
    && network=$(yq eval '.shared_network // "dev-net"' "$PCM_CONFIG_HOME/registry.yml" 2>/dev/null || echo dev-net)

  {
    echo "pcm implode removes:"
    if $have_podman; then
      echo "  services     ${projects:-none running or stopped} (containers, networks, volumes, snapshots)"
      echo "  network      $network"
    else
      echo "  services     podman is not reachable; containers, if any, are left"
    fi
    local dir
    $machine && echo "  machine      the podman machine pcm created"
    for dir in "$PCM_DATA_HOME" "$PCM_STATE_HOME" "$PCM_CACHE_HOME" "$PCM_CONFIG_HOME"; do
      [[ -e "$dir" ]] && echo "  directory    $(tilde "$dir")"
    done
    echo "Kept: pulled images, podman$($machine || echo ' and its machine')"
  } >&2

  if ! $yes; then
    [[ -t 0 ]] || { echo "pcm: implode deletes all pcm data; pass -y to confirm without a terminal" >&2; return 1; }
    local answer
    read -r -p "Implode pcm? [y/N] " answer
    [[ "$answer" == [yY]* ]] || { echo "pcm: nothing removed" >&2; return 1; }
  fi

  local rc=0 project ids
  if $have_podman; then
    for project in $projects; do
      echo "pcm: removing $project" >&2
      ids=$(podman ps -aq --filter "label=$PCM_LABEL_NAME=$project")
      [[ -z "$ids" ]] || podman rm -f -v $ids >/dev/null || rc=1
      _implode_project_objects "$project" || rc=1
    done
    if podman network exists "$network" 2>/dev/null; then
      podman network rm -f "$network" >/dev/null || rc=1
    fi
    # Snapshot images are pcm's own (pulled images are not)
    ids=$(podman images -q --filter "label=$PCM_LABEL_SNAPSHOT" 2>/dev/null | sort -u)
    [[ -z "$ids" ]] || podman rmi -f $ids >/dev/null || rc=1
  fi

  # Service data first: rootless podman leaves subuid-owned files only `podman unshare` removes
  remove_data_dir "$PCM_VOLUMES_HOME" || rc=1
  if $machine; then
    echo "pcm: removing the podman machine" >&2
    podman machine rm -f >/dev/null 2>&1 || { echo "pcm: podman machine rm failed" >&2; rc=1; }
  fi
  for dir in "$PCM_DATA_HOME" "$PCM_STATE_HOME" "$PCM_CACHE_HOME" "$PCM_CONFIG_HOME"; do
    [[ -e "$dir" ]] || continue
    echo "pcm: deleting $(tilde "$dir")" >&2
    rm -rf "${dir:?}" || rc=1
  done
  [[ $rc -eq 0 ]] && echo "pcm imploded" >&2
  return $rc
}

# The networks and named volumes compose created for a project (it labels them with the project)
_implode_project_objects() {
  local project="$1" rc=0 obj
  for obj in $(podman network ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null); do
    podman network rm -f "$obj" >/dev/null || rc=1
  done
  for obj in $(podman volume ls -q --filter "label=com.docker.compose.project=$project" 2>/dev/null); do
    podman volume rm -f "$obj" >/dev/null || rc=1
  done
  return $rc
}
