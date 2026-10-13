#!/bin/bash
# pmm default test (Debian): runs as root in a throwaway boot of the build
set -euo pipefail
test -f /etc/pmm-image && echo "ok  built by pmm: $(tr '\n' ' ' < /etc/pmm-image)"
systemctl is-active --quiet ssh && echo "ok  ssh is running"
test -s /etc/ssh/ssh_host_ed25519_key && echo "ok  host keys were generated on this boot"
test -s /etc/machine-id && echo "ok  machine-id was generated on this boot"
systemctl is-active --quiet dhcpcd && echo "ok  dhcpcd looks after every interface"
dpkg -s qemu-guest-agent >/dev/null && echo "ok  qemu-guest-agent installed"
sudo -n -u "${PIM_USER:-pmm}" true && echo "ok  ${PIM_USER:-pmm} has passwordless sudo"
