#!/usr/bin/env bash
# pim library: the qemu backend — command lines, firmware, disks, QMP, stopping a VM.
# Sourced by ~/.local/bin/pim; functions only.
#
# Acceleration: hvf on macOS and kvm on Linux, only for a guest of the host's own architecture
# (neither can run a foreign one); anything else is TCG emulation, which works but is slow.
# arm64 guests boot UEFI from pflash (code read-only, a per-disk copy of the vars); amd64 guests
# boot SeaBIOS. Networking is user-mode with ssh forwarded on 127.0.0.1 only.

qemu_bin() { echo "qemu-system-$(arch_qemu "$1")"; }

# hvf|kvm|tcg for a guest of <arch> on this host
qemu_accel() {
  local arch="$1"
  if [[ "$arch" == "$(host_arch)" ]]; then
    case "$(host_os)" in
      darwin) echo hvf; return ;;
      linux) [[ -w "${PIM_KVM_DEV:-/dev/kvm}" ]] && { echo kvm; return; } ;;
    esac
  fi
  echo tcg
}

# Set FW_CODE and FW_VARS (the vars template) for an arm64 guest; fails when none is installed
qemu_firmware() {
  local share
  share="$(cd "$(dirname "$(command -v qemu-system-aarch64 2>/dev/null || echo /usr/bin/x)")/.." 2>/dev/null && pwd)/share/qemu"
  local pair
  for pair in \
      "${PIM_FW_CODE:-}|${PIM_FW_VARS:-}" \
      "$share/edk2-aarch64-code.fd|$share/edk2-arm-vars.fd" \
      "/usr/share/AAVMF/AAVMF_CODE.fd|/usr/share/AAVMF/AAVMF_VARS.fd" \
      "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw|/usr/share/edk2/aarch64/vars-template-pflash.raw" \
      "/usr/share/qemu/edk2-aarch64-code.fd|/usr/share/qemu/edk2-arm-vars.fd"; do
    FW_CODE="${pair%%|*}" FW_VARS="${pair#*|}"
    [[ -n "$FW_CODE" && -f "$FW_CODE" && -f "$FW_VARS" ]] && return 0
  done
  return 1
}

# A fresh UEFI vars file for an arm64 disk (nothing for amd64)
# Usage: efivars_new <arch> <dest>
efivars_new() {
  [[ "$1" == arm64 ]] || return 0
  qemu_firmware || die "no aarch64 UEFI firmware found (ppm install anfs/qemu)"
  cp "$FW_VARS" "$2"
  chmod u+w "$2"
}

# The console device of a guest's kernel
qemu_console() { [[ "$1" == arm64 ]] && echo ttyAMA0 || echo ttyS0; }

# Fill QEMU_ARGV with the machine for a guest: accel, cpu, memory, firmware, the disk, rng, nic.
# Usage: qemu_argv <arch> <cpus> <memory MB> <disk> <efivars|""> <ssh port> [hostfwd host:guest...]
qemu_argv() {
  local arch="$1" cpus="$2" mem="$3" disk="$4" vars="$5" port="$6" accel cpu fwd f
  shift 6
  accel=$(qemu_accel "$arch")
  [[ "$accel" == tcg ]] && cpu=max || cpu=host
  QEMU_ARGV=("$(qemu_bin "$arch")")
  case "$arch" in
    arm64) QEMU_ARGV+=(-machine virt,highmem=on) ;;
    amd64) QEMU_ARGV+=(-machine q35) ;;
  esac
  if [[ "$accel" == tcg ]]; then QEMU_ARGV+=(-accel tcg,thread=multi)
  else QEMU_ARGV+=(-accel "$accel")
  fi
  QEMU_ARGV+=(-cpu "$cpu" -smp "$cpus" -m "$mem")
  if [[ "$arch" == arm64 ]]; then
    qemu_firmware || die "no aarch64 UEFI firmware found (ppm install anfs/qemu)"
    QEMU_ARGV+=(-drive "if=pflash,format=raw,readonly=on,file=$FW_CODE"
                -drive "if=pflash,format=raw,file=$vars")
  fi
  fwd="hostfwd=tcp:127.0.0.1:$port-:22"
  for f in "$@"; do fwd+=",hostfwd=tcp:127.0.0.1:${f%%:*}-:${f#*:}"; done
  QEMU_ARGV+=(-drive "file=$disk,format=qcow2,if=virtio"
              -device virtio-rng-pci
              -netdev "user,id=net0,$fwd" -device virtio-net-pci,netdev=net0
              -display none)
}

