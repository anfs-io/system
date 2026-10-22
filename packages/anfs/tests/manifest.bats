#!/usr/bin/env bats
# lib/anfs/manifest.sh: links:, files: and platforms: read into one plan input; every refusal.
# Temp dirs only. Run: bats packages/anfs/tests/manifest.bats

setup() {
  LIBDIR="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  T=$(mkdir -p "$BATS_TEST_TMPDIR/t" && cd -P "$BATS_TEST_TMPDIR/t" && pwd -P)
  export HOME="$T/home"
  TREE="$T/pkg/home"
  mkdir -p "$TREE/.local/lib/x" "$TREE/.config/mise/conf.d" "$TREE/.ssh/config.d" "$TREE/docs/sub" "$HOME"
  echo a > "$TREE/.local/lib/x/a.sh"
  echo b > "$TREE/.local/lib/x/b.sh"
  echo t > "$TREE/.config/mise/conf.d/op.toml"
  echo c > "$TREE/.ssh/config.d/99-op.conf"
  echo r > "$TREE/.toolrc"
  echo d > "$TREE/docs/one.md"
  echo s > "$TREE/docs/sub/two.md"
  echo l > "$TREE/system.list"
  YML="$T/pkg/package.yml"
  # shellcheck source=/dev/null
  source "$LIBDIR/link.sh"
  source "$LIBDIR/manifest.sh"
}

yml() { printf '%s\n' "$@" > "$YML"; }

# plan this manifest on <platform>
plan() {
  local rows
  rows=$(anfs_manifest_read "$YML")
  anfs_manifest_plan "$rows" "$TREE" "${1:-macos}" ${2:+"$2"}
}

has() { case $'\n'"$1" in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1; }

@test "no links: or files: is every file, per file" {
  yml "version: 0.1.0"
  plan
  [ -z "$ANFS_MF_ERR$ANFS_MF_SRCS$ANFS_MF_COPIES$ANFS_MF_OFF$ANFS_MF_DIRS" ]
  [ "$(printf '%s' "$ANFS_MF_LINKS" | LC_ALL=C sort | tr '\n' ' ')" = ".config/mise/conf.d/op.toml .local/lib/x/a.sh .local/lib/x/b.sh .ssh/config.d/99-op.conf .toolrc docs/one.md docs/sub/two.md system.list " ]
}

@test "a directory string is one link; its files are not linked one by one" {
  yml "links: [.local/lib/x/]"
  plan
  has "$ANFS_MF_LINKS" .local/lib/x
  ! has "$ANFS_MF_LINKS" .local/lib/x/a.sh
  [ "$ANFS_MF_DIRS" = $'.local/lib/x\n' ]
  has "$ANFS_MF_LINKS" .toolrc
}

@test "path entries: a file, a directory per file, a directory as one link, each for its platforms" {
  yml "links:" \
    "  - {path: .ssh/config.d/99-op.conf, platforms: [macos]}" \
    "  - {path: .config/mise/conf.d/op.toml, platforms: [linux]}" \
    "  - {path: docs, platforms: [debian]}" \
    "  - {path: .local/lib/x/, platforms: [fedora]}"
  plan macos
  has "$ANFS_MF_LINKS" .ssh/config.d/99-op.conf
  ! has "$ANFS_MF_LINKS" .config/mise/conf.d/op.toml
  ! has "$ANFS_MF_LINKS" docs/one.md && ! has "$ANFS_MF_LINKS" docs/sub/two.md
  ! has "$ANFS_MF_LINKS" .local/lib/x && ! has "$ANFS_MF_LINKS" .local/lib/x/a.sh
  has "$ANFS_MF_OFF" $'.config/mise/conf.d/op.toml\tlinux'
  has "$ANFS_MF_OFF" $'docs\tdebian'
  has "$ANFS_MF_OFF" $'.local/lib/x/\tfedora'

  plan debian
  ! has "$ANFS_MF_LINKS" .ssh/config.d/99-op.conf
  has "$ANFS_MF_LINKS" .config/mise/conf.d/op.toml
  has "$ANFS_MF_LINKS" docs/one.md && has "$ANFS_MF_LINKS" docs/sub/two.md
  ! has "$ANFS_MF_LINKS" .local/lib/x

  plan fedora
  has "$ANFS_MF_LINKS" .config/mise/conf.d/op.toml
  has "$ANFS_MF_LINKS" .local/lib/x && [ "$ANFS_MF_DIRS" = $'.local/lib/x\n' ]
  ! has "$ANFS_MF_LINKS" docs/one.md
}

