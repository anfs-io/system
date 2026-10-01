#!/usr/bin/env bash
# pcm library: shell completion; the completion command
# Sourced by ~/.local/bin/pcm; defines functions only.

cmd_completion() {
  case "${1:-}" in
    zsh)
      cat <<'COMPLETION'
#compdef pcm

_pcm_services() {
  local -a services=(${(f)"$(command pcm list --names 2>/dev/null)"})
  compadd -a services
}

_pcm() {
  local -a subcmds=(
COMPLETION
      cli_zsh_commands
      cat <<'COMPLETION'
  )

  if (( CURRENT == 2 )); then
    _describe 'command' subcmds
    return
  fi

  case "${words[2]}" in
    up)          _pcm_services ;;
    down)        compadd -- --force; _pcm_services ;;
    validate|ps) _pcm_services ;;
    remove|rm)   compadd -- -y --force; _pcm_services ;;
    path|cd|show) (( CURRENT == 3 )) && _pcm_services ;;
    completion)  (( CURRENT == 3 )) && compadd zsh ;;
  esac
}

if [[ "${funcstack[1]}" == "_pcm" ]]; then
  _pcm "$@"
else
  compdef _pcm pcm
fi
COMPLETION
      ;;
    *)
      echo "Usage: pcm completion <zsh>" >&2
      return 1
      ;;
  esac
}
