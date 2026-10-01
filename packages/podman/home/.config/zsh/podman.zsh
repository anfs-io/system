# podman.zsh

# disables podman compose notification
export PODMAN_COMPOSE_WARNING_LOGS=false

zcomp podman

if [[ "$(os)" == "macos" ]] && [[ "$(podman machine inspect --format '{{.State}}' 2>/dev/null)" != "running" ]]; then
  podman machine start
fi

# podman
alias pps="podman ps"
alias ppsa="pps --all"
alias prm="podman rm"

# podman compose
alias pc="podman compose $@"
alias pcd="pc down $@"
alias pcu="pc \up $@"
alias pcud="pc \up - $@"

# docker
alias docker=podman

# export DOCKER_HOST="unix://$HOME/.local/share/containers/podman/machine/podman.sock"
