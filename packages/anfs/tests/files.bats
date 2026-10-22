#!/usr/bin/env bats
# lib/anfs/files.sh: copy-if-missing. Temp dirs only: the target is a fake $HOME with the sources
# in it. Run: bats packages/anfs/tests/files.bats

setup() {
  LIBDIR="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  T=$(mkdir -p "$BATS_TEST_TMPDIR/home" && cd -P "$BATS_TEST_TMPDIR/home" && pwd -P)
  export ANFS_SOURCES_HOME="$T/.local/share/anfs/sources"
  FROM="$ANFS_SOURCES_HOME/core/packages/tool/home"
  LIST="$BATS_TEST_TMPDIR/list"
  SKIP="$BATS_TEST_TMPDIR/skip"
  mkdir -p "$FROM/.config/tool"
  echo defaults > "$FROM/.config/tool/defaults.conf"
  chmod 640 "$FROM/.config/tool/defaults.conf"
  echo top > "$FROM/.toprc"
  printf '.config/tool/defaults.conf\n.toprc\n' > "$LIST"
  : > "$SKIP"
  # shellcheck source=/dev/null
  source "$LIBDIR/link.sh"
  source "$LIBDIR/files.sh"
}

state_of() { awk -F'\t' -v p="$1" '$2 == p { print $1 }' <<< "$output"; }
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

@test "missing is copied with its mode, then present; nothing is a link" {
  run anfs_files_plan "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  [ "$(state_of .config/tool/defaults.conf)" = missing ]
  anfs_files_apply "$FROM" "$T" "$LIST" >/dev/null
  [ -f "$T/.config/tool/defaults.conf" ] && [ ! -L "$T/.config/tool/defaults.conf" ]
  [ "$(cat "$T/.config/tool/defaults.conf")" = defaults ]
  [ "$(mode "$T/.config/tool/defaults.conf")" = 640 ]
  [ -z "$(find "$T/.config" -name '*.anfs-copy.*')" ]
  run anfs_files_plan "$FROM" "$T" "$LIST"
  [ "$(state_of .config/tool/defaults.conf)" = present ]
  [ "$(state_of .toprc)" = present ]
}

@test "differs is reported and left: the user's bytes are never touched" {
  anfs_files_apply "$FROM" "$T" "$LIST" >/dev/null
  echo mine > "$T/.toprc"
  run anfs_files_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  [ "$(state_of .toprc)" = differs ]
  [ "$(cat "$T/.toprc")" = mine ]
  # deleted, it is copied again
  rm "$T/.toprc"
  anfs_files_apply "$FROM" "$T" "$LIST" >/dev/null
  [ "$(cat "$T/.toprc")" = top ]
}

@test "in the way: a directory, a link, a link on the way into the sources; nothing is copied; all listed" {
  mkdir -p "$T/.toprc"
  run anfs_files_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'in the way\t.toprc\ta directory'* ]]
  [ ! -e "$T/.config/tool/defaults.conf" ]
  rmdir "$T/.toprc"
  ln -s "$FROM/.toprc" "$T/.toprc"
  mkdir -p "$T/.config"
  ln -s ../.local/share/anfs/sources/core/packages/tool/home/.config/tool "$T/.config/tool"
  run anfs_files_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 1 ]
  [[ "$output" == *$'in the way\t.toprc\ta link'* ]]
  [[ "$output" == *$'in the way\t.config/tool/defaults.conf\tinside a directory link: .config/tool -> core/packages/tool/home/.config/tool'* ]]
  [ "$(readlink "$T/.toprc")" = "$FROM/.toprc" ]
}

@test "the skip set is skipped" {
  echo .toprc > "$SKIP"
  run anfs_files_apply "$FROM" "$T" "$LIST" "$SKIP"
  [ "$(state_of .toprc)" = skip ]
  [ ! -e "$T/.toprc" ]
}

@test "a file that appears between the plan and the copy is never written over" {
  # cp is where the time goes: something writes the target meanwhile
  cp() { command cp "$@"; echo intruder > "$T/.toprc"; }
  printf '.toprc\n' > "$LIST"
  run anfs_files_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 1 ]
  [ "$(cat "$T/.toprc")" = intruder ]
  [ -z "$(find "$T" -maxdepth 1 -name '*.anfs-copy.*')" ]
}

@test "names are data (space, +, a leading -); a tab, a missing file and a directory are refused" {
  mkdir -p "$FROM/a b"
  echo x > "$FROM/a b/-c+d"
  printf 'a b/-c+d\n' > "$LIST"
  anfs_files_apply "$FROM" "$T" "$LIST" >/dev/null
  [ "$(cat "$T/a b/-c+d")" = x ]
  printf 'a\tb\n' > "$LIST"
  run anfs_files_plan "$FROM" "$T" "$LIST"
  [ "$status" -eq 2 ]
  printf 'nope\n' > "$LIST"
  run anfs_files_plan "$FROM" "$T" "$LIST"
  [ "$status" -eq 2 ]
  printf '.config/tool\n' > "$LIST"
  run anfs_files_plan "$FROM" "$T" "$LIST"
  [ "$status" -eq 2 ]
}

@test "under macOS's bash 3.2: plan and apply" {
  [[ -x /bin/bash ]] || skip "no /bin/bash"
  run /bin/bash -c 'set -euo pipefail; source "$1"; source "$2"
    anfs_files_apply "$3" "$4" "$5" >/dev/null
    anfs_files_plan "$3" "$4" "$5"' _ "$LIBDIR/link.sh" "$LIBDIR/files.sh" "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  [ "$(state_of .toprc)" = present ]
}
