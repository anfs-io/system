#!/usr/bin/env bats
# install: a space is a directory of a source's spaces/ with a space.yml, at any depth; its files
# (those whose nearest space it is) are linked into $WSM_SPACES_HOME/<source>/<path>/, dependencies
# first, then its repositories are cloned. Everything clones over file:// from bare repos in the
# test temp dir — no network.
# Run: bats packages/wsm/tests/install.bats

load helper
setup() {
  wsm_setup
  mksource acme >/dev/null
}

# --- spaces, by space.yml ------------------------------------------------------------------

@test "a space at any depth: the root space and a/b/c, not the directories between" {
  space_def acme <<<'repositories: []'
  space_def acme a/b/c <<<'repositories: []'
  space_file acme a/x.md
  space_file acme a/b/c/c.md
  run wsm ls
  [ "$status" -eq 0 ]
  [ "$(cut -f1 <<< "$output" | tr '\n' ' ')" = "acme acme/a/b/c " ]
  run wsm install acme
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme -> ~/spaces/acme"*"linked 2 of 2 file(s)"* ]]
  [ -L "$HOME/spaces/acme/a/x.md" ] && [ -L "$HOME/spaces/acme/space.yml" ]
  # a child space's files are its own
  [ ! -e "$HOME/spaces/acme/a/b/c" ]
  run wsm install acme/a/b/c
  [ "$status" -eq 0 ]
  [ -L "$HOME/spaces/acme/a/b/c/c.md" ] && [ -L "$HOME/spaces/acme/a/b/c/space.yml" ]
  # a link per file: the directories are real
  [ -d "$HOME/spaces/acme/a/b" ] && [ ! -L "$HOME/spaces/acme/a/b" ]
  [ "$(cat "$HOME/spaces/acme/a/b/c/c.md")" = a/b/c/c.md ]
}

@test "a file under no space is not linked, and is warned about once" {
  space_def acme a/b/c <<<'repositories: []'
  space_file acme a/x.md
  space_file acme a/y.md
  run wsm install acme/a/b/c
  [ "$status" -eq 0 ]
  [ "$(grep -c 'not in any space' <<< "$output")" -eq 1 ]
  [[ "$output" == *"not in any space, not linked: acme/a/x.md (and 1 more)"* ]]
  [ ! -e "$HOME/spaces/acme/a/x.md" ]
}

@test "a file belongs to the nearest space above it; a new space.yml takes the files below it" {
  space_def acme a/b/c <<<'repositories: []'
  space_file acme a/b/c/top.md
  space_file acme a/b/c/d/deep.md
  wsm install acme/a/b/c >/dev/null
  [ -L "$HOME/spaces/acme/a/b/c/d/deep.md" ]
  space_def acme a/b/c/d <<<'repositories: []'
  run wsm ls
  [[ "$output" == *$'acme/a/b/c\tpartial'*"1 leftover"* || "$output" == *$'acme/a/b/c\tok'* ]]
  run wsm install acme/a/b/c/d
  [ "$status" -eq 0 ]
  # its link was already right: only space.yml is new
  [[ "$output" == *"space acme/a/b/c/d"*"linked 1 of 2 file(s)"* ]]
  run wsm ls --json
  [ "$(yq -p json -r '.[] | select(.space == "acme/a/b/c") | .status' <<< "$output")" = ok ]
  [ "$(yq -p json -r '.[] | select(.space == "acme/a/b/c/d") | .status' <<< "$output")" = ok ]
}

@test "hidden directories are content, and a space.yml makes one a space" {
  space_def acme <<<'repositories: []'
  space_file acme .config/thing
  space_def acme .hidden/s <<<'repositories: []'
  run wsm install acme
  [ "$status" -eq 0 ]
  [ -L "$HOME/spaces/acme/.config/thing" ]
  run wsm ls
  [[ "$output" == *"acme/.hidden/s"* ]]
}

# --- specs ---------------------------------------------------------------------------------

