#!/bin/bash
# pim default verification (Debian): runs as root in a throwaway boot of the build
set -euo pipefail
test -f /etc/pim-image && echo "ok  built by pim: $(tr '\n' ' ' < /etc/pim-image)"
systemctl is-active --quiet ssh && echo "ok  ssh is running"
test -s /etc/ssh/ssh_host_ed25519_key && echo "ok  host keys were generated on this boot"
test -s /etc/machine-id && echo "ok  machine-id was generated on this boot"
dpkg -s qemu-guest-agent >/dev/null && echo "ok  qemu-guest-agent installed"
sudo -n -u "${PIM_USER:-pim}" true && echo "ok  ${PIM_USER:-pim} has passwordless sudo"
