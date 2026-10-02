#!/usr/bin/env bats
# qemu.sh: the command line for each host and guest
load helper

setup() {
  setup_pim
  mkdir -p "$T/fw"
  : > "$T/fw/code.fd"; : > "$T/fw/vars.fd"
  export PIM_FW_CODE="$T/fw/code.fd" PIM_FW_VARS="$T/fw/vars.fd"
}

argv() { qemu_argv "$@"; echo "${QEMU_ARGV[*]}"; }

@test "arm64 guest on Apple silicon: hvf, cpu host, UEFI pflash, ssh on 127.0.0.1 only" {
  run argv arm64 2 2048 /d.qcow2 /v.fd 2222
  [[ "$output" == "qemu-system-aarch64 -machine virt,highmem=on -accel hvf -cpu host -smp 2 -m 2048"* ]]
  [[ "$output" == *"if=pflash,format=raw,readonly=on,file=$T/fw/code.fd"* ]]
  [[ "$output" == *"if=pflash,format=raw,file=/v.fd"* ]]
  [[ "$output" == *"hostfwd=tcp:127.0.0.1:2222-:22"* ]]
}

@test "amd64 guest on Apple silicon is emulated (tcg, cpu max), no pflash" {
  run argv amd64 2 2048 /d.qcow2 "" 2222
  [[ "$output" == "qemu-system-x86_64 -machine q35 -accel tcg,thread=multi -cpu max"* ]]
  [[ "$output" != *pflash* ]]
}

@test "Linux: kvm when /dev/kvm is writable, tcg when it is not" {
  PIM_HOST_OS=linux PIM_HOST_ARCH=amd64 PIM_KVM_DEV="$T/kvm"
  : > "$T/kvm"
  [ "$(qemu_accel amd64)" = kvm ]
  [ "$(qemu_accel arm64)" = tcg ]
  chmod 000 "$T/kvm"
  [ "$(qemu_accel amd64)" = tcg ]
}

@test "extra port forwards and a read-only 9p share" {
  mkdir -p "$T/share"
  SHARE_TAGS=()
  qemu_argv arm64 2 2048 /d.qcow2 /v.fd 2222 8080:80
  qemu_argv_share "$T/share:src:ro"
  [[ "${QEMU_ARGV[*]}" == *"hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80"* ]]
  [[ "${QEMU_ARGV[*]}" == *"path=$T/share,security_model=none,readonly=on"* ]]
  [[ "${QEMU_ARGV[*]}" == *"mount_tag=src"* ]]
  [ "${SHARE_TAGS[0]}" = src ]
}

@test "installer: kernel, injected initrd, append, no reboot" {
  qemu_argv arm64 2 2048 /d.qcow2 /v.fd 2222
  qemu_argv_installer /i.iso /k /ird "auto=true ---"
  [[ "${QEMU_ARGV[*]}" == *"-kernel /k -initrd /ird -append auto=true --- -no-reboot"* ]]
}

@test "free_port skips ports recorded for running VMs and ports in use" {
  mkdir -p "$PIM_STATE_HOME/run/x"
  echo 42200 > "$PIM_STATE_HOME/run/x/port"
  [ "$(free_port)" = 42201 ]
}
