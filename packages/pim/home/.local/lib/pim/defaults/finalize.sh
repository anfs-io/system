#!/bin/bash
# pim's finalize step, run as root at the end of every build: make the disk a clean image that a
# VM, a cloud or a hypervisor can boot as a new machine.
set -euo pipefail

# Package caches
if command -v apt-get >/dev/null; then apt-get clean; rm -rf /var/lib/apt/lists/*; fi
if command -v dnf >/dev/null; then dnf clean all -q || true; fi

# cloud-init runs again, as on a first boot
command -v cloud-init >/dev/null && { cloud-init clean --logs --seed || true; }

# ssh host keys: unique per machine, so none ship in the image. Fedora's sshd-keygen units make
# missing keys at boot; Debian has nothing that does, so this unit does it for both.
rm -f /etc/ssh/ssh_host_*
cat > /etc/systemd/system/pim-hostkeys.service <<'UNIT'
[Unit]
Description=Generate missing ssh host keys (pim)
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
Before=ssh.service sshd.service

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
ExecStartPost=-/bin/sh -c 'command -v restorecon >/dev/null && restorecon -R /etc/ssh'

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable pim-hostkeys.service

# What built this image
printf 'image=%s\narch=%s\nbuilt=%s\n' "${PIM_IMAGE:-}" "${PIM_ARCH:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /etc/pim-image

# Logs, history, temp files
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
find /var/log -type f -exec truncate -s 0 {} +
for h in /root /home/*; do rm -f "$h/.bash_history" "$h/.lesshst" "$h/.viminfo"; done
rm -rf /tmp/* /var/tmp/*

# machine-id last: an empty file makes systemd generate a new one on the next boot
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
sync
