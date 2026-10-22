#!/usr/bin/env bats
# links: in space.yml: the vocabulary a package.yml has (lib/anfs/manifest.sh). {src, dest} links
# out of the tree, relative (anfs_link_one), states ok, missing, missing src, wrong, in the way; -f
# moves what is in the way aside; remove takes a link only while it still points at its src.
# Directory links, path entries with platforms, files: copies; a refused manifest makes the space
# invalid.
# Run: bats packages/wsm/tests/links.bats

load helper
setup() {
  wsm_setup
  mksource acme >/dev/null
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/target/sub"
  H="$HOME/spaces/acme/tech"
}

links_json() { wsm ls acme/tech --json | yq -p json -r '.[0].links[] | .dest + "|" + .src + "|" + .status'; }
# <link> is relative and resolves to <dir>
points() { [[ "$(readlink "$1")" != /* ]] && [ "$(cd -P "$1" && pwd -P)" = "$(cd -P "$2" && pwd -P)" ]; }

@test "src with ~ and \$VAR expanded; dest defaults to src's basename; a relative link" {
  mkdir -p "$HOME/data"
  export WSM_T_DIR="$T/target"
  space_def acme tech <<'EOF'
links:
  - src: ~/data
  - src: $WSM_T_DIR/sub
    dest: here/sub
  - src: ${WSM_T_DIR}
    dest: t
EOF
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  points "$H/data" "$HOME/data"
  points "$H/here/sub" "$T/target/sub"
  points "$H/t" "$T/target"
  run wsm ls acme/tech
  [[ "$output" == *$'\tok\t'* ]]
}

@test "an unset variable, a dest with .. or a leading /: that entry invalid and skipped, the rest installed; exit 1" {
  unset WSM_T_NOPE
  space_def acme tech <<EOF
links:
  - src: \$WSM_T_NOPE/x
  - {src: /tmp, dest: ../out}
  - {src: /tmp, dest: /abs}
  - {src: $T/target, dest: good}
EOF
  run wsm install acme/tech
  [ "$status" -eq 1 ]
  [[ "$output" == *'invalid link in acme/tech, skipped: $WSM_T_NOPE is not set'* ]]
  [[ "$output" == *"dest must stay inside the target: '../out'"* ]]
  [[ "$output" == *"dest must stay inside the target: '/abs'"* ]]
  [ ! -e "$T/out" ] && [ ! -e /abs ]
  [ -L "$H/space.yml" ]
  points "$H/good" "$T/target"
  # list: the space ok (an invalid entry is not counted), the entry invalid in --json
  run wsm ls acme/tech
  [[ "$output" == *$'\tok\t'* ]]
  run links_json
  [ "${lines[0]}" = "good|$T/target|ok" ]
  [ "${lines[1]}" = 'x|$WSM_T_NOPE/x|invalid' ]
  wsm remove -y acme/tech >/dev/null
  [ ! -L "$H/good" ]
}

@test "a relative src is from the space's directory; the link is relative" {
  space_def acme tech <<'EOF'
links:
  - {src: ../../../../target, dest: up}
EOF
  # $HOME/spaces/acme/tech/../../../../target is $T/target
  wsm install acme/tech >/dev/null
  points "$H/up" "$T/target"
}

@test "missing src: not linked, said, exit 0, not counted" {
  space_def acme tech <<<'links: [{src: /nonexistent/wsm-test, dest: gone}]'
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing src gone -> /nonexistent/wsm-test (not linked)"* ]]
  [ ! -e "$H/gone" ] && [ ! -L "$H/gone" ]
  run wsm ls acme/tech
  [[ "$output" == *$'\tok\t'* ]]
  [ "$(links_json)" = "gone|/nonexistent/wsm-test|missing src" ]
}

@test "each state in ls; wrong and in the way fail install, -f moves them aside" {
  space_def acme tech <<'EOF'
links:
  - {src: TARGET, dest: a}
  - {src: TARGET, dest: b}
  - {src: TARGET, dest: c}
EOF
  sed -i.bak "s|TARGET|$T/target|g" "$T/srcs/acme/spaces/tech/space.yml" && rm "$T/srcs/acme/spaces/tech/space.yml.bak"
  wsm install acme/tech >/dev/null
  rm "$H/a" "$H/b" "$H/c"
  ln -s /etc "$H/b"
  echo mine > "$H/c"
  run links_json
  [ "${lines[0]}" = "a|$T/target|missing" ]
  [ "${lines[1]}" = "b|$T/target|wrong" ]
  [ "${lines[2]}" = "c|$T/target|in the way" ]
  run wsm ls acme/tech
  [[ "$output" == *$'\tpartial\t'*"1 missing, 1 wrong, 1 in the way"* ]]
  run wsm install acme/tech
  [ "$status" -eq 1 ]
  [[ "$output" == *"wrong: ~/spaces/acme/tech/b"* ]]
  points "$H/a" "$T/target"
  [ "$(readlink "$H/b")" = /etc ]
  run wsm install -f acme/tech
  [ "$status" -eq 0 ]
  points "$H/b" "$T/target"
  points "$H/c" "$T/target"
  [ "$(cat "$XDG_STATE_HOME/wsm/backup/acme/tech/c")" = mine ]
  [ "$(readlink "$XDG_STATE_HOME/wsm/backup/acme/tech/b")" = /etc ]
  run wsm ls acme/tech
  [[ "$output" == *$'\tok\t'* ]]
}

@test "remove takes a link that points at its src, leaves one the user repointed" {
  space_def acme tech <<EOF
links:
  - {src: $T/target, dest: keep/a}
  - {src: $T/target/sub, dest: b}
EOF
  wsm install acme/tech >/dev/null
  rm "$H/keep/a"
  ln -s /etc "$H/keep/a"
  run wsm remove -y acme/tech
  [ "$status" -eq 0 ]
  [ ! -L "$H/b" ]
  [ "$(readlink "$H/keep/a")" = /etc ]
  [ -d "$T/target/sub" ]
}

@test "an existing absolute link that is already right is ok and left as it is (not rewritten)" {
  mkdir -p "$H"
  ln -s "$T/target" "$H/target"
  space_def acme tech <<<"links: [{src: $T/target}]"
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  [[ "$output" != *"linked target"* ]]
  [ "$(links_json)" = "target|$T/target|ok" ]
  [ "$(readlink "$H/target")" = "$T/target" ]
  # and remove takes it
  wsm remove -y acme/tech >/dev/null
  [ ! -L "$H/target" ]
}

@test "ls --json: links is empty for a space without, and dry-run makes nothing" {
  space_def acme tech <<<"links: [{src: $T/target, dest: t}]"
  run wsm install -n acme/tech
  [[ "$output" == *"would link t -> $T/target"* ]]
  [ ! -e "$H" ]
  space_def acme other <<<'repositories: []'
  wsm install acme/other >/dev/null
  [ "$(wsm ls acme/other --json | yq -p json -r '.[0].links | length')" = 0 ]
}

@test "new: the template lists skills: and links: commented out" {
  wsm new acme/fresh >/dev/null
  run cat "$T/srcs/acme/spaces/fresh/space.yml"
  [[ "$output" == *"#skills:"* ]]
  [[ "$output" == *"#links:"* ]]
  [[ "$output" == *'$VAR expanded'* ]]
  [[ "$output" == *"#files:"* ]]
  [[ "$output" != *"absolute"* ]]
  [ "$(yq -r '.repositories | length' "$T/srcs/acme/spaces/fresh/space.yml")" = 0 ]
}

# --- linker 02: directory links, platforms, files: -------------------------------------------

@test "a directory link: one link, ok in ls; a file added in the source is there; the leftover walk does not enter it" {
  space_def acme tech <<<'links: [docs/]'
  space_file acme tech/docs/a.md a
  space_file acme tech/notes.md n
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  [ -L "$H/docs" ] && [[ "$(readlink "$H/docs")" != /* ]] && [ -L "$H/notes.md" ]
  space_file acme tech/docs/b.md b
  [ "$(cat "$H/docs/b.md")" = b ]
  # a dangling link inside the source's directory is the source's, not a leftover
  ln -s nowhere "$T/srcs/acme/spaces/tech/docs/dangling"
  run wsm ls acme/tech
  [[ "$output" == *$'\tok\t'* ]]
  [ "$(wsm ls acme/tech --json | yq -p json -r '.[0].files[] | select(.file == "docs") | .status')" = ok ]
  run wsm install acme/tech
  [ -L "$T/srcs/acme/spaces/tech/docs/dangling" ]
  wsm remove -y acme/tech >/dev/null
  [ ! -e "$H/docs" ] && [ -f "$T/srcs/acme/spaces/tech/docs/a.md" ]
}

@test "a directory link holding a child space, or a hidden directory with skills:, is invalid" {
  space_def acme tech <<<'links: [team/]'
  space_def acme tech/team/web <<<'repositories: []'
  run wsm ls acme/tech
  [[ "$output" == *$'\tinvalid\t'*"the directory link team/ holds the space acme/tech/team/web"* ]]
  run wsm install acme/tech
  [ "$status" -eq 1 ]
  space_def acme tech <<'EOF'
links: [.agents/]
skills: [{repo: owner/repo}]
EOF
  space_file acme tech/.agents/x x
  run wsm ls acme/tech
  [[ "$output" == *"where the skills CLI writes"* ]]
}

@test "a path entry with platforms: [linux] on macOS is not linked and not counted missing" {
  space_def acme tech <<<'links: [{path: linux.conf, platforms: [linux]}]'
  space_file acme tech/linux.conf l
  space_file acme tech/all.conf a
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  [ ! -e "$H/linux.conf" ] && [ -L "$H/all.conf" ]
  run wsm ls acme/tech
  [[ "$output" == *$'\tok\t'* ]]
}

@test "files: copied when missing, then left; differs is not partial, missing is; remove leaves it" {
  space_def acme tech <<<'files: [local.conf]'
  space_file acme tech/local.conf defaults
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  [ -f "$H/local.conf" ] && [ ! -L "$H/local.conf" ]
  echo mine > "$H/local.conf"
  wsm install acme/tech >/dev/null
  [ "$(cat "$H/local.conf")" = mine ]
  run wsm ls acme/tech
  [[ "$output" == *$'\tok\t'* ]]
  [ "$(wsm ls acme/tech --json | yq -p json -r '.[0].copies[0].status')" = differs ]
  rm "$H/local.conf"
  run wsm ls acme/tech
  [[ "$output" == *$'\tpartial\t'*"1 missing"* ]]
  wsm install acme/tech >/dev/null
  [ "$(cat "$H/local.conf")" = defaults ]
  wsm remove -y acme/tech >/dev/null
  [ "$(cat "$H/local.conf")" = defaults ] && [ ! -e "$H/space.yml" ]
}

@test "files: in the way fails the space before anything is linked; -f moves it aside" {
  space_def acme tech <<<'files: [local.conf]'
  space_file acme tech/local.conf defaults
  mkdir -p "$H/local.conf"
  run wsm install acme/tech
  [ "$status" -eq 1 ]
  [[ "$output" == *"in the way: ~/spaces/acme/tech/local.conf (a directory)"* ]]
  [ ! -e "$H/space.yml" ]
  run wsm install -f acme/tech
  [ "$status" -eq 0 ]
  [ "$(cat "$H/local.conf")" = defaults ]
  [ -d "$XDG_STATE_HOME/wsm/backup/acme/tech/local.conf" ]
}

@test "space.yml in files: is refused" {
  space_def acme tech <<<'files: [space.yml]'
  run wsm install acme/tech
  [ "$status" -eq 1 ]
  [[ "$output" == *"space.yml is how wsm knows the space is installed"* ]]
}

@test "wsm add makes a relative link through anfs_link_one" {
  space_def acme tech <<<'repositories: []'
  wsm install acme/tech >/dev/null
  echo mine > "$H/new.md"
  run wsm add "$H/new.md"
  [ "$status" -eq 0 ]
  [[ "$(readlink "$H/new.md")" == ../* ]]
  [ "$(cat "$T/srcs/acme/spaces/tech/new.md")" = mine ]
}
