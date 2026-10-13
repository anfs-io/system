#!/usr/bin/env bash
# pmm-network: the host setup pmm's networks need, once and as root.
#
#   groups       the user in libvirt (networks without sudo) and kvm
#   the helper   qemu's bridge helper setuid root, for the kvm group only. pmm starts qemu as the
#                user, and the helper is how an unprivileged qemu gets a tap device on a bridge.
#                Recorded with dpkg-statoverride, so a qemu upgrade keeps it.
#   allow list   /etc/qemu/bridge.conf includes /etc/qemu/pmm-bridge.conf, which the libvirt
#                group may write: pmm adds each network's bridge there without asking again.
#                (Whoever is in that group can already make any network libvirt can.)
#   names        `libvirt` in nsswitch.conf's hosts line, so machines' names resolve on the host
#
# Everything is left in place when the package is removed.

PMM_NET_QEMU_ETC=/etc/qemu

_pmm_net_helper() {
  local p
  for p in /usr/lib/qemu/qemu-bridge-helper /usr/libexec/qemu-bridge-helper; do
    [[ -e "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

install_linux() {
  local user helper added="" g
  user=$(id -un)
  helper=$(_pmm_net_helper) || { ppm_fail "qemu's bridge helper was not found (ppm install core/qemu)"; return 0; }
  _system_sudo "host setup for pmm networks" \
    "pmm's networks need root once (groups, the bridge helper, /etc/qemu); ask an admin to run: ppm install core/pmm-network" ||
    return 0

  for g in libvirt kvm; do
    getent group "$g" >/dev/null || continue
    id -nG "$user" | tr ' ' '\n' | grep -qx "$g" && continue
    sudo -n usermod -aG "$g" "$user" && added+=" $g"
  done

  if command -v dpkg-statoverride >/dev/null 2>&1; then
    sudo -n dpkg-statoverride --list "$helper" >/dev/null 2>&1 && sudo -n dpkg-statoverride --remove "$helper" >/dev/null
    sudo -n dpkg-statoverride --update --add root kvm 4750 "$helper" || ppm_fail "could not make $helper setuid"
  else
    sudo -n chown root:kvm "$helper" && sudo -n chmod 4750 "$helper" || ppm_fail "could not make $helper setuid"
  fi

  sudo -n mkdir -p "$PMM_NET_QEMU_ETC"
  sudo -n touch "$PMM_NET_QEMU_ETC/bridge.conf" "$PMM_NET_QEMU_ETC/pmm-bridge.conf"
  grep -qx "include $PMM_NET_QEMU_ETC/pmm-bridge.conf" "$PMM_NET_QEMU_ETC/bridge.conf" ||
    echo "include $PMM_NET_QEMU_ETC/pmm-bridge.conf" | sudo -n tee -a "$PMM_NET_QEMU_ETC/bridge.conf" >/dev/null
  sudo -n chown root:kvm "$PMM_NET_QEMU_ETC/bridge.conf"
  sudo -n chmod 640 "$PMM_NET_QEMU_ETC/bridge.conf"
  sudo -n chown root:libvirt "$PMM_NET_QEMU_ETC/pmm-bridge.conf"
  sudo -n chmod 664 "$PMM_NET_QEMU_ETC/pmm-bridge.conf"

  if ! grep -Eq '^hosts:.*[[:space:]]libvirt([[:space:]]|$)' /etc/nsswitch.conf; then
    [[ -e /etc/nsswitch.conf.before-pmm ]] || sudo -n cp -p /etc/nsswitch.conf /etc/nsswitch.conf.before-pmm
    sudo -n sed -i -E 's/^(hosts:[[:space:]]+files)([[:space:]]|$)/\1 libvirt\2/' /etc/nsswitch.conf
    grep -Eq '^hosts:.*[[:space:]]libvirt([[:space:]]|$)' /etc/nsswitch.conf ||
      user_message "Add 'libvirt' to the hosts: line of /etc/nsswitch.conf for machines' names to resolve on this host"
  fi

  sudo -n systemctl enable --now libvirtd.socket >/dev/null 2>&1 || true
  [[ -z "$added" ]] ||
    user_message "Added $user to:$added. Log out and in again (or: newgrp libvirt) before pmm network install"
}

install_macos() {
  user_message "pmm's networks are built on Linux only so far; nothing was set up on this Mac"
}