@test "src: ~, \$VAR, \${VAR}, a default dest; platforms filter it" {
  export ANFS_T_VAULT="$T/vaults"
  yml "links:" \
    "  - {src: ~/somewhere/apex}" \
    "  - {src: \$ANFS_T_VAULT/a, dest: v/a}" \
    "  - {src: '\${ANFS_T_VAULT}/b/./c/../b', dest: b/}" \
    "  - {src: /opt/x, dest: x, platforms: [linux]}"
  plan macos
  [ -z "$ANFS_MF_ERR" ]
  has "$ANFS_MF_SRCS" "apex	$HOME/somewhere/apex"
  has "$ANFS_MF_SRCS" "v/a	$T/vaults/a"
  has "$ANFS_MF_SRCS" "b	$T/vaults/b/b"
  has "$ANFS_MF_OFF" $'x\tlinux'
  ! has "$ANFS_MF_LINKS" apex
}

@test "a relative src is from ANFS_MF_SRC_BASE, refused without it" {
  yml "links: [{src: ../shared, dest: shared}]"
  run plan
  [ "$status" -eq 2 ]
  plan || true
  [[ "$ANFS_MF_ERR" == *"a src: here is absolute, or starts with ~ or a variable: ../shared"* ]]
  ANFS_MF_SRC_BASE="$T/spaces/acme/team"
  plan
  [ "$ANFS_MF_SRCS" = "shared	$T/spaces/acme/shared"$'\n' ]
}

@test "files: strings and maps are copies, not links; platforms filter them" {
  yml "files:" "  - system.list" "  - {path: .toolrc, platforms: [debian]}"
  plan macos
  [ "$ANFS_MF_COPIES" = $'system.list\n' ]
  ! has "$ANFS_MF_LINKS" system.list && ! has "$ANFS_MF_LINKS" .toolrc
  has "$ANFS_MF_OFF" $'.toolrc\tdebian'
  plan debian
  has "$ANFS_MF_COPIES" .toolrc
}

@test "anfs_manifest_match: linux is any distro; debian is not fedora" {
  anfs_manifest_match debian linux
  anfs_manifest_match fedora macos,linux
  ! anfs_manifest_match macos linux
  ! anfs_manifest_match fedora debian
  anfs_manifest_match macos macos
  ! anfs_manifest_match debian macos
}

@test "every refusal, each with its message, all listed at once; exit 2" {
  yml "links:" \
    "  - .toolrc" \
    "  - {path: nowhere.txt, platforms: [macos]}" \
    "  - .toolrc/" \
    "  - /etc/" \
    "  - ../up/" \
    "  - .local/lib/x/" \
    "  - {path: .local/lib/x/a.sh, platforms: [macos]}" \
    "  - docs/" \
    "  - docs/sub/" \
    "  - {path: .ssh/config.d/99-op.conf, platforms: [beos]}" \
    "  - {path: .config/mise/conf.d/op.toml, platforms: []}" \
    "  - {path: x, src: /y}" \
    "  - {dest: z}" \
    "  - {path: system.list, platforms: [macos], color: red}" \
    "  - {src: /opt/z, dest: ../out}" \
    "  - {src: /opt/w, dest: /abs}" \
    "  - {src: \$ANFS_T_UNSET/x}" \
    "  - {path: .toolrc}" \
    "files:" \
    "  - .local/lib/x/b.sh" \
    "  - docs/sub/" \
    "  - .local/lib/x/"
  run plan
  [ "$status" -eq 2 ]
  plan || true
  local e="$ANFS_MF_ERR"
  printf '%s' "$e"
  [[ "$e" == *"a links: path without a trailing / says nothing the default does not: .toolrc"* ]]
  [[ "$e" == *"not in the tree: nowhere.txt"* ]]
  [[ "$e" == *"a trailing / on what is not a directory: .toolrc/"* ]]
  [[ "$e" == *"a path in the tree is needed: /etc"* ]]
  [[ "$e" == *"a path in the tree is needed: ../up"* ]]
  [[ "$e" == *".local/lib/x/a.sh is inside the directory link .local/lib/x/"* ]]
  [[ "$e" == *".local/lib/x/b.sh is inside the directory link .local/lib/x/"* ]]
  [[ "$e" == *"a directory link inside another: docs/sub/ is in docs/"* ]]
  [[ "$e" == *"unknown platform (beos)"* ]]
  [[ "$e" == *"platforms: [] names none: .config/mise/conf.d/op.toml"* ]]
  [[ "$e" == *"an entry has a path or a src, not both: x, /y"* ]]
  [[ "$e" == *"a links: entry needs a path or a src"* ]]
  [[ "$e" == *"unknown key (color)"* ]]
  [[ "$e" == *"dest must stay inside the target: '../out'"* ]]
  [[ "$e" == *"dest must stay inside the target: '/abs'"* ]]
  [[ "$e" == *'$ANFS_T_UNSET is not set'* ]]
  [[ "$e" == *"{path: .toolrc} without platforms says nothing the default does not"* ]]
  [[ "$e" == *"the same path twice: .local/lib/x"* ]]
  [[ "$e" == *"files: a directory is not a file: docs/sub"* || "$e" == *"the same path twice: docs/sub"* ]]
  [ -z "$ANFS_MF_LINKS" ]
}

