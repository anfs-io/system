#!/usr/bin/env bats
# links: in space.yml: absolute links in a space's directory, dest -> src. States ok, missing,
# missing src, wrong, in the way (and invalid); -f moves what is in the way aside; remove takes a
# link only while it still points at its src.
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

@test "src with ~ and \$VAR expanded; dest defaults to src's basename; an absolute link" {
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
  [ "$(readlink "$H/data")" = "$HOME/data" ]
  [ "$(readlink "$H/here/sub")" = "$T/target/sub" ]
  [ "$(readlink "$H/t")" = "$T/target" ]
  run wsm ls acme/tech
  [[ "$output" == *$'\tok\t'* ]]
}

@test "an unset variable, a dest with .. or a leading / are invalid and fail the space" {
  unset WSM_T_NOPE
  space_def acme tech <<'EOF'
links:
  - src: $WSM_T_NOPE/x
  - {src: /tmp, dest: ../out}
  - {src: /tmp, dest: /abs}
EOF
  run wsm install acme/tech
  [ "$status" -eq 1 ]
  [[ "$output" == *'invalid link in acme/tech: $WSM_T_NOPE is not set'* ]]
  [[ "$output" == *"dest must stay inside the space: '../out'"* ]]
  [[ "$output" == *"dest must stay inside the space: '/abs'"* ]]
  [ ! -e "$T/out" ] && [ ! -e /abs ]
}

@test "a relative src is from the space's directory, written absolute" {
  space_def acme tech <<'EOF'
links:
  - {src: ../../../../target, dest: up}
EOF
  # $HOME/spaces/acme/tech/../../../../target is $T/target
  wsm install acme/tech >/dev/null
  # HOME is canonical (helper), so the path written is too
  [ "$(readlink "$H/up")" = "$(cd -P "$T" && pwd)/target" ]
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
  [ "$(readlink "$H/a")" = "$T/target" ]
  [ "$(readlink "$H/b")" = /etc ]
  run wsm install -f acme/tech
  [ "$status" -eq 0 ]
  [ "$(readlink "$H/b")" = "$T/target" ]
  [ "$(readlink "$H/c")" = "$T/target" ]
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

@test "an existing link that is already right is left as it is (ok, untouched)" {
  mkdir -p "$H"
  ln -s "$T/target" "$H/target"
  space_def acme tech <<<"links: [{src: $T/target}]"
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  [[ "$output" != *"linked target"* ]]
  [ "$(links_json)" = "target|$T/target|ok" ]
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
  [ "$(yq -r '.repositories | length' "$T/srcs/acme/spaces/fresh/space.yml")" = 0 ]
}
