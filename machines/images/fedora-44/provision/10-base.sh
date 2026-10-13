#!/bin/bash
# pmm default (Fedora): the guest agent, cloud-init for wherever the image goes next
set -euo pipefail
dnf install -y -q cloud-init cloud-utils-growpart qemu-guest-agent curl ca-certificates
systemctl enable qemu-guest-agent || true
cat > /etc/cloud/cloud.cfg.d/90_pmm.cfg <<'CFG'
datasource_list: [ NoCloud, ConfigDrive, OpenStack, Ec2, GCE, Azure, None ]
CFG
