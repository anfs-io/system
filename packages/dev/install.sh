# dev

# hooks() is stowed to ~/.local/lib/ppm/hooks.sh and normally sourced by ppm at startup — but on
# the run that first installs this package it did not exist yet, so load it from the package.
_dev_load_hooks() {
  declare -f cmd_hooks >/dev/null && return 0
  local lib="$(dirname "${BASH_SOURCE[0]}")/home/.local/lib/ppm/hooks.sh"
  [[ -f "$lib" ]] && source "$lib"
}

# Wire ppm's git hooks into the package repos. Hooks are not carried by git clone, so this runs
# on install rather than being part of a repo's contents; re-run `ppm hooks install` after
# `ppm src add`. user.list repos are opt-in (`ppm hooks install --all`).
post_install() {
  _dev_load_hooks || return 0
  echo "Wiring git hooks into the system.list repos:"
  cmd_hooks install || true
}

# Unset core.hooksPath again, but only in repos where ppm set it. The hook files are already
# unstowed by now; a leftover hooksPath pointing at a missing directory is harmless to git
# (commits just find no hooks), but leaving it behind would be untidy.
post_remove() {
  _dev_load_hooks || return 0
  echo "Removing git hooks from the package repos:"
  cmd_hooks uninstall --all || true
}
