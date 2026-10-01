# pcm.zsh — Personal Container Manager shell function: pcm cd, and the podman compose --pcm wrapper

export PCM_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/pcm"
export PCM_CONTAINERS_HOME="$PCM_CONFIG_HOME/containers"

export PCM_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/pcm"
export PCM_VOLUMES_HOME="$PCM_DATA_HOME/volumes"

export PCM_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/pcm"

zcomp pcm

cconf() {
  local dir=$PCM_CONTAINERS_HOME file="../registry.yml" ext="compose.yml"
  load_conf "$@"
}

# Wrapper to handle `pcm cd` since subshells can't change parent directory
pcm() {
  if [[ "${1:-}" == "cd" ]]; then
    shift
    if [[ $# -eq 0 ]]; then
      builtin cd "$PCM_CONTAINERS_HOME"
    else
      local service_path
      service_path=$(command pcm path "$@") || return $?
      builtin cd "$service_path"
    fi
  else
    command pcm "$@"
  fi
}

# --- podman / podman-compose --pcm integration ------------------------------
# Plain podman commands pass straight through. Add `--pcm` anywhere to a compose
# command and it is handed to `pcm` to resolve pcm-provided services:
#
#   podman compose up postgres          # stock podman, cwd compose file
#   podman compose up --pcm postgres    # pcm-provided postgres (same as `pcm up postgres`)
#   podman compose --pcm logs -f postgres glitchtip

podman() {
  if (( ${argv[(Ie)--pcm]} )); then
    local -a args=("${(@)argv:#--pcm}")
    if [[ "${args[1]}" == "compose" ]]; then
      PCM_COMPOSE="podman compose" command pcm __compose "${(@)args[2,-1]}"
      return $?
    fi
    echo "pcm: --pcm only applies to 'podman compose'; ignoring it" >&2
    command podman "${args[@]}"
    return $?
  fi

  command podman "$@"
}

podman-compose() {
  if (( ${argv[(Ie)--pcm]} )); then
    PCM_COMPOSE="podman-compose" command pcm __compose "${(@)argv:#--pcm}"
    return $?
  fi

  command podman-compose "$@"
}
