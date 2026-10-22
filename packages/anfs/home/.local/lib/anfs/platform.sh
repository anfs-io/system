#!/usr/bin/env bash
# anfs: which platform this is, the one answer every tool gives (ppm's package.yml platforms:, the
# platforms: of links: and files: entries, wsm's space.yml, package hooks' install_<os>)
#
# BOOTSTRAP SET: install.sh sources this under whatever bash started it, which on a vanilla Mac is
# 3.2. Keep it parseable and runnable there: no bash 4+ syntax (see bash.sh). Functions only.
#
#   platform   macos, or the supported distro family: debian, fedora; else unsupported. The value
#              is also the key of per-platform maps and lists in package.yml
#   os         macos or linux (install_<os>/remove_<os> hooks); else unsupported
#
# Two functions where one would do: merging them is on the roadmap's "Last".

# macos, or the supported distro family from os-release (ID first, then ID_LIKE): debian (Debian
# and derivatives such as Ubuntu) or fedora (Fedora, and RHEL-family distros that declare
# ID_LIKE=fedora). PPM_OS_RELEASE points at another os-release (tests).
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

# The OS: linux or macos
os() {
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "linux"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  else
    echo "unsupported"
  fi
}
