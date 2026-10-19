#!/usr/bin/env bats
# qemu.sh: the command line for each host and guest
load helper

setup() {
  setup_images
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
  PMM_HOST_OS=linux PMM_HOST_ARCH=amd64 PMM_KVM_DEV="$T/kvm"
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

@test "free_port skips ports recorded for builds, for running machines, and ports in use" {
  mkdir -p "$PMM_STATE_HOME/build/x" "$PMM_STATE_HOME/run/m"
  echo "$PMM_SSH_PORT_BASE" > "$PMM_STATE_HOME/build/x/port"
  [ "$(free_port)" = $((PMM_SSH_PORT_BASE + 1)) ]
  echo $((PMM_SSH_PORT_BASE + 1)) > "$PMM_STATE_HOME/run/m/port"
  [ "$(free_port)" = $((PMM_SSH_PORT_BASE + 2)) ]
}

@test "tcg for a guest of the host's arch is said once, with what is missing; a foreign arch is not" {
  PMM_HOST_OS=linux PMM_HOST_ARCH=amd64 PMM_KVM_DEV="$T/kvm"
  : > "$T/kvm"
  run qemu_accel_warn amd64
  [ -z "$output" ]
  chmod 000 "$T/kvm"
  run qemu_accel_warn arm64
  [ -z "$output" ]
  w() { qemu_accel_warn amd64; qemu_accel_warn amd64; }
  run w
  [ "$(grep -c 'emulated (tcg)' <<< "$output")" = 1 ]
  [[ "$output" == *"$T/kvm is not writable"*"ppm install core/pmm-network"*"usermod -aG kvm"* ]]
  rm -f "$T/kvm"
  QEMU_ACCEL_WARNED=false
  run qemu_accel_warn amd64
  [[ "$output" == *"$T/kvm is missing"* ]]
}

@test "image build on Linux without a writable /dev/kvm warns once, parents included" {
  PMM_HOST_OS=linux PMM_HOST_ARCH=amd64 PMM_KVM_DEV="$T/kvm"
  : > "$T/kvm"; chmod 000 "$T/kvm"
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  image "$PMM_IMAGES_HOME/c" "from: d"
  load_images
  mkdir -p "$ANFS_ISO_HOME"
  echo iso > "$ANFS_ISO_HOME/b.iso"
  sleep 1; echo "$SHA" > "$ANFS_ISO_HOME/b.iso.sha256"
  wait_ssh() { return 0; }
  run cmd_image_build c
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'emulated (tcg)' <<< "$output")" = 1 ]
  [[ "$output" == *"Installing debian (tcg)"* ]]
}
