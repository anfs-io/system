#!/usr/bin/env bash
# Platform: OS/distro detection, and Homebrew's location and ownership
#
# Homebrew supports one owner per installation. The owner installs and upgrades formulas;
# other users run the tools but never write to the prefix.

# Apple silicon macOS and Linux; Intel Macs (/usr/local) are not supported
PPM_BREW_PREFIXES="/opt/homebrew /home/linuxbrew/.linuxbrew"

# macos, or the supported distro family from os-release (ID first, then ID_LIKE):
# debian (Debian and derivatives such as Ubuntu) or fedora (Fedora, and RHEL-family distros
# that declare ID_LIKE=fedora). The value is also the key for per-platform maps in package.yml.
platform() {
  if [[ "$OSTYPE" == darwin* ]]; then
    echo "macos"
    return
  fi

  local os_release="${PPM_OS_RELEASE:-/etc/os-release}" candidates="" candidate
  [[ -r "$os_release" ]] && candidates=$(. "$os_release" && echo "${ID:-} ${ID_LIKE:-}")
  for candidate in $candidates; do
    case "$candidate" in
      debian|fedora) echo "$candidate"; return ;;
    esac
  done
  echo "unsupported"
}

# First Homebrew prefix that exists; prints nothing if Homebrew is not installed
brew_prefix() {
  local prefix
  for prefix in $PPM_BREW_PREFIXES; do
    if [[ -x "$prefix/bin/brew" ]]; then
      echo "$prefix"
      return 0
    fi
  done
  return 0
}

# Put Homebrew on PATH when ppm runs without the user's shell setup (cron, sudo -iu, env -i)
brew_env() {
  command -v brew >/dev/null 2>&1 && return 0
  local prefix
  prefix=$(brew_prefix)
  [[ -n "$prefix" ]] || return 0
  eval "$("$prefix/bin/brew" shellenv bash)"
}

# User that owns a Homebrew installation (its repository dir; on Apple silicon that is the prefix)
# Usage: brew_owner [prefix]   — returns 1 if Homebrew is not installed
brew_owner() {
  local prefix="${1:-$(brew_prefix)}" dir
  [[ -n "$prefix" ]] || return 1
  dir="$prefix/Homebrew"
  [[ -d "$dir" ]] || dir="$prefix"
  if [[ "$(os)" == "macos" ]]; then
    stat -f %Su "$dir"
  else
    stat -c %U "$dir"
  fi
}

# True when the current user owns the Homebrew installation
brew_is_owner() {
  local owner
  owner=$(brew_owner) || return 1
  [[ "$owner" == "$(id -un)" ]]
}

# Succeeds for the owner; otherwise reports who must run <action> and returns 1
# Usage: brew_require_owner "brew install jq"
brew_require_owner() {
  local action="$1" owner
  brew_is_owner && return 0
  if owner=$(brew_owner); then
    ppm_fail "Homebrew is owned by $owner; ask them to run: $action"
  else
    ppm_fail "Homebrew is not installed; it is needed to run: $action"
  fi
  return 1
}

# Refresh Homebrew's formula index at most every HOMEBREW_UPDATE_CACHE_DURATION seconds (owner only)
update_brew_if_needed() {
  if ! command -v brew >/dev/null 2>&1; then
    debug "Homebrew not found; skipping brew update"
    return 0
  fi
  if ! brew_is_owner; then
    debug "Homebrew is owned by $(brew_owner); skipping brew update"
    return 0
  fi

  local cache_duration="${HOMEBREW_UPDATE_CACHE_DURATION:-86400}" # default is 24 hours in seconds
  local cache_file="$PPM_CACHE_HOME/brew_last_update"

  if [[ ! -f "$cache_file" ]] || [[ $(($(date +%s) - $(cat "$cache_file"))) -gt $cache_duration ]]; then
    [[ ! -d $PPM_CACHE_HOME ]] && mkdir -p $PPM_CACHE_HOME
    brew update
    date +%s > "$cache_file"
  fi
}

# --- Package managers: install what is missing, never upgrade ---

# System packages from the arguments that are not installed, one per line
system_pkg_missing() {
  local pkg
  case "$(platform)" in
    debian)
      for pkg in "$@"; do
        [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" == "install ok installed" ]] || echo "$pkg"
      done
      ;;
    fedora)
      # --whatprovides also counts a package installed under another name that provides it
      # (e.g. zlib-devel, provided by zlib-ng-compat-devel)
      for pkg in "$@"; do
        rpm -q --whatprovides "$pkg" >/dev/null 2>&1 || echo "$pkg"
      done
      ;;
    macos) ;;
    *) printf '%s\n' "$@" ;;
  esac
}

# Install system packages with the distro package manager (prompts for sudo at most once)
system_pkg_install() {
  local what="$*"
  case "$(platform)" in
    debian)
      _system_sudo "$what" || return 1
      sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null &&
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" </dev/null
      ;;
    fedora)
      _system_sudo "$what" || return 1
      sudo dnf install -y "$@" </dev/null
      ;;
    *)
      ppm_fail "Installing system packages is not supported on $(platform): $what"
      return 1
      ;;
  esac
}

# Get sudo credentials with a normal prompt; on failure report what an admin has to do.
# Returns 0 with the credential cache primed, so the caller's real command can use `sudo -n` and
# never block an unattended install. $2 overrides the failure message for callers that need root
# for something other than a package install (pde/bash registers brew's bash in /etc/shells).
_system_sudo() {
  local what="$1"
  local msg="${2:-Installing system packages needs sudo; ask an admin to install: $what}"
  if command -v sudo >/dev/null 2>&1 && { sudo -n true 2>/dev/null || sudo -v; }; then
    return 0
  fi
  ppm_fail "$msg"
  return 1
}

# Brew formulas from the arguments that are not installed (tap-qualified names match their last part)
brew_missing() {
  local prefix name
  prefix=$(brew_prefix)
  for name in "$@"; do
    [[ -n "$prefix" && -e "$prefix/opt/${name##*/}" ]] || echo "$name"
  done
}

# Casks from the arguments that are not installed
# Homebrew installs casks on Linux too; a cask that is macOS-only (a GUI app) belongs
# under a platform map in package.yml rather than being skipped here
cask_missing() {
  local prefix name
  prefix=$(brew_prefix)
  for name in "$@"; do
    [[ -n "$prefix" && -d "$prefix/Caskroom/${name##*/}" ]] || echo "$name"
  done
}
