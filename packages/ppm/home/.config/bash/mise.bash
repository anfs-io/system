# mise activation for bash (core/ppm; ppm installs mise as a core component).
# Aliases are in .config/sh/mise.sh.

command -v mise >/dev/null 2>&1 || return

eval "$(mise activate bash)"
