#!/usr/bin/env bats
# lib/anfs/link.sh: the plan (every class), names as data, directories on the way, links as stow
# writes them, unlinking, owners. Temp dirs only: the target is a fake $HOME with the sources in it.
# Run: bats packages/anfs/tests/link.bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../home/.local/lib/anfs/link.sh"
  # canonical, so what the tests compare is what the library computes (macOS: /var is /private/var)
  T=$(mkdir -p "$BATS_TEST_TMPDIR/home" && cd -P "$BATS_TEST_TMPDIR/home" && pwd -P)
  export ANFS_SOURCES_HOME="$T/.local/share/anfs/sources"
  FROM="$ANFS_SOURCES_HOME/core/packages/tool/home"
  OTHER="$ANFS_SOURCES_HOME/stack/packages/other/home"
  LIST="$BATS_TEST_TMPDIR/list"
  SKIP="$BATS_TEST_TMPDIR/skip"
  mkdir -p "$FROM/.config/tool" "$OTHER/.config/tool"
  echo rc > "$FROM/.config/tool/rc"
  echo env > "$FROM/.toolenv"
  : > "$SKIP"
  # shellcheck source=/dev/null
  source "$LIB"
}

# The list of every file under <dir> (default: $FROM), as the tools build it
list() { (cd "${1:-$FROM}" && find . \( -type f -o -type l \) | sed 's|^\./||' | LC_ALL=C sort) > "$LIST"; }

# The class the last plan gave <path>
class_of() { awk -F'\t' -v p="$1" '$2 == p { print $1 }' <<< "$output"; }

@test "link: nothing there, a relative link per file, directories made real" {
  list
  run anfs_link_plan "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  [ "$(class_of .config/tool/rc)" = link ]
  [ "$(class_of .toolenv)" = link ]
  [ ! -e "$T/.config" ]

  anfs_link_apply "$FROM" "$T" "$LIST" >/dev/null
  [ -d "$T/.config/tool" ] && [ ! -L "$T/.config/tool" ]
  [ "$(readlink "$T/.config/tool/rc")" = ../../.local/share/anfs/sources/core/packages/tool/home/.config/tool/rc ]
  [ "$(readlink "$T/.toolenv")" = .local/share/anfs/sources/core/packages/tool/home/.toolenv ]
  [ "$(cat "$T/.config/tool/rc")" = rc ]
}

@test "keep: a second apply rewrites nothing" {
  list
  anfs_link_apply "$FROM" "$T" "$LIST" >/dev/null
  local before
  before=$(ls -li "$T/.config/tool/rc" | awk '{print $1}')
  run anfs_link_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  [ "$(class_of .config/tool/rc)" = keep ]
  [ "$(class_of .toolenv)" = keep ]
  [ "$(ls -li "$T/.config/tool/rc" | awk '{print $1}')" = "$before" ]
}

@test "keep: a relative link to the file written another way (wsm add, ppm file add) is kept" {
  list
  mkdir -p "$T/.config/tool"
  ln -s "../../.local/share/anfs/sources/core/packages/tool/home/.config/tool/../tool/rc" "$T/.config/tool/rc"
  run anfs_link_plan "$FROM" "$T" "$LIST"
  [ "$(class_of .config/tool/rc)" = keep ]
}