@test "a files: directory is refused, and so is a kind the tool does not take" {
  yml "files: [docs]" "links: [{src: /opt/x}]"
  plan || true
  [[ "$ANFS_MF_ERR" == *"files: a directory is not a file: docs"* ]]
  yml "links: [{src: /opt/x}, .local/lib/x/]"
  ANFS_MF_KINDS="path dir file"
  run plan
  [ "$status" -eq 2 ]
  plan || true
  [ "$ANFS_MF_ERR" = $'a src: link (/opt/x) is not taken here\n' ]
}

@test "links: or files: that is not a list, an entry that is not a path or a map" {
  yml "links: {a: b}" "files: [3]"
  plan || true
  [[ "$ANFS_MF_ERR" == *"links: is not a list"* ]]
  [[ "$ANFS_MF_ERR" == *"an entry is a path or a map, not !!int"* ]]
}

@test "one read of three manifests: each its rows, by index; a malformed one named, the others read" {
  local a="$T/a.yml" b="$T/b.yml" c="$T/c.yml"
  printf 'links: [x/]\n' > "$a"
  printf 'files: [y]\n' > "$b"
  printf 'links: [{src: /z}]\n' > "$c"
  # one yq for the three
  yq() { echo . >> "$T/yq.calls"; command yq "$@"; }
  run anfs_manifest_read "$a" "$b" "$c"
  [ "${lines[0]}" = $'0\tdir\tx\t\t' ]
  [ "${lines[1]}" = $'1\tfile\ty\t\t' ]
  [ "${lines[2]}" = $'2\tsrc\t/z\t\t' ]
  rm -f "$T/yq.calls"
  anfs_manifest_read "$a" "$b" "$c" >/dev/null
  [ "$(wc -l < "$T/yq.calls")" -eq 1 ]
  printf 'links: [x/\n  oops: : :\n' > "$b"
  run anfs_manifest_read "$a" "$b" "$c"
  [ "${lines[0]}" = $'0\tdir\tx\t\t' ]
  [[ "${lines[1]}" == $'1\terror\tcannot read '*"b.yml" ]]
  [ "${lines[2]}" = $'2\tsrc\t/z\t\t' ]
}

@test "an extra expression rides along in the same yq" {
  printf 'links: [x/]\nskills: [{repo: a}]\n' > "$YML"
  ANFS_MF_YQ_EXTRA='(.skills[]? | [fileIndex, "X", .repo] | join(strenv(ANFS_MF_SEP)))'
  run anfs_manifest_read "$YML"
  [ "${lines[1]}" = $'0\textra\ta' ]
}

@test "a candidate list (wsm's) instead of the tree's files" {
  yml "links: [docs/]"
  printf 'docs/one.md\n.toolrc\n' > "$T/cand"
  plan macos "$T/cand"
  [ "$ANFS_MF_LINKS" = $'.toolrc\ndocs\n' ]
}

@test "parses and runs under /bin/bash 3.2" {
  [[ -x /bin/bash ]] || skip "no /bin/bash"
  yml "links:" "  - .local/lib/x/" "  - {path: .ssh/config.d/99-op.conf, platforms: [linux]}" "  - {src: ~/v, dest: v}" "files: [system.list]"
  run /bin/bash -c 'set -euo pipefail; source "$1"; source "$2"
    rows=$(anfs_manifest_read "$3")
    anfs_manifest_plan "$rows" "$4" macos
    printf "%s|%s|%s|%s\n" "$ANFS_MF_DIRS" "$ANFS_MF_COPIES" "$ANFS_MF_SRCS" "$ANFS_MF_OFF"' _ \
    "$LIBDIR/link.sh" "$LIBDIR/manifest.sh" "$YML" "$TREE"
  [ "$status" -eq 0 ]
  [[ "$output" == *".local/lib/x"*"system.list"*"v	$HOME/v"*".ssh/config.d/99-op.conf	linux"* ]]
}
