#!/usr/bin/env bash
# Core utility functions for ppm
#
# BOOTSTRAP SET: install.sh sources this under whatever bash started it, which on a vanilla Mac is
# 3.2. Keep it parseable and runnable there: no bash 4+ syntax (see lib/anfs/bash.sh)

# Your customization repo is always the "user" source: created by `anfs onboard`, registered by
# `install.sh --repo <url>`, highest priority, and the default repo for `ppm file claim`
PPM_USER_REPO_ALIAS=user

# Detect the CPU architecture
arch() {
  local arch=$(uname -m)

  if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
    echo "arm64"
  else
    echo "amd64"
  fi
}

# os() is anfs's (lib/anfs/platform.sh), sourced before this file

# search in file and add/remove as requested
add_to_file() {
  local file="$1" dir="$(dirname "$1")"
  shift

  [[ -d "$dir" ]] || mkdir -p $dir
  [[ -f "$file" ]] || touch "$file"

  for string in "$@"; do
    _string_in_file "$string" "$file" || echo "$string" >> "$file"
  done
}

remove_from_file() {
  local file="$1"
  shift
  [[ -f "$file" ]] || return 0

  for string in "$@"; do
    if _string_in_file "$string" "$file"; then
      _sed_inplace "/^$(printf '%s' "$string" | sed 's/[^^]/[&]/g; s/\^/\\^/g')$/d" "$file"
    fi
  done
}

_string_in_file() {
  local string="$1" file="$2"
  grep -qxF "$string" "$file" 2>/dev/null
}

_sed_inplace() {
  local pattern="$1" file="$2"

  # Resolve symlink to actual file
  if [[ -L "$file" ]]; then
    local link_target=$(readlink "$file")
    if [[ "$link_target" == /* ]]; then
      file="$link_target"
    else
      file="$(dirname "$file")/$link_target"
    fi
  fi

  if [[ "$(os)" == "macos" ]]; then
    sed -i '' "$pattern" "$file"
  else
    sed -i "$pattern" "$file"
  fi
}

# Install dependencies using the OS specific package manager (apt or homebrew)
# Debug output: on with -d/--debug (or ANFS_DEBUG, PPM_DEBUG). It is anfs's (lib/anfs/log.sh), which
# also writes it to the log; the fallback is for install.sh, which sources this file without it
PPM_DEBUG=${PPM_DEBUG:-false}

debug() {
  if declare -F anfs_debug >/dev/null; then anfs_debug "$@"; return 0; fi
  $PPM_DEBUG && echo -e "[DEBUG] $*" >&2 || true
}

# User message aggregation — packages call user_message() during install. In $TMPDIR (a job's own
# under anfs work run), /tmp when it is unset
PPM_MSG_FILE=$(mktemp "${TMPDIR:-/tmp}/ppm-messages.XXXXXX")
# (and the installer's skip list, installer.sh)
trap 'rm -f "$PPM_MSG_FILE" ${PPM_SKIP_FILE:+"$PPM_SKIP_FILE"}' EXIT

# Set by installer() before sourcing each package's install.sh
PPM_CURRENT_PACKAGE=""

user_message() {
  local prefix=""
  [[ -n "$PPM_CURRENT_PACKAGE" ]] && prefix="[$PPM_CURRENT_PACKAGE] "
  # Join args, stripping leading whitespace from each so backslash continuations work
  local msg=""
  for arg in "$@"; do
    msg="${msg}${arg#"${arg%%[![:space:]]*}"}"
  done
  echo "${prefix}${msg}" >> "$PPM_MSG_FILE"
}

flush_user_messages() {
  if [[ -s "$PPM_MSG_FILE" ]]; then
    echo ""
    echo "=== Package Messages ==="
    while IFS= read -r line; do
      # Extract prefix length for indenting continuation lines
      local padding=""
      if [[ "$line" =~ ^\[.*\]\  ]]; then
        local prefix_len=${#BASH_REMATCH}
        padding=$(printf '%*s' "$prefix_len" '')
      fi
      # Expand \n then indent continuation lines
      local expanded
      expanded=$(printf '%b' "$line")
      local first=true
      while IFS= read -r subline; do
        if $first; then
          echo "$subline"
          first=false
        else
          echo "${padding}${subline}"
        fi
      done <<< "$expanded"
    done < "$PPM_MSG_FILE"
    echo "========================"
  fi
  rm -f "$PPM_MSG_FILE"
}

# Called by packages to signal a non-fatal install failure.
# Logs the error immediately to stderr and queues it for end-of-run display.
# Usage (in a package install.sh):
#   ppm_fail "No pre-built binaries for arm64 Linux"
#   return
ppm_fail() {
  local prefix=""
  [[ -n "$PPM_CURRENT_PACKAGE" ]] && prefix="[$PPM_CURRENT_PACKAGE] "
  echo -e "${prefix}ERROR: $*" >&2
  user_message "ERROR: $*"
  return 1
}

# --- Post-run callbacks ---
#
# A package registers a function in its install.sh to hear about every later `ppm install` and
# `ppm remove`: once the whole run is done, ppm calls <function> <install|remove> <repo/pkg>...
# with every package that run installed (dependencies included) or removed. core/psm uses it to
# sync skills when an agent package comes or goes.
#
# The mechanism is anfs's (lib/anfs/callbacks.sh), shared with every tool that emits events: it
# owns the registrations ($ANFS_STATE_HOME/callbacks/ppm.yml, repo/pkg: function), the run loop and
# failure isolation. What is ppm's is here and in installer.sh: the package-facing names, and how
# a handler is run (ppm_callback_invoke: a function of the registering package's install.sh).

# Registrations used to live in $PPM_INSTALLED_DIR/callbacks.yml; move them once
_callbacks_migrate() {
  local old="$PPM_INSTALLED_DIR/callbacks.yml" new
  [[ -f "$old" ]] || return 0
  new=$(anfs_callbacks_file ppm)
  [[ ! -e "$new" ]] || return 0
  mkdir -p "$(dirname "$new")"
  mv "$old" "$new"
}

# Register the current package's callback; call it from post_install. Re-registering replaces it.
# Usage (in a package install.sh):
#   post_install() { ppm_register_callback my_pkg_changed; }
#   my_pkg_changed() { local event="$1"; shift; ... "$@" are repo/pkg names ...; }
ppm_register_callback() {
  local fn="${1:-}"
  if [[ -z "$fn" || -z "$PPM_CURRENT_PACKAGE" ]]; then
    ppm_fail "ppm_register_callback needs a function name and must be called from a package hook"
    return 1
  fi
  _callbacks_migrate
  anfs_callback_register ppm "$PPM_CURRENT_PACKAGE" "$fn"
}

# Drop the current package's callback. ppm does this itself when the package is removed.
ppm_unregister_callback() {
  _callback_unregister "$PPM_CURRENT_PACKAGE"
}

# Usage: _callback_unregister <repo/pkg>
_callback_unregister() {
  [[ -n "${1:-}" ]] || return 0
  _callbacks_migrate
  anfs_callback_unregister ppm "$1"
}
