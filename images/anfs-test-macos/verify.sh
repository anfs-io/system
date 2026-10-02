#!/bin/bash
# The macOS test box: both test users, their ssh access, sudo's relaxed timestamp, /src
set -euo pipefail
id owner >/dev/null && dseditgroup -o checkmember -m owner admin >/dev/null && echo "ok  owner exists and is an admin"
id other >/dev/null && ! dseditgroup -o checkmember -m other admin >/dev/null && echo "ok  other exists and is not"
grep -q ssh-ed25519 /Users/owner/.ssh/authorized_keys /Users/other/.ssh/authorized_keys && echo "ok  both users accept the image's key"
visudo -cf /etc/sudoers.d/ppm-vm >/dev/null && echo "ok  sudoers drop-in parses"
[ -L /src ] && echo "ok  /src links to the shared folders"
! command -v brew >/dev/null && ! xcode-select -p >/dev/null 2>&1 && echo "ok  no Homebrew, no Xcode CLT (vanilla)"