# Add the installer: the ISO as a CD, direct kernel boot with the injected initrd, no reboot
# Usage: qemu_argv_installer <iso> <kernel> <initrd> <append>
qemu_argv_installer() {
  QEMU_ARGV+=(-device virtio-scsi-pci,id=scsi0
              -drive "file=$1,media=cdrom,if=none,id=cd0,readonly=on"
              -device scsi-cd,drive=cd0,bus=scsi0.0
              -kernel "$2" -initrd "$3" -append "$4" -no-reboot)
}

# Add a virtio-9p share: <path>[:tag][:ro]
qemu_argv_share() {
  local spec="$1" path tag ro="" n="${#QEMU_ARGV[@]}"
  path="${spec%%:*}"
  tag=$(basename "$path")
  case "$spec" in
    *:*:ro) tag=$(echo "$spec" | cut -d: -f2); ro=",readonly=on" ;;
    *:ro) ro=",readonly=on" ;;
    *:*) tag="${spec#*:}" ;;
  esac
  [[ -d "$path" ]] || die "share: $path is not a directory"
  QEMU_ARGV+=(-fsdev "local,id=fs$n,path=${path//,/,,},security_model=none$ro"
              -device "virtio-9p-pci,fsdev=fs$n,mount_tag=$tag")
  SHARE_TAGS+=("$tag")
}

# Serial to a log file (and the monitor off), or to the terminal with --console
# Usage: qemu_argv_io <console:true|false> <serial log> <qmp socket>
qemu_argv_io() {
  if [[ "$1" == true ]]; then QEMU_ARGV+=(-serial mon:stdio)
  else QEMU_ARGV+=(-monitor none -serial "file:$2")
  fi
  QEMU_ARGV+=(-qmp "unix:$3,server=on,wait=off")
}

# Send one QMP command; prints the reply
qmp() {
  local sock="$1" cmd="$2"
  [[ -S "$sock" ]] || return 1
  printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$cmd" | socat -t2 - "UNIX-CONNECT:$sock" 2>/dev/null
}

# Wait up to <secs> for <pid> to exit
wait_exit() {
  local pid="$1" secs="$2" i
  for ((i = 0; i < secs; i++)); do
    pid_alive "$pid" || return 0
    sleep 1
  done
  ! pid_alive "$pid"
}

# Stop a VM: the guest's own poweroff over ssh (when <ssh-fn> is given), then ACPI powerdown
# through QMP, then QMP quit, then SIGKILL — each only if the one before didn't end it
# Usage: qemu_stop <pid> <qmp socket> [ssh-poweroff function and args...]
qemu_stop() {
  local pid="$1" sock="$2"
  shift 2
  pid_alive "$pid" || return 0
  if [[ $# -gt 0 ]]; then
    "$@" >/dev/null 2>&1 || true
    wait_exit "$pid" 60 && return 0
  fi
  qmp "$sock" system_powerdown >/dev/null || true
  wait_exit "$pid" 30 && return 0
  qmp "$sock" quit >/dev/null || true
  wait_exit "$pid" 5 && return 0
  kill -9 "$pid" 2>/dev/null || true
  wait_exit "$pid" 5 || true
}

# Create a qcow2 disk (or an overlay on <backing>)
# Usage: disk_create <path> <size> | disk_overlay <path> <backing>
disk_create()  { qemu-img create -q -f qcow2 "$1" "$2"; }
disk_overlay() { qemu-img create -q -f qcow2 -b "$2" -F qcow2 "$1"; }
