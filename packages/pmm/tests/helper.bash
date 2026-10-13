# Shared setup for pmm's bats suites: an isolated HOME, anfs sources made of plain directories,
# pmm's libraries (and the four of pim's it uses) sourced directly, and stubs first on PATH so
# nothing boots a VM or touches the network: pim's own (qemu, ssh, ...) and a tart here. Stubs log
# each call to $PIM_CALLS.
#
# pim is the real one, from the working tree, run against the same isolated HOME: what pmm reads
# from it (`pim builds --json`, `pim path`, hold and release) is the interface under test. Only
# `pim build` is replaced, since a build boots a VM; fake_build leaves what one would.

setup_pmm() {
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home"
  export ANFS_LOG=off   # no log file from tests (lib/anfs/log.sh)
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  unset ANFS_CONFIG_HOME ANFS_DATA_HOME ANFS_CACHE_HOME ANFS_STATE_HOME ANFS_JSON ANFS_ISO_HOME PMM_DISPLAY DISPLAY WAYLAND_DISPLAY
  unset PIM_CONFIG_HOME PIM_DATA_HOME PIM_STATE_HOME PIM_CACHE_HOME PIM_IMAGES_HOME
  unset PMM_CONFIG_HOME PMM_DATA_HOME PMM_STATE_HOME PMM_CACHE_HOME PMM_MACHINES_HOME PMM_NETWORKS_HOME
  mkdir -p "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources" "$HOME/.local/lib"
  export PIM_HOST_OS=darwin PIM_HOST_ARCH=arm64
  export PIM_CALLS="$T/calls"
  : > "$PIM_CALLS"
  export TART_STUB="$T/tart"
  mkdir -p "$TART_STUB"
  export PATH="$BATS_TEST_DIRNAME/stubs:$BATS_TEST_DIRNAME/../../pim/tests/stubs:$PATH"

  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/pmm"
  local anfs="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"
  export PIM_LIB_DIR="$BATS_TEST_DIRNAME/../../pim/home/.local/lib/pim"
  # the real pim finds anfs's libraries under $HOME
  ln -sfn "$anfs" "$HOME/.local/lib/anfs"
  export PMM_PIM="$BATS_TEST_DIRNAME/../../pim/home/.local/bin/pim"
  # shellcheck source=/dev/null
  source "$anfs/paths.sh"; source "$anfs/log.sh"; source "$anfs/sources.sh"; source "$anfs/catalog.sh"; source "$anfs/iso.sh"; source "$anfs/cli.sh"; source "$anfs/table.sh"
  CLI_TOOL=pmm
  anfs_tool_paths pmm
  anfs_tool_paths pim
  anfs_gitsrc_env
  PMM_MACHINES_HOME="$PMM_CONFIG_HOME/machines" PMM_LOCAL_SOURCE=local PMM_LIB_DIR="$lib"
  PMM_SSH_PORT_BASE=42300 PIM_SSH_PORT_BASE=42300 PMM_SSH_TIMEOUT=5 PMM_INSTALL=up PMM_MACOS_LIMIT=2
  PIM_IMAGES_HOME="$PIM_CONFIG_HOME/images"
  # Networks: no backend, as on macOS, until a suite asks for libvirt (setup_net)
  PMM_NETWORKS_HOME="$PMM_CONFIG_HOME/networks" PMM_NET_BACKEND=none PMM_NET_CHECK=true
  PMM_LIBVIRT_URI=qemu:///system PMM_BRIDGE_CONF="$T/etc/pmm-bridge.conf" PMM_BRIDGE_HELPER="$T/etc/helper"
  PMM_SYS_NET="$T/sys" PMM_SSH_CONFIG="$HOME/.ssh/config.d/05-pmm.conf"
  export VIRSH_STUB="$T/virsh"
  mkdir -p "$T/etc" "$T/sys" "$VIRSH_STUB"
  local f
  for f in core qemu ssh tart; do source "$PIM_LIB_DIR/$f.sh"; done
  for f in "$lib"/*.sh; do source "$f"; done
  mkdir -p "$PMM_MACHINES_HOME" "$PIM_IMAGES_HOME" "$T/fw"
  : > "$T/fw/code.fd"; : > "$T/fw/vars.fd"
  export PIM_FW_CODE="$T/fw/code.fd" PIM_FW_VARS="$T/fw/vars.fd"

  # No VM boots: ssh answers at once, a stop is a kill, and a build is only logged
  wait_ssh() { return 0; }
  qemu_stop() { kill "$1" 2>/dev/null || true; }
  _tart_shutdown() { kill "$2" 2>/dev/null || true; sleep 0.2; }
  pim_cli() {
    if [[ "$1" == build ]]; then echo "pim $*" >> "$PIM_CALLS"; return 0; fi
    "$PMM_PIM" "$@"
  }
  load_machines
}

# A Linux host set up for networks (what pmm-network does): libvirt (the virsh stub), a setuid
# bridge helper and a writable allow list. host_bridge <name> is a bridge the host has.
setup_net() {
  PMM_NET_BACKEND=libvirt
  : > "$PMM_BRIDGE_CONF"
  : > "$PMM_BRIDGE_HELPER"
  chmod u+s "$PMM_BRIDGE_HELPER"
}
host_bridge() { mkdir -p "$PMM_SYS_NET/$1/bridge"; }

# network <dir> <yaml>: write networks/<name>/network.yml under a source dir (or $PMM_NETWORKS_HOME)
network() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/network.yml"
}

# An anfs source <alias> holding machines/, listed and linked like `anfs src update` does
add_source() {
  mkdir -p "$T/srcs/$1/machines"
  ln -sfn "$T/srcs/$1" "$HOME/.local/share/anfs/sources/$1"
  printf '%s  %s\n' "$T/srcs/$1" "$1" >> "$HOME/.config/anfs/user.list"
}

# machine <dir> <yaml>: write machines/<name>/machine.yml under a source dir (or $PMM_MACHINES_HOME)
machine() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/machine.yml"
}

SHA=6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b

# A pim image <name> (a local definition) with a build <key> for arm64, as `pim build` leaves it:
# the definition, the disk, its UEFI vars, meta.yml and the image's key. [yaml] is added to image.yml.
fake_build() {
  local name="$1" key="${2:-aaaaaaaaaaaaaaaa}" d="$PIM_DATA_HOME/images/$1/arm64"
  mkdir -p "$PIM_IMAGES_HOME/$name" "$d" "$PIM_DATA_HOME/keys/$name"
  printf 'distro: debian\narch: [arm64]\niso:\n  arm64: {url: https://x/a.iso, sha256: %s}\n%s\n' "$SHA" "${3:-}" > "$PIM_IMAGES_HOME/$name/image.yml"
  : > "$d/$key.qcow2"; : > "$d/$key-efivars.fd"
  echo key > "$PIM_DATA_HOME/keys/$name/id_ed25519"
  printf 'id: local/%s\nname: %s\narch: arm64\nbackend: qemu\ncache_key: %s\ndisk: %s.qcow2\nuser: pim\n' \
    "$name" "$name" "$key" "$key" > "$d/meta.yml"
}

# The same for a tart image: its build is a VM in tart's store (the stub's)
fake_tart_build() {
  local name="$1" key="${2:-bbbbbbbbbbbbbbbb}" d="$PIM_DATA_HOME/images/$1/arm64"
  mkdir -p "$PIM_IMAGES_HOME/$name" "$d" "$PIM_DATA_HOME/keys/$name"
  printf 'backend: tart\ndistro: macos\narch: [arm64]\nbase: ghcr.io/x/macos:latest\nuser: {name: owner, bootstrap: {name: admin, password: admin}}\n' > "$PIM_IMAGES_HOME/$name/image.yml"
  echo key > "$PIM_DATA_HOME/keys/$name/id_ed25519"
  printf 'id: local/%s\nname: %s\narch: arm64\nbackend: tart\ncache_key: %s\ndisk: pim-%s-%s\nuser: owner\n' \
    "$name" "$name" "$key" "$name" "$key" > "$d/meta.yml"
  echo stopped > "$TART_STUB/pim-$name-$key"
}

held() { "$PMM_PIM" builds --json "$1" | yq -p json -r '.[0].held | join(" ")'; }