@test "a prefix is every space at or under it; an id that space only, not the ones above it" {
  space_def acme <<<'repositories: []'
  space_def acme a/b/c <<<'repositories: []'
  space_def acme z <<<'repositories: []'
  run wsm install -y acme/a/
  [ "$status" -eq 0 ]
  [ "$(installed | tr '\n' ' ')" = "acme/a/b/c " ]
  [ ! -e "$HOME/spaces/acme/space.yml" ]
  run wsm install acme/z
  [ "$(installed | tr '\n' ' ')" = "acme/a/b/c acme/z " ]
  # a prefix is asked about: no terminal and no -y is 77, nothing linked; -n does not ask
  run wsm install acme/ </dev/null
  [ "$status" -eq 77 ]
  [ ! -e "$HOME/spaces/acme/space.yml" ]
  run wsm install -n acme/ </dev/null
  [ "$status" -eq 0 ]
  run wsm install -y acme/
  [ "$status" -eq 0 ]
  [ "$(ninstalled)" -eq 3 ]
}

@test "several specs in one run" {
  mksource other >/dev/null
  space_def acme tech <<<'repositories: []'
  space_def other ops <<<'repositories: []'
  run wsm install -y acme/ other/ops
  [ "$status" -eq 0 ]
  [ -L "$HOME/spaces/acme/tech/space.yml" ] && [ -L "$HOME/spaces/other/ops/space.yml" ]
}

@test "a bare path comes from the highest-priority source that has it" {
  mksource other >/dev/null
  space_def acme main/tech <<<'repositories: []'
  space_def other main/tech <<<'# other'
  space_def other main/ops <<<'repositories: []'
  run wsm install main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme/main/tech"* ]]
  [ "$(cat "$HOME/spaces/acme/main/tech/space.yml")" = "repositories: []" ]
  # a bare prefix: the first source with a space under it
  run wsm install -y main/
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/spaces/other" ]
}

@test "an alias that is also another source's top-level directory names the source" {
  mksource other >/dev/null
  space_def acme other/x <<<'repositories: []'
  space_def other x <<<'repositories: []'
  run wsm install other/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"space other/x"* ]]
  [ ! -e "$HOME/spaces/acme" ]
}

@test "a spec that names nothing fails before anything is created" {
  space_def acme a <<<'repositories: []'
  run wsm install acme/a nowhere
  [ "$status" -eq 1 ]
  [[ "$output" == *"no space matches 'nowhere'"* ]]
  [ ! -e "$HOME/spaces" ]
  # a source with no root space.yml: its alias alone is no space
  run wsm install acme
  [ "$status" -eq 1 ]
  [[ "$output" == *"acme/ is every space in it"* ]]
}

@test "a spec that reads as a directory is refused: there is no DIR" {
  space_def acme a <<<'repositories: []'
  run wsm install acme/a "$HOME/x"
  [ "$status" -eq 64 ]
  run wsm install .
  [ "$status" -eq 64 ]
  [[ "$output" == *"'.' is a directory, not a space"* ]]
  for bad in .. acme/./a acme//a /abs '~/x' 'acme/m*'; do
    run wsm install "$bad"
    [ "$status" -eq 64 ]
  done
  [ ! -e "$HOME/spaces" ]
}

# --- depends -------------------------------------------------------------------------------

@test "dependencies first: a path in the same source, an id of another" {
  mksource other >/dev/null
  space_def acme main/org <<<'repositories: []'
  space_def other net <<<'repositories: []'
  space_def acme main/tech <<<'depends: [main/org, other/net]'
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme/main/org"*"space other/net"*"space acme/main/tech"* ]]
  [ -L "$HOME/spaces/other/net/space.yml" ]
}

@test "a bare dependency is this source's, else a lower-priority one's; never a sibling by name" {
  mksource other >/dev/null
  # other is lower priority (listed after acme)
  space_def acme main/tech <<<'depends: [org]'
  space_def acme main/org <<<'repositories: []'
  space_def other org <<<'repositories: []'
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"space other/org"* && "$output" != *"acme/main/org"* ]]
  # the root space of another source by its alias
  space_def other <<<'repositories: []'
  space_def acme ops <<<'depends: [other]'
  run wsm install acme/ops
  [ "$status" -eq 0 ]
  [[ "$output" == *"space other -> ~/spaces/other"* ]]
}

