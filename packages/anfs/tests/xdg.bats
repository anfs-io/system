#!/usr/bin/env bats
# The XDG rule (AGENTS.md, "Where files go"): an install writes nothing into a config directory
# but what a package links. install.sh seeds no user.list; core's hooks make no directory under
# ~/.config. pcm's token and pmm's sockets and ssh entries: pcm-local-env.bats, pmm-runtime.bats.
# Run: bats packages/anfs/tests/xdg.bats

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  mkdir -p "$HOME"
}

@test "core/pcm's and core/pmm's hooks make nothing under ~/.config" {
  local pkg
  for pkg in pcm pmm; do
    run bash -c 'source "$1"; ! declare -F post_install >/dev/null || post_install' _ "$REPO/packages/$pkg/install.sh"
    [ "$status" -eq 0 ] || { echo "$pkg: $output"; return 1; }
  done
  [ ! -e "$HOME/.config" ]
  [ -d "$HOME/.local/share/pcm/volumes" ]   # DATA: still made
}

@test "no core install hook writes into a config directory or ~/.ssh" {
  run grep -nE '(mkdir|touch|tee|cp|mv|ln|add_to_file|>>?)[^#]*(\.config/|CONFIG_HOME|XDG_CONFIG|\.ssh/|CONTAINERS_HOME|MACHINES_HOME|IMAGES_HOME|NETWORKS_HOME)' \
    "$REPO"/packages/*/install.sh
  [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "install.sh seeds no user.list: anfs src add makes it" {
  ! grep -n 'install_configs' "$REPO/install.sh"
  ! grep -nE '>[[:space:]]*"?\$ANFS_USER_LIST' "$REPO/install.sh"
  grep -q 'touch "$user_file"' "$REPO/packages/anfs/home/.local/lib/anfs/sources.sh"
}
