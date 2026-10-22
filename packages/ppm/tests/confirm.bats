#!/usr/bin/env bats
# What ppm asks before (anfs_confirm): remove, and file reset. The real ppm in a temp $HOME, its
# libraries linked from this clone; nothing is installed or removed.
# Run: bats packages/ppm/tests/

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

setup() {
  local pkgs
  pkgs="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  PPM="$pkgs/ppm/home/.local/bin/ppm"
  export HOME="$BATS_TEST_TMPDIR/home"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_SOURCES_HOME PPM_STATE_HOME
  mkdir -p "$HOME/.local/lib" "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources" "$HOME/.local/state/ppm/installed"
  ln -s "$pkgs/anfs/home/.local/lib/anfs" "$HOME/.local/lib/anfs"
  ln -s "$pkgs/ppm/home/.local/lib/ppm" "$HOME/.local/lib/ppm"
  : > "$HOME/.config/anfs/user.list"
  : > "$HOME/.config/anfs/system.list"
  export ANFS_LOG=off
}

@test "remove asks: no terminal and no -y is 77, and nothing is removed" {
  run "$PPM" remove nothing </dev/null
  [ "$status" -eq 77 ]
  [[ "$output" == *"remove takes away nothing"*"pass -y"* ]]
}

@test "file reset asks: no terminal and no -y is 77" {
  run "$PPM" file reset "$HOME/.zshrc" </dev/null
  [ "$status" -eq 77 ]
  [[ "$output" == *"file reset deletes the claimed copies"*"pass -y"* ]]
  run "$PPM" file reset -y "$HOME/.zshrc" </dev/null
  [ "$status" -ne 77 ]
  [[ "$output" == *"is not claimed"* ]]
}

@test "the help says what -y skips" {
  run "$PPM" help remove
  [[ "$output" == *"Do not ask before removing"* ]]
  run "$PPM" help install
  [[ "$output" == *"Do not ask before installing a whole repo/ or @category"* ]]
}
