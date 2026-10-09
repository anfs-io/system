# mise aliases — portable (core/ppm; ppm installs mise as a core component).
# Activation is per-shell: see .config/zsh/mise.zsh and .config/bash/mise.bash.

command -v mise >/dev/null 2>&1 || return 0

alias mi="mise install"
alias mra="mise run all"
alias mtd="mise trust ."
alias mui="mise upgrade --interactive"
