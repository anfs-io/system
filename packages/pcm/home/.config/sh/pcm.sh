# pcm.sh — pcm's portable shell integration. Sourced by both the bash and the zsh rc; the
# zsh-only parts (exports, completion, the podman --pcm wrapper) live in .config/zsh/pcm.zsh.

command -v pcm >/dev/null 2>&1 || return 0

# Wrapper to handle `pcm cd` through _anfs_cd (anfs.sh); no service: the containers directory.
pcm() {
  if [ "${1:-}" = "cd" ]; then
    shift
    _anfs_cd pcm "${PCM_CONTAINERS_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/pcm/containers}" "$@"
  else
    command pcm "$@"
  fi
}
