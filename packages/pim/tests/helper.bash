# Shared setup for pim's bats suites: an isolated HOME and pim state, anfs sources made of plain
# directories, pim's libraries sourced directly, and stubs (tests/stubs) first on PATH so nothing
# boots a VM or touches the network. Stubs log each call to $PIM_CALLS.

setup_pim() {
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  unset ANFS_CONFIG_HOME ANFS_DATA_HOME ANFS_CACHE_HOME ANFS_STATE_HOME
  unset PIM_CONFIG_HOME PIM_DATA_HOME PIM_STATE_HOME PIM_CACHE_HOME PIM_IMAGES_HOME PIM_LIB_DIR
  mkdir -p "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources"
  export PIM_HOST_OS=darwin PIM_HOST_ARCH=arm64 PIM_SSH_PORT_BASE=42200
  export PIM_CALLS="$T/calls"
  : > "$PIM_CALLS"
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"

  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/pim"
  local anfs="$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs"
  # shellcheck source=/dev/null
  source "$anfs/paths.sh"; source "$anfs/sources.sh"; source "$anfs/cli.sh"
  anfs_tool_paths pim
  anfs_gitsrc_env
  PIM_IMAGES_HOME="$PIM_CONFIG_HOME/images" PIM_LOCAL_SOURCE=local PIM_LIB_DIR="$lib"
  PIM_INSTALL_TIMEOUT=60 PIM_SSH_TIMEOUT=5 PIM_INSTALL=build
  local f
  for f in "$lib"/*.sh; do source "$f"; done
  mkdir -p "$PIM_IMAGES_HOME"
}

# An anfs source <alias> holding images/, listed and linked like `anfs src update` does
add_source() {
  mkdir -p "$T/srcs/$1/images"
  ln -sfn "$T/srcs/$1" "$HOME/.local/share/anfs/sources/$1"
  printf '%s  %s\n' "$T/srcs/$1" "$1" >> "$HOME/.config/anfs/user.list"
}

# image <dir> <yaml>: write images/<name>/image.yml under a source dir (or $PIM_IMAGES_HOME)
image() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/image.yml"
}

SHA=6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b
deb_yml() {
  printf 'distro: debian\narch: [arm64, amd64]\niso:\n  arm64: {url: https://x/a.iso, sha256: %s}\n  amd64: {url: https://x/b.iso, sha256: %s}\n%s\n' "$SHA" "$SHA" "${1:-}"
}
