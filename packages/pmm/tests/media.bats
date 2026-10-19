#!/usr/bin/env bats
# media.sh: boot media, blank machines (no image) and the display (qemu and ssh stubbed)
load helper

setup() {
  setup_pmm
  fake_build deb
  : > "$T/pve.iso"; : > "$T/ventoy.img"
  wait_ssh() { echo "wait_ssh" >> "$PMM_CALLS"; return 0; }
}

teardown() {
  local f
  for f in "$PMM_STATE_HOME"/run/*/pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null; done
  return 0
}

argv() { grep "^qemu-system" "$PMM_CALLS" | tail -n1; }

@test "validate: image or media; a media entry is a file or a catalogue id" {
  machine "$PMM_MACHINES_HOME/none" "cpus: 2"
  machine "$PMM_MACHINES_HOME/blank" "media: [$T/pve.iso]"
  machine "$PMM_MACHINES_HOME/gone" "media: [$T/nope.iso]"
  machine "$PMM_MACHINES_HOME/unknown" "media: [nope]"
  load_machines
  run cmd_validate none
  [ "$status" -ne 0 ]
  [[ "$output" == *"image: is required (or media:"* ]]
  run cmd_validate blank
  [ "$status" -eq 0 ]
  run cmd_validate gone
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning  media: $T/nope.iso is not a file here"* ]]
  run cmd_validate unknown
  [ "$status" -ne 0 ]
  [[ "$output" == *"'nope' is not a file or an ISO in the catalogue"* ]]
}

@test "run --media with no image: a blank machine, an empty disk, nothing held, no definition" {
  run cli_call run --name nas --no-start --media "$T/pve.iso" --disk 32G --memory 8G
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created nas, blank (32G disk)"* ]]
  [ ! -e "$PMM_MACHINES_HOME/nas" ]
  [ "$(state_get nas '.settings.media[0]')" = "$T/pve.iso" ]
  [ -z "$(state_get nas .settings.image)" ]
  [ -f "$PMM_DATA_HOME/machines/nas/disk.qcow2" ]
  [ -f "$PMM_DATA_HOME/machines/nas/efivars.fd" ]
  [ -z "$(state_get nas .image)" ]
  ! grep -q "image build" "$PMM_CALLS"
  run cmd_show nas
  [[ "$output" == *"image       none"* ]]
  [[ "$output" == *"media       $T/pve.iso"* ]]
  ANFS_JSON=true run cmd_list
  [ "$(yq -p json -r '.[] | select(.machine == "nas") | .image // "null"' <<< "$output")" = null ]
  run cli_call run --name x
  [ "$status" -eq 64 ]
  run cli_call run --media "$T/pve.iso"
  [ "$status" -eq 64 ]     # a blank machine has no image to be named after
}

@test "up, a blank machine: the disk first, then its media as a CD; no wait for ssh, no shell" {
  cli_call run --name nas --no-start --media "$T/pve.iso"
  run cli_call up nas
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Started nas"*"booting its disk, then its media"* ]]
  ! grep -q wait_ssh "$PMM_CALLS"
  [[ "$(argv)" == *"file=$PMM_DATA_HOME/machines/nas/disk.qcow2,format=qcow2,if=none,id=disk0"* ]]
  [[ "$(argv)" == *"virtio-blk-pci,drive=disk0,bootindex=0"* ]]
  [[ "$(argv)" == *"file=$T/pve.iso,media=cdrom,if=none,id=media1,readonly=on -device scsi-cd,drive=media1,bus=mscsi.0,bootindex=1"* ]]
  [[ "$(argv)" == *"-display none"* ]]
  run cli_call shell nas
  [ "$status" -ne 0 ]
  [[ "$output" == *"nas has no image, so pmm has no login for it"* ]]
  ! grep -q IdentityFile "$PMM_SSH_CONFIG"
  grep -q "^Host nas" "$PMM_SSH_CONFIG"
  cli_call down nas
}

@test "up --media: for this run it boots first, as a USB drive when it is not an ISO" {
  cli_call run deb --name web --no-start
  run cli_call up web --media "$T/ventoy.img"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"booting ventoy.img"* ]]
  ! grep -q wait_ssh "$PMM_CALLS"
  [[ "$(argv)" == *"file=$T/ventoy.img,format=raw,if=none,id=media1,snapshot=on -device usb-storage,drive=media1,bus=musb.0,removable=on,bootindex=0"* ]]
  [[ "$(argv)" == *"virtio-blk-pci,drive=disk0,bootindex=1"* ]]
  cli_call down web
  # without it the machine starts as it always did
  run cli_call up web
  [[ "$output" == *"web is up: pmm shell web"* ]]
  [[ "$(argv)" == *"file=$PMM_DATA_HOME/machines/web/disk.qcow2,format=qcow2,if=virtio"* ]]
  [[ "$(argv)" != *bootindex* ]]
}

@test "media: an id in the ISO catalogue is the file in the store" {
  mkdir -p "$HOME/.config/anfs" "$ANFS_ISO_HOME"
  printf -- '- id: pve\n  url: https://x/proxmox.iso\n' > "$HOME/.config/anfs/isos.yml"
  : > "$ANFS_ISO_HOME/proxmox.iso"
  cli_call run --name pve1 --no-start --media pve
  run cli_call up pve1
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$(argv)" == *"file=$ANFS_ISO_HOME/proxmox.iso,media=cdrom"* ]]
}

@test "up --display: VNC where the host has no screen; a screen and input devices for arm64" {
  cli_call run --name nas --no-start --media "$T/pve.iso"
  PMM_DISPLAY=vnc run cli_call up nas --display
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nas's screen: VNC at 127.0.0.1:5900"* ]]
  [[ "$(argv)" == *"-vnc 127.0.0.1:0,to=99"* ]]
  [[ "$(argv)" != *"-display none"* ]]
  [[ "$(argv)" == *"-device virtio-gpu-pci -device qemu-xhci,id=hid -device usb-kbd,bus=hid.0 -device usb-tablet,bus=hid.0"* ]]
  run cli_call up nas --display --console
  [ "$status" -eq 64 ]
}

@test "reset recreates a blank machine's empty disk" {
  cli_call run --name nas --no-start --media "$T/pve.iso"
  echo data > "$PMM_DATA_HOME/machines/nas/disk.qcow2"
  CLI_OPT[yes]=true run cli_call reset -y nas
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$PMM_DATA_HOME/machines/nas/disk.qcow2")" != data ]
}
