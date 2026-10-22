# Shared setup for pmm's bats suites: an isolated HOME, anfs sources made of plain directories,
# pmm's libraries sourced directly, and stubs (tests/stubs) first on PATH so nothing boots a VM or
# touches the network: qemu, qemu-img, ssh, bsdtar, socat, tart, virsh. Stubs log each call to
# $PMM_CALLS.

# Off until further notice (2026-10-19): pmm's suites are too slow to run on every change. The
# person runs them by hand (ROADMAP.md, "Last"); ANFS_TESTS_PMM_PCM=1 turns them back on.
setup_file() {
  [[ "${ANFS_TESTS_PMM_PCM:-}" == 1 ]] || skip "pmm tests are off (ANFS_TESTS_PMM_PCM=1 runs them)"
}
#
# There is one catalogue per process (lib/anfs/catalog.sh), so a suite is set up for machines
# (setup_pmm) or for images (setup_images). What a machine suite needs of an image is a build:
# fake_build leaves what `pmm image build` would.

_setup_home() {
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home"
  export ANFS_LOG=off   # no log file from tests (lib/anfs/log.sh)
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  unset ANFS_CONFIG_HOME ANFS_DATA_HOME ANFS_CACHE_HOME ANFS_STATE_HOME ANFS_JSON ANFS_ISO_HOME PMM_DISPLAY DISPLAY WAYLAND_DISPLAY
  unset PMM_CONFIG_HOME PMM_DATA_HOME PMM_STATE_HOME PMM_CACHE_HOME PMM_MACHINES_HOME PMM_NETWORKS_HOME PMM_IMAGES_HOME
  unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)
  unset PMM_KVM_DEV
  mkdir -p "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources" "$HOME/.local/lib"
  export PMM_HOST_OS=darwin PMM_HOST_ARCH=arm64
  # never the default: a pmm really running machines on this host has their sockets there, and
  # implode deletes the directory. Short, for macOS's limit on a socket's path. Under `anfs work
  # run` the job has a directory of its own, and the suites use one inside it.
  if [[ -n "${PMM_SOCK_DIR:-}" ]]; then
    export PMM_SOCK_DIR="${PMM_SOCK_DIR%/}/bats"
  else
    export PMM_SOCK_DIR="/tmp/pmm-bats-$(id -u)"
  fi
  # The ports: from the run's PMM_SSH_PORT_BASE when it has one (a job's own range), else 42300.
  # A machine suite's start there, an image suite's 50 above (setup_images): never below, which
  # under a job would be the range of the job before it or the live default, 2222.
  PORT_BASE="${PMM_SSH_PORT_BASE:-42300}"
  export PMM_CALLS="$T/calls"
  : > "$PMM_CALLS"
  export TART_STUB="$T/tart"
  mkdir -p "$TART_STUB"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"

  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/pmm"
  local anfs="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"
  # a pmm run as a command finds anfs's libraries under $HOME
  ln -sfn "$anfs" "$HOME/.local/lib/anfs"
  PMM="$BATS_TEST_DIRNAME/../home/.local/bin/pmm"
  # shellcheck source=/dev/null
  source "$anfs/paths.sh"; source "$anfs/log.sh"; source "$anfs/sources.sh"; source "$anfs/catalog.sh"; source "$anfs/iso.sh"; source "$anfs/cli.sh"; source "$anfs/config.sh"; source "$anfs/table.sh"
  CLI_TOOL=pmm
  anfs_tool_paths pmm
  anfs_gitsrc_env
  PMM_MACHINES_HOME="$PMM_CONFIG_HOME/machines" PMM_LOCAL_SOURCE=local
  export PMM_LIB_DIR="$lib"
  export PMM_SSH_PORT_BASE="$PORT_BASE"
  PMM_SSH_TIMEOUT=5 PMM_INSTALL=up PMM_MACOS_LIMIT=2
  PMM_IMAGES_HOME="$PMM_MACHINES_HOME/images" PMM_IMAGE_INSTALL_TIMEOUT=60 PMM_IMAGE_SSH_TIMEOUT=5
  # Networks: no backend, as on macOS, until a suite asks for libvirt (setup_net)
  PMM_NETWORKS_HOME="$PMM_MACHINES_HOME/networks" PMM_NET_BACKEND=none PMM_NET_CHECK=true
  PMM_LIBVIRT_URI=qemu:///system PMM_BRIDGE_CONF="$T/etc/pmm-bridge.conf" PMM_BRIDGE_HELPER="$T/etc/helper"
  PMM_SYS_NET="$T/sys" PMM_SSH_CONFIG="$HOME/.ssh/config.d/05-pmm.conf"
  export VIRSH_STUB="$T/virsh"
  mkdir -p "$T/etc" "$T/sys" "$VIRSH_STUB"
  local f
  for f in "$lib"/*.sh; do source "$f"; done
  mkdir -p "$PMM_MACHINES_HOME" "$PMM_IMAGES_HOME" "$T/fw"
  iso_catalog
  : > "$T/fw/code.fd"; : > "$T/fw/vars.fd"
  export PMM_FW_CODE="$T/fw/code.fd" PMM_FW_VARS="$T/fw/vars.fd"
}

# A machine suite: the machines' catalogue, and no VM boots. ssh answers at once, a stop is a
# kill, and the build a create asks for is only logged
setup_pmm() {
  _setup_home
  wait_ssh() { return 0; }
  qemu_stop() { kill "$1" 2>/dev/null || true; }
  _tart_shutdown() { kill "$2" 2>/dev/null || true; sleep 0.2; }
  image_ensure_built() { echo "image build --arch $2 $1" >> "$PMM_CALLS"; }
  load_machines
}

# An image suite: the images' catalogue, and the build's own waiting and stopping against the
# stubs. Call load_images again after adding a source.
setup_images() {
  _setup_home
  export PMM_SSH_PORT_BASE=$((PORT_BASE + 50))
  load_images
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

# network <dir> <yaml>: write machines/networks/<name>/network.yml under a source dir (or $PMM_NETWORKS_HOME)
network() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/network.yml"
}

# An anfs source <alias> holding machines/ (and machines/images/), listed and linked like `anfs src update` does
add_source() {
  mkdir -p "$T/srcs/$1/machines/images"
  ln -sfn "$T/srcs/$1" "$HOME/.local/share/anfs/sources/$1"
  printf '%s  %s\n' "$T/srcs/$1" "$1" >> "$HOME/.config/anfs/user.list"
}

# machine <dir> <yaml>: write machines/<name>/machine.yml under a source dir (or $PMM_MACHINES_HOME)
machine() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/machine.yml"
}

# image <dir> <yaml>: write machines/images/<name>/image.yml under a source dir (or
# $PMM_IMAGES_HOME). A Debian root image gets the answer file it has to have, a one-line one
image() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/image.yml"
  [[ "$2" != *"distro: debian"* ]] || printf '%s\n' 'd-i passwd/username string ${USER}' 'd-i netcfg/get_hostname string ${HOSTNAME}' > "$1/preseed.cfg"
}

# The ISOs the test images name, in the person's own catalogue ($ANFS_CONFIG_HOME/isos.yml):
# t-arm64 is a.iso and t-amd64 is b.iso, both pinned to $SHA
SHA=6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b
iso_catalog() {
  printf -- '- {id: t-arm64, url: https://x/a.iso, checksum: "sha256:%s"}\n- {id: t-amd64, url: https://x/b.iso, checksum: "sha256:%s"}\n' \
    "$SHA" "$SHA" > "$HOME/.config/anfs/isos.yml"
}
deb_yml() {
  printf 'distro: debian\narch: [arm64, amd64]\niso: {arm64: t-arm64, amd64: t-amd64}\n%s\n' "${1:-}"
}

# This repo as the source `core`: the shipped images, and the catalogue their ISOs are in
core_source() {
  ln -sfn "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)" "$HOME/.local/share/anfs/sources/core"
  printf '%s  core\n' "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)" >> "$HOME/.config/anfs/user.list"
}

# An image <name> (a local definition) with a build <key> for arm64, as `pmm image build` leaves
# it: the definition, the disk, its UEFI vars, meta.yml and the image's key. [yaml] is added to
# image.yml.
fake_build() {
  local name="$1" key="${2:-aaaaaaaaaaaaaaaa}" d="$PMM_DATA_HOME/images/$1/arm64"
  mkdir -p "$PMM_IMAGES_HOME/$name" "$d" "$PMM_DATA_HOME/keys/$name"
  image "$PMM_IMAGES_HOME/$name" "$(printf 'distro: debian\narch: [arm64]\niso: {arm64: t-arm64}\n%s' "${3:-}")"
  : > "$d/$key.qcow2"; : > "$d/$key-efivars.fd"
  echo key > "$PMM_DATA_HOME/keys/$name/id_ed25519"
  printf 'id: local/%s\nname: %s\narch: arm64\nbackend: qemu\ncache_key: %s\ndisk: %s.qcow2\nuser: pmm\n' \
    "$name" "$name" "$key" "$key" > "$d/meta.yml"
}

# The same for a tart image: its build is a VM in tart's store (the stub's)
fake_tart_build() {
  local name="$1" key="${2:-bbbbbbbbbbbbbbbb}" d="$PMM_DATA_HOME/images/$1/arm64"
  mkdir -p "$PMM_IMAGES_HOME/$name" "$d" "$PMM_DATA_HOME/keys/$name"
  printf 'backend: tart\ndistro: macos\narch: [arm64]\nbase: ghcr.io/x/macos:latest\nuser: {name: owner, bootstrap: {name: admin, password: admin}}\n' > "$PMM_IMAGES_HOME/$name/image.yml"
  echo key > "$PMM_DATA_HOME/keys/$name/id_ed25519"
  printf 'id: local/%s\nname: %s\narch: arm64\nbackend: tart\ncache_key: %s\ndisk: pmm-image-%s-%s\nuser: owner\n' \
    "$name" "$name" "$key" "$name" "$key" > "$d/meta.yml"
  echo stopped > "$TART_STUB/pmm-image-$name-$key"
}

# What is on <image>'s arm64 builds: the machines and snapshots, space-separated
held() { (load_images; holders_of "$1" arm64 | paste -sd' ' -); }