@test "an unknown dependency or a cycle fails before anything is created" {
  space_def acme tech <<<'depends: [nope]'
  run wsm install acme/tech
  [ "$status" -ne 0 ]
  [[ "$output" == *"space 'nope' not found"* ]]
  space_def acme tech <<<'depends: [org]'
  space_def acme org <<<'depends: [acme/tech]'
  run wsm install acme/tech
  [ "$status" -ne 0 ]
  [[ "$output" == *"circular dependency"* ]]
  [ ! -e "$HOME/spaces" ]
}

# --- the root ------------------------------------------------------------------------------

@test "WSM_SPACES_HOME is the one root, ~ expanded" {
  space_def acme a <<<'repositories: []'
  WSM_SPACES_HOME='~/ws' run wsm install acme/a
  [ "$status" -eq 0 ]
  [ -L "$HOME/ws/acme/a/space.yml" ]
  WSM_SPACES_HOME='~/ws' run wsm ls
  [[ "$output" == *$'acme/a\tok\t~/ws/acme/a'* ]]
}

@test "a root inside a source checkout is refused" {
  space_def acme a <<<'repositories: []'
  WSM_SPACES_HOME="$BATS_TEST_TMPDIR/srcs/acme/inside" run wsm install acme/a
  [ "$status" -ne 0 ]
  [[ "$output" == *"is inside the source acme"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/srcs/acme/inside" ]
}

# --- linking -------------------------------------------------------------------------------

@test "links: relative, README and LICENSE kept, a re-run finds them linked" {
  space_def acme a <<<'repositories: []'
  space_file acme a/README.md
  space_file acme a/LICENSE.txt
  wsm install acme/a >/dev/null
  [[ "$(readlink "$HOME/spaces/acme/a/README.md")" == ../* ]]
  [ -L "$HOME/spaces/acme/a/LICENSE.txt" ]
  run wsm install acme/a
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked 0 of 3 file(s)"* ]]
}

@test "anything in the way fails the space before anything is linked, every file named" {
  space_def acme a <<<'repositories: []'
  space_file acme a/README.md
  space_file acme a/docs/n.md
  mkdir -p "$HOME/spaces/acme/a/docs"
  echo mine > "$HOME/spaces/acme/a/README.md"
  echo mine > "$HOME/spaces/acme/a/docs/n.md"
  run wsm install acme/a
  [ "$status" -ne 0 ]
  [[ "$output" == *"in the way: ~/spaces/acme/a/README.md"* ]]
  [[ "$output" == *"in the way: ~/spaces/acme/a/docs/n.md"* ]]
  [[ "$output" == *"wsm install -f acme/a moves them aside"* ]]
  [ ! -e "$HOME/spaces/acme/a/space.yml" ]
  [ "$(cat "$HOME/spaces/acme/a/README.md")" = mine ]
}

@test "-f moves a file, a directory and a foreign link aside and links; remove leaves the backups" {
  local bk="$XDG_STATE_HOME/wsm/backup/acme/a"
  space_def acme a <<<'repositories: []'
  space_file acme a/README.md
  space_file acme a/notes.md
  space_file acme a/link.md
  mkdir -p "$HOME/spaces/acme/a/notes.md"
  echo mine > "$HOME/spaces/acme/a/README.md"
  echo inside > "$HOME/spaces/acme/a/notes.md/x"
  ln -s /etc/hosts "$HOME/spaces/acme/a/link.md"
  run wsm install -f acme/a
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved aside ~/spaces/acme/a/README.md -> ~/.local/state/wsm/backup/acme/a/README.md"* ]] ||
    [[ "$output" == *"moved aside ~/spaces/acme/a/README.md"* ]]
  [ "$(cat "$bk/README.md")" = mine ]
  [ "$(cat "$bk/notes.md/x")" = inside ]
  [ "$(readlink "$bk/link.md")" = /etc/hosts ]
  [ -L "$HOME/spaces/acme/a/README.md" ] && [ -L "$HOME/spaces/acme/a/notes.md" ] && [ -L "$HOME/spaces/acme/a/link.md" ]
  # a second one goes beside the first
  rm "$HOME/spaces/acme/a/README.md" && echo again > "$HOME/spaces/acme/a/README.md"
  wsm install -f acme/a >/dev/null
  [ "$(cat "$bk/README.md.1")" = again ]
  run wsm remove -y acme/a
  [ "$status" -eq 0 ]
  [ "$(cat "$bk/README.md")" = mine ]
  [ ! -e "$HOME/spaces/acme/a/README.md" ]
}

@test "a link into the source at a renamed path is replaced; a file gone from the source is unlinked" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  space_def acme a <<<'repositories: []'
  space_file acme a/gone.md
  space_file acme a/other.md
  space_file acme a/keep.md
  wsm install acme/a >/dev/null
  # keep.md's link points at another file of the space, as after a rename in the source
  rm "$HOME/spaces/acme/a/keep.md"
  ln -s "../../../.local/share/anfs/sources/acme/spaces/a/other.md" "$HOME/spaces/acme/a/keep.md"
  rm "$src/a/gone.md"
  space_file acme a/NEW.md
  run wsm install acme/a
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked 2 of 4 file(s), unlinked 1 leftover(s)"* ]]
  [ -L "$HOME/spaces/acme/a/NEW.md" ]
  [ ! -e "$HOME/spaces/acme/a/gone.md" ] && [ ! -L "$HOME/spaces/acme/a/gone.md" ]
  [ "$(cat "$HOME/spaces/acme/a/keep.md")" = a/keep.md ]
}

@test "absolute links (wsm 0.3) are replaced on a re-run" {
  space_def acme a <<<'repositories: []'
  wsm install acme/a >/dev/null
  rm "$HOME/spaces/acme/a/space.yml"
  ln -s "$HOME/.local/share/anfs/sources/acme/spaces/a/space.yml" "$HOME/spaces/acme/a/space.yml"
  run wsm install acme/a
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked 1 of 1 file(s)"* ]]
  [[ "$(readlink "$HOME/spaces/acme/a/space.yml")" == ../* ]]
}

@test "--dry-run reports but links, clones, moves and removes nothing" {
  local a
  a=$(mkbare alpha)
  space_def acme a <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  run wsm install acme/a --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would link 1 of 1 file(s)"* ]]
  [[ "$output" == *"would clone repos/alpha"* ]]
  [ ! -e "$HOME/spaces" ]
  mkdir -p "$HOME/spaces/acme/a" && echo mine > "$HOME/spaces/acme/a/space.yml"
  run wsm install -n -f acme/a
  [ "$status" -eq 0 ]
  [[ "$output" == *"would move aside ~/spaces/acme/a/space.yml"* ]]
  [ "$(cat "$HOME/spaces/acme/a/space.yml")" = mine ]
  [ ! -e "$XDG_STATE_HOME/wsm" ]
}

@test "install with no SPEC installs the space at ., which must hold a space.yml" {
  space_def acme a <<<'repositories: []'
  space_def acme a/b <<<'repositories: []'
  cd "$BATS_TEST_TMPDIR/srcs/acme/spaces/a/b"
  run wsm install
  [ "$status" -eq 0 ]
  [[ "$output" == *"install acme/a/b"* ]]
  [ ! -e "$HOME/spaces/acme/a/space.yml" ]
  cd "$HOME/spaces/acme/a"
  run wsm install
  [ "$status" -eq 64 ]
  cd "$HOME/spaces/acme/a/b"
  run wsm install
  [ "$status" -eq 0 ]
  [[ "$output" == *"install acme/a/b"* ]]
}

# --- repositories --------------------------------------------------------------------------

@test "every installed space clones its own repositories, into the root, never the source" {
  local a b
  a=$(mkbare alpha) b=$(mkbare beta)
  printf 'repositories:\n  - url: %s\n    path: org-repo\n' "$a" | space_def acme
  printf 'repositories:\n  - url: %s\n    path: repos/beta\n' "$b" | space_def acme a/b
  run wsm install acme/a/b
  [ "$status" -eq 0 ]
  [ -f "$HOME/spaces/acme/a/b/repos/beta/README" ]
  [ ! -e "$HOME/spaces/acme/org-repo" ]
  [ ! -e "$BATS_TEST_TMPDIR/srcs/acme/spaces/a/b/repos" ]
  run wsm install acme
  [ "$status" -eq 0 ]
  [ -d "$HOME/spaces/acme/org-repo/.git" ]
}

@test "a repository inside a child space, or holding one, is invalid" {
  local a
  a=$(mkbare alpha)
  space_def acme <<YML
repositories:
  - url: $a
    path: a/b/inside
  - url: $a
    path: a
YML
  space_def acme a/b <<<'repositories: []'
  run wsm install acme
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid repository acme/a/b/inside: inside the space acme/a/b"* ]]
  [[ "$output" == *"invalid repository acme/a: holds the space acme/a/b"* ]]
  [ ! -e "$HOME/spaces/acme/a" ]
  run wsm repo ls --json
  [ "$(yq -p json -r '[.[] | .status] | join(" ")' <<< "$output")" = "invalid invalid" ]
}

@test "a ref is checked out after the clone" {
  local a
  a=$(mkbare alpha other)
  space_def acme a <<YML
repositories:
  - url: $a
    path: repos/alpha
    ref: other
YML
  run wsm install acme/a
  [ "$status" -eq 0 ]
  [ -f "$HOME/spaces/acme/a/repos/alpha/BRANCH" ]
}

@test "re-running keeps clones and never pulls" {
  local a
  a=$(mkbare alpha)
  space_def acme a <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  wsm install acme/a >/dev/null
  echo "local work" > "$HOME/spaces/acme/a/repos/alpha/SCRATCH"
  run wsm install acme/a
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 cloned, 1 present"* ]]
  [ -f "$HOME/spaces/acme/a/repos/alpha/SCRATCH" ]
}

@test "a repository path that escapes its space is refused, and a failed clone leaves nothing" {
  space_def acme a <<'YML'
repositories:
  - url: file:///nowhere.git
    path: ../escaped
  - url: file:///definitely/not/a/repo.git
    path: repos/nope
YML
  run wsm install acme/a
  [ "$status" -ne 0 ]
  [[ "$output" == *"a path inside the space is needed"* ]]
  [[ "$output" == *"clone failed"* ]]
  [ ! -e "$HOME/spaces/acme/escaped" ]
  [ ! -e "$HOME/spaces/acme/a/repos/nope" ]
}

@test "a repository with no path clones where git clone would; two in one place fail the second" {
  local a b
  a=$(mkbare alpha) b=$(mkbare beta)
  space_def acme a <<YML
repositories:
  - url: $a
  - url: $b/
YML
  run wsm install acme/a
  [ "$status" -eq 0 ]
  [ -d "$HOME/spaces/acme/a/alpha/.git" ] && [ -d "$HOME/spaces/acme/a/beta/.git" ]
  run wsm repo ls acme/a
  [[ "$output" == *"acme/a/alpha"$'\t'clean* ]]

  mkdir -p "$BATS_TEST_TMPDIR/other"
  git clone -q --bare "$a" "$BATS_TEST_TMPDIR/other/alpha.git"
  space_def acme a <<YML
repositories:
  - url: $a
  - url: $BATS_TEST_TMPDIR/other/alpha.git
YML
  run wsm install acme/a
  [ "$status" -ne 0 ]
  [[ "$output" == *"two repositories in alpha"* ]]
}

# --- speed ---------------------------------------------------------------------------------

@test "a clone of 5000 files inside a space is never walked by ls or install" {
  local bin="$BATS_TEST_TMPDIR/bin" i
  space_def acme a <<<'repositories: []'
  space_file acme a/x.md
  wsm install acme/a >/dev/null
  mkdir -p "$HOME/spaces/acme/a/big/.git" "$HOME/spaces/acme/a/big/d"
  for i in $(seq 1 5000); do : > "$HOME/spaces/acme/a/big/d/f$i"; done
  mkdir -p "$bin"
  printf '#!/bin/sh\necho "$*" >> "%s/finds"\nexec %s "$@"\n' "$BATS_TEST_TMPDIR" "$(command -v find)" > "$bin/find"
  chmod +x "$bin/find"
  PATH="$bin:$PATH" run wsm ls
  [ "$status" -eq 0 ]
  [[ "$output" == *$'acme/a\tok'* ]]
  PATH="$bin:$PATH" run wsm install acme/a
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/finds"
  [ -n "$output" ]
  [[ "$output" != *"$HOME/spaces"* ]]
}
