#!/bin/bash
# debian-13: the guest agent, ACPI shutdown, cloud-init for wherever the image goes next
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q cloud-init cloud-guest-utils qemu-guest-agent acpid curl ca-certificates
systemctl enable qemu-guest-agent acpid || true

# DHCP on every ethernet interface, however many the machine is given. The installer configures
# only the one it used (ifupdown); dhcpcd's own service looks after them all instead. It is not
# started here (policy-rc.d): the interface this script came in on stays as it is until reboot.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
apt-get install -y -q dhcpcd
rm -f /usr/sbin/policy-rc.d
systemctl enable dhcpcd
sed -i -E '/^# The primary network interface/d; /^(auto|allow-hotplug) (en|eth)/d; /^iface (en|eth)[^ ]* inet6? /d; /^# This is an autoconfigured IPv6 interface/d' /etc/network/interfaces

cat > /etc/cloud/cloud.cfg.d/90_pmm.cfg <<'CFG'
datasource_list: [ NoCloud, ConfigDrive, OpenStack, Ec2, GCE, Azure, None ]
CFG