@test "replace: an absolute link to the file, a link to another of its files, a dangling one" {
  echo old > "$FROM/.config/tool/old"
  list
  mkdir -p "$T/.config/tool"
  ln -s "$FROM/.toolenv" "$T/.toolenv"
  ln -s "$FROM/.config/tool/old" "$T/.config/tool/rc"
  ln -s "$ANFS_SOURCES_HOME/stack/packages/gone/home/.config/tool/old" "$T/.config/tool/old"
  run anfs_link_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  [ "$(class_of .toolenv)" = replace ]
  [ "$(class_of .config/tool/rc)" = replace ]
  [ "$(class_of .config/tool/old)" = replace ]
  [[ "$(readlink "$T/.toolenv")" != /* ]]
  [ "$(cat "$T/.config/tool/rc")" = rc ]
  [ "$(cat "$T/.config/tool/old")" = old ]
}

@test "skip: the skip set by exact name (+ and . are not patterns), and .DS_Store" {
  echo a > "$FROM/.config/tool/a+b"
  echo a > "$FROM/.config/tool/aab"
  echo a > "$FROM/.config/tool/x.y"
  echo a > "$FROM/.config/tool/xzy"
  echo junk > "$FROM/.config/tool/.DS_Store"
  list
  printf '%s\n' .config/tool/a+b .config/tool/x.y > "$SKIP"
  run anfs_link_apply "$FROM" "$T" "$LIST" "$SKIP"
  [ "$status" -eq 0 ]
  [ "$(class_of .config/tool/a+b)" = skip ]
  [ "$(class_of .config/tool/x.y)" = skip ]
  [ "$(class_of .config/tool/.DS_Store)" = skip ]
  [ "$(class_of .config/tool/aab)" = link ]
  [ "$(class_of .config/tool/xzy)" = link ]
  [ ! -e "$T/.config/tool/a+b" ] && [ ! -e "$T/.config/tool/x.y" ] && [ ! -e "$T/.config/tool/.DS_Store" ]
  [ -L "$T/.config/tool/aab" ]
}

@test "other: a live link into another package, named by its owner; nothing is touched" {
  echo theirs > "$OTHER/.config/tool/rc"
  list
  mkdir -p "$T/.config/tool"
  ln -s "../../.local/share/anfs/sources/stack/packages/other/home/.config/tool/rc" "$T/.config/tool/rc"
  run anfs_link_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other	.config/tool/rc	stack/packages/other/home/.config/tool/rc"* ]]
  [ "$(cat "$T/.config/tool/rc")" = theirs ]
  [ ! -e "$T/.toolenv" ]
}

@test "conflict: a file, a directory, a link elsewhere; every one is reported and nothing changes" {
  echo x > "$FROM/.config/tool/dir"
  echo x > "$FROM/.config/tool/elsewhere"
  echo x > "$FROM/.config/tool/free"
  list
  mkdir -p "$T/.config/tool/dir" "$T/dotfiles"
  echo mine > "$T/.config/tool/rc"
  echo mine > "$T/dotfiles/e"
  ln -s ../../dotfiles/e "$T/.config/tool/elsewhere"
  run anfs_link_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict	.config/tool/rc	a file"* ]]
  [[ "$output" == *"conflict	.config/tool/dir	a directory"* ]]
  [[ "$output" == *"conflict	.config/tool/elsewhere	a link to ../../dotfiles/e"* ]]
  [ "$(class_of .config/tool/free)" = link ]
  [ ! -e "$T/.config/tool/free" ] && [ ! -e "$T/.toolenv" ]
  [ "$(cat "$T/.config/tool/rc")" = mine ]
}

@test "a dangling link elsewhere is the user's: a conflict, not replaced" {
  list
  ln -s /nowhere/at/all "$T/.toolenv"
  run anfs_link_plan "$FROM" "$T" "$LIST"
  [ "$status" -eq 1 ]
  [ "$(class_of .toolenv)" = conflict ]
}

@test "names are data: spaces, +, (, [, a leading -, a dot file" {
  local n
  mkdir -p "$FROM/a dir"
  for n in "sp ace" "a+b" "p(x)" "b[1]" "-lead" ".dot" "a dir/-x [y] (z)+"; do echo "$n" > "$FROM/$n"; done
  list
  run anfs_link_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  for n in "sp ace" "a+b" "p(x)" "b[1]" "-lead" ".dot" "a dir/-x [y] (z)+"; do
    [ -L "$T/$n" ] && [ "$(cat "$T/$n")" = "$n" ]
  done
  run anfs_link_plan "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  [ -z "$(awk -F'\t' '$1 != "keep"' <<< "$output")" ]
}

@test "a name with a newline is refused, once, and nothing is linked" {
  echo x > "$FROM/bad"$'\n'"name"
  echo y > "$FROM/also"$'\n'"bad"
  list
  run anfs_link_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 2 ]
  [ "$(grep -c newline <<< "$output")" -eq 1 ]
  [ ! -e "$T/.toolenv" ]
}

@test "a name with a tab is refused" {
  echo x > "$FROM/tab"$'\t'"name"
  list
  run anfs_link_plan "$FROM" "$T" "$LIST"
  [ "$status" -eq 2 ]
  [[ "$output" == *"tab"* ]]
}

@test "a directory on the way that links out of the target is a conflict" {
  mkdir -p "$BATS_TEST_TMPDIR/outside/tool"
  mkdir -p "$T/.config"
  ln -s "$BATS_TEST_TMPDIR/outside/tool" "$T/.config/tool"
  list
  run anfs_link_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 1 ]
  [[ "$(class_of .config/tool/rc)" == conflict ]]
  [[ "$output" == *"a link out of the target on the way: .config/tool"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/outside/tool/rc" ]
}

@test "a directory on the way that links inside the target is followed" {
  mkdir -p "$T/.config" "$T/real/tool"
  ln -s ../real/tool "$T/.config/tool"
  list
  run anfs_link_apply "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  [ -L "$T/real/tool/rc" ] && [ "$(cat "$T/.config/tool/rc")" = rc ]
  run anfs_link_plan "$FROM" "$T" "$LIST"
  [ "$(class_of .config/tool/rc)" = keep ]
}

@test "a file where a directory goes is a conflict" {
  echo mine > "$T/.config"
  list
  run anfs_link_plan "$FROM" "$T" "$LIST"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict	.config/tool/rc	a file where a directory goes: .config"* ]]
}

@test "the links are byte for byte what stow --no-folding writes, and stow -D removes them" {
  command -v stow >/dev/null || skip "stow is not installed"
  mkdir -p "$FROM/.local/bin" "$FROM/.local/share/tool"
  echo b > "$FROM/.local/bin/tool"
  echo s > "$FROM/.local/share/tool/data"
  list
  anfs_link_apply "$FROM" "$T" "$LIST" >/dev/null
  local f ours=""
  while IFS= read -r f; do ours="$ours$f -> $(readlink "$T/$f")"$'\n'; done < "$LIST"
  while IFS= read -r f; do rm "$T/$f"; done < "$LIST"
  stow --no-folding -d "${FROM%/*}" -t "$T" home
  local theirs=""
  while IFS= read -r f; do theirs="$theirs$f -> $(readlink "$T/$f")"$'\n'; done < "$LIST"
  [ "$ours" = "$theirs" ]

  # stow's links are the plan's keep, and stow -D undoes what the library linked
  run anfs_link_plan "$FROM" "$T" "$LIST"
  [ -z "$(awk -F'\t' '$1 != "keep"' <<< "$output")" ]
  stow -D -d "${FROM%/*}" -t "$T" home
  anfs_link_apply "$FROM" "$T" "$LIST" >/dev/null
  stow -D -d "${FROM%/*}" -t "$T" home
  [ -z "$(find "$T" -type l)" ]
}

@test "anfs_unlink removes its links and leaves a file, a link elsewhere and another package's" {
  echo x > "$FROM/.config/tool/mine"
  echo x > "$FROM/.config/tool/theirs"
  echo x > "$FROM/.config/tool/elsewhere"
  echo x > "$OTHER/.config/tool/theirs"
  list
  anfs_link_apply "$FROM" "$T" <(grep -v -e mine -e theirs -e elsewhere "$LIST") >/dev/null
  echo mine > "$T/.config/tool/mine"
  ln -s ../../.local/share/anfs/sources/stack/packages/other/home/.config/tool/theirs "$T/.config/tool/theirs"
  ln -s /tmp "$T/.config/tool/elsewhere"
  anfs_unlink "$FROM" "$T" "$LIST"
  [ ! -e "$T/.config/tool/rc" ] && [ ! -L "$T/.toolenv" ]
  [ -f "$T/.config/tool/mine" ] && [ -L "$T/.config/tool/theirs" ] && [ -L "$T/.config/tool/elsewhere" ]
  # the directories stay, as stow -D leaves them
  [ -d "$T/.config/tool" ]
}

@test "anfs_unlink takes a dangling link into the directory; _tree needs no list" {
  list
  anfs_link_apply "$FROM" "$T" "$LIST" >/dev/null
  mkdir -p "$T/.config/tool"
  ln -s ../../.local/share/anfs/sources/core/packages/tool/home/.config/tool/gone "$T/.config/tool/gone"
  echo .config/tool/gone >> "$LIST"
  anfs_unlink "$FROM" "$T" "$LIST"
  [ ! -L "$T/.config/tool/gone" ]

  anfs_link_apply "$FROM" "$T" <(grep -v gone "$LIST") >/dev/null
  anfs_unlink_tree "$FROM" "$T"
  [ -z "$(find "$T" -type l)" ]
}

@test "anfs_link_owner: a link into the sources, live, dangling or through a local-path source" {
  list
  anfs_link_apply "$FROM" "$T" "$LIST" >/dev/null
  run anfs_link_owner "$T/.config/tool/rc"
  [ "$status" -eq 0 ] && [ "$output" = core/packages/tool/home/.config/tool/rc ]

  ln -s ../../.local/share/anfs/sources/stack/packages/gone/x "$T/.config/tool/dangling"
  run anfs_link_owner "$T/.config/tool/dangling"
  [ "$output" = stack/packages/gone/x ]

  # a local-path source is a link in the sources dir; a link to its real directory is still its
  mkdir -p "$BATS_TEST_TMPDIR/mine/packages/p/home"
  echo m > "$BATS_TEST_TMPDIR/mine/packages/p/home/f"
  ln -s "$BATS_TEST_TMPDIR/mine" "$ANFS_SOURCES_HOME/user"
  ln -s "$BATS_TEST_TMPDIR/mine/packages/p/home/f" "$T/f"
  run anfs_link_owner "$T/f"
  [ "$output" = user/packages/p/home/f ]

  echo plain > "$T/plain"
  ln -s /tmp "$T/tmp"
  run anfs_link_owner "$T/plain"
  [ "$status" -eq 1 ]
  run anfs_link_owner "$T/tmp"
  [ "$status" -eq 1 ]
}

@test "anfs_link_one: one relative link, its directories made" {
  anfs_link_one "$FROM/.config/tool/rc" "$T/a/b/c/rc"
  [ -L "$T/a/b/c/rc" ] && [[ "$(readlink "$T/a/b/c/rc")" == ../* ]]
  [ "$(cat "$T/a/b/c/rc")" = rc ]
  run anfs_link_one "$FROM/.toolenv" "$T/a/b/c/rc"
  [ "$status" -ne 0 ]
}

@test "anfs_relpath" {
  [ "$(anfs_relpath /a/b /a/b/c/d)" = c/d ]
  [ "$(anfs_relpath /a/b/c /a/x/y)" = ../../x/y ]
  [ "$(anfs_relpath /a /a)" = . ]
  [ "$(anfs_relpath / /a/b)" = a/b ]
  [ "$(anfs_relpath /a/b /c)" = ../../c ]
}

@test "under macOS's bash 3.2: plan, apply, keep, unlink" {
  [[ -x /bin/bash ]] || skip "no /bin/bash"
  list
  run /bin/bash -c 'set -euo pipefail; source "$1"
    anfs_link_apply "$2" "$3" "$4" >/dev/null
    anfs_link_plan "$2" "$3" "$4"
    anfs_unlink "$2" "$3" "$4"' _ "$LIB" "$FROM" "$T" "$LIST"
  [ "$status" -eq 0 ]
  [ "$(class_of .config/tool/rc)" = keep ]
  [ -z "$(find "$T" -type l)" ]
}
