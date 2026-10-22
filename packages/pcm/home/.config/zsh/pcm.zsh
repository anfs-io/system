# pcm.zsh — pcm's zsh-only integration: exports, completion, cconf and the podman compose --pcm
# wrapper. The `pcm cd` wrapper is portable and lives in ~/.config/sh/pcm.sh.

export PCM_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/pcm"
export PCM_CONTAINERS_HOME="$PCM_CONFIG_HOME/containers"

export PCM_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/pcm"
export PCM_VOLUMES_HOME="$PCM_DATA_HOME/volumes"

export PCM_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/pcm"

zcomp pcm

cconf() {
  local dir=$PCM_CONTAINERS_HOME file="../pcm.local.env" ext="compose.yml"
  load_conf "$@"
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
