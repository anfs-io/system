#!/usr/bin/env bash
# pmm library: boot media, and the display to use them with. Sourced by ~/.local/bin/pmm;
# functions only.
#
# A machine's media are what a person would plug in: an ISO is a CD, any other file a USB drive
# (a raw disk image such as a Ventoy stick's, or a qcow2). One is named by its path, or by its id
# in the ISO catalogue (lib/anfs/iso.sh), which is downloaded into the shared store when needed.
#
# Media in the definition (media:) boot after the machine's disk: an empty disk falls through to
# the installer, and what it installs boots from then on. Media given for one run (`pmm up
# --media`) boot before it: a rescue system, a reinstall.
#
# A machine with media and no image is a blank one: an empty disk of its `disk:` size (20G),
# nothing pmm can log in to. It is for systems with installers of their own.

PMM_BLANK_DISK=20G

# A media entry: a path when it looks like one or names a file, else an ISO catalogue id
_media_is_path() { [[ "$1" == */* || "$1" == "~"* || "$1" == .* || -e "$1" ]]; }
_media_expand() { local p="$1"; [[ "$p" != "~"* ]] || p="$HOME${p:1}"; echo "$p"; }

# What is wrong with a media entry, as validate says it; nothing when it is fine
media_problem() {
  local m="$1"
  if _media_is_path "$m"; then
    [[ -f "$(_media_expand "$m")" ]] || echo "warning media: $(_media_expand "$m") is not a file here"
  elif ! command -v yq >/dev/null 2>&1 || ! anfs_iso_known "$m"; then
    echo "error media: '$m' is not a file or an ISO in the catalogue (isos/isos.yml in a source)"
  fi
}

# The file of a media entry, downloading a catalogue ISO that is not in the store yet
media_file() {
  local m="$1" f
  if _media_is_path "$m"; then
    f=$(_media_expand "$m")
    [[ -f "$f" ]] || die "media: $f is not a file"
    [[ "$f" == /* ]] || f="$PWD/$f"
    echo "$f"
    return 0
  fi
  anfs_iso_fetch_id "$m" || die "media: the ISO '$m' could not be downloaded and verified"
}

# Add media to QEMU_ARGV and give the machine's disk its place in the boot order.
# Usage: qemu_argv_media <disk> <n first> [first media file...] [later media file...]
qemu_argv_media() {
  local disk="$1" n="$2" i f idx=0 k=0 fmt
  shift 2
  local -a first=("${@:1:$n}") later=("${@:$((n + 1))}")
  local scsi=false usb=false
  [[ $# -gt 0 ]] || return 0

  _media_add() {
    f="$1"
    k=$((k + 1))
    case "${f,,}" in
      *.iso)
        $scsi || QEMU_ARGV+=(-device virtio-scsi-pci,id=mscsi)
        scsi=true
        QEMU_ARGV+=(-drive "file=${f//,/,,},media=cdrom,if=none,id=media$k,readonly=on"
                    -device "scsi-cd,drive=media$k,bus=mscsi.0,bootindex=$idx")
        ;;
      *)
        fmt=raw
        [[ "${f,,}" != *.qcow2 ]] || fmt=qcow2
        $usb || QEMU_ARGV+=(-device qemu-xhci,id=musb)
        usb=true
        # snapshot=on: what the guest writes to it is thrown away, so a stick's image is never
        # changed by a machine that booted from it
        QEMU_ARGV+=(-drive "file=${f//,/,,},format=$fmt,if=none,id=media$k,snapshot=on"
                    -device "usb-storage,drive=media$k,bus=musb.0,removable=on,bootindex=$idx")
        ;;
    esac
    idx=$((idx + 1))
  }

  for f in "${first[@]}"; do _media_add "$f"; done
  # The disk, between the two: qemu_argv's -drive if=virtio takes no bootindex, so it becomes a
  # drive and a device of its own
  for i in "${!QEMU_ARGV[@]}"; do
    if [[ "${QEMU_ARGV[$i]}" == "file=$disk,format=qcow2,if=virtio" ]]; then
      QEMU_ARGV[i]="file=$disk,format=qcow2,if=none,id=disk0"
      QEMU_ARGV+=(-device "virtio-blk-pci,drive=disk0,bootindex=$idx")
      idx=$((idx + 1))
      break
    fi
  done
  for f in "${later[@]}"; do _media_add "$f"; done
  unset -f _media_add
}

# How a display is shown here: window (the host has a screen: macOS, or X/Wayland) or vnc.
# PMM_DISPLAY says otherwise.
display_kind() {
  if [[ -n "${PMM_DISPLAY:-}" ]]; then echo "$PMM_DISPLAY"
  elif [[ "$(host_os)" == darwin || -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then echo window
  else echo vnc
  fi
}

# Give the machine a screen, a keyboard and a pointer, in place of qemu_argv's `-display none`
# Usage: qemu_argv_display <arch> <window|vnc>
qemu_argv_display() {
  local arch="$1" kind="$2" i
  for i in "${!QEMU_ARGV[@]}"; do
    [[ "${QEMU_ARGV[$i]}" == -display && "${QEMU_ARGV[$((i + 1))]:-}" == none ]] || continue
    if [[ "$kind" == vnc ]]; then
      # the first free display from :0; `pmm up` asks qemu which it took
      QEMU_ARGV[i]=-vnc
      QEMU_ARGV[i+1]="127.0.0.1:0,to=99"
    elif [[ "$(host_os)" == darwin ]]; then QEMU_ARGV[i+1]=cocoa
    else QEMU_ARGV[i+1]=gtk
    fi
    break
  done
  # amd64 (q35) has a VGA card and a PS/2 keyboard already; arm64 (virt) has neither
  [[ "$arch" != arm64 ]] || QEMU_ARGV+=(-device virtio-gpu-pci)
  QEMU_ARGV+=(-device qemu-xhci,id=hid)
  [[ "$arch" != arm64 ]] || QEMU_ARGV+=(-device usb-kbd,bus=hid.0)
  QEMU_ARGV+=(-device usb-tablet,bus=hid.0)
}

# The port a running machine's VNC display is on; nothing when it has none
vnc_port() {
  qmp "$1" query-vnc 2>/dev/null | grep -o '"service": *"[0-9]*"' | grep -o '[0-9][0-9]*' | head -n1 || true
}
