#!/usr/bin/env bash
# pim library: shell completion; the completion command. Sourced by ~/.local/bin/pim; functions only.

cmd_completion() {
  case "${1:-}" in
    zsh)
      cat <<'COMPLETION'
#compdef pim

_pim_images() {
  local -a images=(${(f)"$(command pim list --names 2>/dev/null)"})
  compadd -a images
}

_pim() {
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
    build)       compadd -- -f --arch --console --verify; _pim_images ;;
    up|run)      compadd -- --fresh --snapshot --console --share -p --arch; _pim_images ;;
    rm)          compadd -- -y -f; _pim_images ;;
    reset)       compadd -- -y; (( CURRENT == 3 || CURRENT == 4 )) && _pim_images ;;
    publish)     compadd -- -c -o --arch; _pim_images ;;
    validate|install|down|stop|verify) _pim_images ;;
    path|cd|show|shell|ssh|snapshot) (( CURRENT == 3 )) && _pim_images ;;
    clean)       compadd -- --isos ;;
    completion)  (( CURRENT == 3 )) && compadd zsh ;;
  esac
}

if [[ "${funcstack[1]}" == "_pim" ]]; then
  _pim "$@"
else
  compdef _pim pim
fi
COMPLETION
      ;;
    *)
      echo "Usage: pim completion <zsh>" >&2
      return 1
      ;;
  esac
}
