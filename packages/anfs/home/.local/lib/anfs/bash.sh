#!/usr/bin/env bash
# anfs: the bash floor
#
# BOOTSTRAP SET: this file must parse and run under bash 3.2, the version macOS ships. It is what
# gets every tool off that bash, so it is the one file in lib/anfs that cannot assume the floor.
#
# Every anfs entry point sources this first, at top level and before anything written for bash 5:
#
#   source "$HOME/.local/lib/anfs/bash.sh"
#
# Under bash $ANFS_BASH_MIN or newer it does nothing. Under an older bash it re-execs the script
# with a newer one, or exits 69 (EX_UNAVAILABLE) saying how to get one. The floor is there on a
# Mac (install.sh brews bash before any tool runs); what goes wrong is PATH: macOS's path_helper
# demotes /opt/homebrew/bin below /bin in nested login shells and non-interactive ones, so
# `env bash` finds Apple's 3.2 again. That is why the search is by path, never `command -v bash`.
#
# Bash parses a script command by command, so everything after the `source` line may use bash 5
# syntax, as may every file sourced later.
#
#   ANFS_BASH_CANDIDATES   colon-separated bash paths to try instead of the built-in list (tests)

ANFS_BASH_MIN=5.2

# True when the running bash meets the floor
anfs_bash_ok() {
  [ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }
}

# The first bash that meets the floor, by path. Prints it; returns 1 when there is none.
anfs_bash_find() {
  local list candidate
  list="${ANFS_BASH_CANDIDATES-${HOMEBREW_PREFIX:+$HOMEBREW_PREFIX/bin/bash:}/opt/homebrew/bin/bash:/usr/local/bin/bash:/home/linuxbrew/.linuxbrew/bin/bash}"
  local IFS=:
  for candidate in $list; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016
    "$candidate" -c '[ "${BASH_VERSINFO[0]}" -gt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }' 2>/dev/null || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# Usage: anfs_bash_require <script> [args...]   (sourcing this file calls it with "$0" "$@")
anfs_bash_require() {
  local script="$1" newer
  shift
  if anfs_bash_ok; then
    # Children start clean: the marker is about this process only
    unset ANFS_BASH_REEXEC
    return 0
  fi
  # A candidate is only exec'd after its version is checked, so landing here again means the
  # check and the exec disagree. Stop rather than loop.
  if [ -n "${ANFS_BASH_REEXEC:-}" ]; then
    echo "${script##*/}: re-exec under $ANFS_BASH_REEXEC still runs bash $BASH_VERSION (need $ANFS_BASH_MIN+)" >&2
    exit 69
  fi
  if newer=$(anfs_bash_find); then
    ANFS_BASH_REEXEC="$newer" exec "$newer" "$script" "$@"
  fi
  echo "${script##*/}: needs bash $ANFS_BASH_MIN or newer, and this is $BASH_VERSION" >&2
  case "$(uname -s)" in
    Darwin) echo "${script##*/}: install one with: brew install bash" >&2 ;;
    *)      echo "${script##*/}: install one with your package manager, or: brew install bash" >&2 ;;
  esac
  exit 69
}

anfs_bash_require "$0" "$@"
