#!/bin/bash
# pim default (Debian): the guest agent, ACPI shutdown, cloud-init for wherever the image goes next
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q cloud-init cloud-guest-utils qemu-guest-agent acpid curl ca-certificates
systemctl enable qemu-guest-agent acpid || true
cat > /etc/cloud/cloud.cfg.d/90_pim.cfg <<'CFG'
datasource_list: [ NoCloud, ConfigDrive, OpenStack, Ec2, GCE, Azure, None ]
CFG
