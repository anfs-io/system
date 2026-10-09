#!/usr/bin/env bats
# install: linking spaces/<ws>/<space>/ from anfs sources into <target>/<ws>/<space>/,
# dependencies first, then cloning the repositories each space.yml declares. Everything clones over
# file:// from bare repos in the test temp dir — no network.
# Run: bats packages/wsm/tests/install.bats

load helper
setup() {
  wsm_setup
  mksource acme >/dev/null
}

@test "a space's files are linked one by one into ~/spaces/acme/<ws>/<space>" {
  space_def acme main/tech <<'YML'
repositories: []
YML
  space_file acme main/tech/README.md
  space_file acme main/tech/docs/notes.md
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme/main/tech -> ~/spaces/acme/main/tech"* ]]
  [[ "$output" == *"linked 3 of 3 file(s)"* ]]
  # stow's default ignore list would have dropped README.md
  [ -L "$HOME/spaces/acme/main/tech/README.md" ]
  [ -L "$HOME/spaces/acme/main/tech/space.yml" ]
  # A link per file: the directories are real, never a link folded into the source
  [ -d "$HOME/spaces/acme/main/tech" ] && [ ! -L "$HOME/spaces/acme/main/tech" ]
  [ -d "$HOME/spaces/acme/main/tech/docs" ] && [ ! -L "$HOME/spaces/acme/main/tech/docs" ]
  [ "$(cat "$HOME/spaces/acme/main/tech/docs/notes.md")" = main/tech/docs/notes.md ]
  [ "$(installed)" -eq 1 ]
}

@test "a clone lands in the target, never in the source" {
  local a
  a=$(mkbare alpha)
  space_def acme main/tech <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [ -f "$HOME/spaces/acme/main/tech/repos/alpha/README" ]
  [ ! -e "$BATS_TEST_TMPDIR/srcs/acme/spaces/main/tech/repos" ]
}

@test "source/ws installs every space of the workspace, and source/ every workspace" {
  space_def acme main/tech <<<'repositories: []'
  space_def acme main/finance <<<'repositories: []'
  space_def acme spikes/rails <<<'repositories: []'
  run wsm install acme/main
  [ "$status" -eq 0 ]
  [ "$(installed)" -eq 2 ]
  [ ! -e "$HOME/spaces/acme/spikes" ]
  run wsm install acme/
  [ "$status" -eq 0 ]
  [ "$(installed)" -eq 3 ]
  [ -L "$HOME/spaces/acme/spikes/rails/space.yml" ]
}

@test "a bare workspace or ws/space comes from the highest-priority source" {
  mksource other >/dev/null
  space_def acme main/tech <<<'repositories: []'
  space_def other main/tech <<<'# other'
  space_def other main/ops <<<'repositories: []'
  run wsm install main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme/main/tech"* ]]
  [ "$(cat "$HOME/spaces/acme/main/tech/space.yml")" = "repositories: []" ]
  # bare ws: acme has main, so only acme's spaces
  run wsm install main
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/spaces/other" ]
}

@test "DIR puts the source there, and . is the current directory" {
  space_def acme main/tech <<<'repositories: []'
  mksource other >/dev/null
  space_def other spikes/x <<<'repositories: []'
  run wsm install acme/main "$HOME/work"
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme/main/tech -> ~/work/acme/main/tech"* ]]
  [ -L "$HOME/work/acme/main/tech/space.yml" ]
  mkdir -p "$HOME/elsewhere" && cd "$HOME/elsewhere"
  run wsm install other/spikes .
  [ "$status" -eq 0 ]
  [ -L "$HOME/elsewhere/other/spikes/x/space.yml" ]
}

@test "WSM_SPACES_HOME is the default target, ~ expanded" {
  space_def acme main/tech <<<'repositories: []'
  WSM_SPACES_HOME='~/ws' run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [ -L "$HOME/ws/acme/main/tech/space.yml" ]
}

@test "one spec only, and a spec that reads as a path is refused" {
  space_def acme main/tech <<<'repositories: []'
  run wsm install acme/main/tech acme/main/tech "$HOME/x"
  [ "$status" -eq 64 ]
  run wsm install .
  [ "$status" -eq 64 ]
  [[ "$output" == *"'.' is a directory, not a space"* ]]
  for bad in .. acme/./tech acme//tech /abs '~/x' 'acme/m*' a/b/c/d; do
    run wsm install "$bad"
    [ "$status" -eq 64 ]
  done
  [ ! -e "$HOME/spaces" ]
}

@test "a source lives in one target: later installs go there, another DIR is refused" {
  space_def acme main/tech <<<'repositories: []'
  space_def acme main/finance <<<'repositories: []'
  space_def acme spikes/x <<<'repositories: []'
  wsm install acme/main/tech "$HOME/work" >/dev/null
  run wsm install acme/spikes
  [ "$status" -eq 0 ]
  [ -L "$HOME/work/acme/spikes/x/space.yml" ]
  run wsm install acme/main/finance "$HOME/other"
  [ "$status" -ne 0 ]
  [[ "$output" == *"acme is installed in ~/work"* ]]
  [ ! -e "$HOME/other" ]
}

@test "the same ws/space from two sources live side by side" {
  mksource other >/dev/null
  space_def acme main/tech <<<'repositories: []'
  space_def other main/tech <<<'repositories: []'
  wsm install acme/main/tech >/dev/null
  run wsm install other/main/tech
  [ "$status" -eq 0 ]
  [ -L "$HOME/spaces/acme/main/tech/space.yml" ]
  [ -L "$HOME/spaces/other/main/tech/space.yml" ]
}

@test "a target inside a source checkout, or inside another installed source, is refused" {
  mksource other >/dev/null
  space_def acme main/tech <<<'repositories: []'
  space_def other main/tech <<<'repositories: []'
  cd "$BATS_TEST_TMPDIR/srcs/acme"
  run wsm install acme/main/tech .
  [ "$status" -ne 0 ]
  [[ "$output" == *"is inside the source acme"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/srcs/acme/acme" ]
  cd "$HOME"
  wsm install acme/main/tech >/dev/null
  run wsm install other/main/tech "$HOME/spaces/acme/main"
  [ "$status" -ne 0 ]
  [[ "$output" == *"where acme is installed"* ]]
}

@test "files beside the workspaces and beside a workspace's spaces (hidden dirs too) are stowed with its first space" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  space_def acme main/tech <<<'repositories: []'
  space_def acme main/finance <<<'repositories: []'
  space_def acme spikes/x <<<'repositories: []'
  echo org > "$src/mise.toml"
  mkdir -p "$src/.config" "$src/main/.vscode"
  echo cfg > "$src/.config/thing"
  echo vault > "$src/main/opm.yml"
  echo notes > "$src/main/.vscode/settings.json"
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"source acme -> ~/spaces/acme"*"linked 2 of 2"*"workspace acme/main -> ~/spaces/acme/main"*"linked 2 of 2"*"space acme/main/tech"* ]]
  [ -L "$HOME/spaces/acme/mise.toml" ]
  [ -L "$HOME/spaces/acme/.config/thing" ]
  [ -L "$HOME/spaces/acme/main/opm.yml" ]
  [ -L "$HOME/spaces/acme/main/.vscode/settings.json" ]
  # a workspace's files are not a space's, nor the source's
  [ ! -e "$HOME/spaces/acme/main/tech/opm.yml" ]
  [ ! -e "$HOME/spaces/acme/spikes" ]
  [ ! -e "$HOME/spaces/acme/main/finance" ]

  wsm install acme/spikes/x >/dev/null
  # the levels go with their last space
  wsm remove acme/main/tech >/dev/null
  [ ! -e "$HOME/spaces/acme/main" ]
  [ -L "$HOME/spaces/acme/mise.toml" ]
  wsm remove acme/spikes >/dev/null
  [ ! -e "$HOME/spaces/acme" ]
  [ -z "$(find "$TRACKERS" -name '*.yml' 2>/dev/null)" ]
}

@test "a file in the way fails the space before anything is linked" {
  space_def acme main/tech <<<'repositories: []'
  space_file acme main/tech/README.md
  mkdir -p "$HOME/spaces/acme/main/tech"
  echo mine > "$HOME/spaces/acme/main/tech/README.md"
  run wsm install acme/main/tech
  [ "$status" -ne 0 ]
  [[ "$output" == *"in the way: ~/spaces/acme/main/tech/README.md"* ]]
  [ ! -e "$HOME/spaces/acme/main/tech/space.yml" ]
  [ "$(cat "$HOME/spaces/acme/main/tech/README.md")" = mine ]
  [ "$(installed)" -eq 0 ]
}

@test "re-running links new files, unlinks files gone from the source, and keeps clones" {
  local a src="$BATS_TEST_TMPDIR/srcs/acme/spaces/main/tech"
  a=$(mkbare alpha)
  space_def acme main/tech <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  space_file acme main/tech/old/OLD.md
  wsm install acme/main/tech >/dev/null
  echo "local work" > "$HOME/spaces/acme/main/tech/repos/alpha/SCRATCH"
  rm -r "$src/old"
  space_file acme main/tech/NEW.md

  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked 1 of 2 file(s), unlinked 1 gone from the source"* ]]
  [[ "$output" == *"0 cloned, 1 present"* ]]
  [ -L "$HOME/spaces/acme/main/tech/NEW.md" ]
  [ ! -e "$HOME/spaces/acme/main/tech/old" ]
  [ -f "$HOME/spaces/acme/main/tech/repos/alpha/SCRATCH" ]
}

@test "dependencies are installed first: a bare name is a sibling, ws/space another workspace" {
  space_def acme main/org <<<'repositories: []'
  space_def acme infra/net <<<'repositories: []'
  space_def acme main/tech <<'YML'
depends: [org, infra/net]
YML
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme/main/org"*"space acme/infra/net"*"space acme/main/tech"* ]]
  [ -L "$HOME/spaces/acme/infra/net/space.yml" ]
}

@test "a dependency resolves to the same or a lower-priority source, one space only" {
  mksource other >/dev/null
  # other is lower priority (listed after acme)
  space_def acme main/tech <<<'depends: [org]'
  space_def other main/org <<<'repositories: []'
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"space other/main/org"* ]]
}

@test "an unknown space or dependency fails before anything is created" {
  space_def acme main/tech <<<'depends: [nope]'
  run wsm install acme/main/tech
  [ "$status" -ne 0 ]
  [[ "$output" == *"space 'main/nope' not found"* ]]
  [ ! -e "$HOME/spaces" ]
  run wsm install nowhere
  [ "$status" -ne 0 ]
  [[ "$output" == *"no workspace or source named 'nowhere'"* ]]
}

@test "a ref is checked out after the clone" {
  local a
  a=$(mkbare alpha other)
  space_def acme main/tech <<YML
repositories:
  - url: $a
    path: repos/alpha
    ref: other
YML
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [ -f "$HOME/spaces/acme/main/tech/repos/alpha/BRANCH" ]
}

@test "every directory at the workspace and space depths is one, space.yml or not" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  mkdir -p "$src/main/plain" "$src/bare/notes"
  echo hi > "$src/main/plain/hello.md"
  echo n > "$src/bare/notes/n.md"
  run wsm install acme/main
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme/main/plain"* ]]
  [ -L "$HOME/spaces/acme/main/plain/hello.md" ]
  run wsm install acme/bare/notes
  [ "$status" -eq 0 ]
  [ -L "$HOME/spaces/acme/bare/notes/n.md" ]
}

@test "the source and workspace levels' space.yml clone into their directories when the spec names them" {
  local a b src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  a=$(mkbare alpha) b=$(mkbare beta)
  space_def acme main/tech <<<'repositories: []'
  printf 'repositories:\n  - url: %s\n    path: org-repo\n' "$a" > "$src/space.yml"
  printf 'repositories:\n  - url: %s\n    path: ws-repo\n' "$b" > "$src/main/space.yml"
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [ -L "$HOME/spaces/acme/space.yml" ] && [ -L "$HOME/spaces/acme/main/space.yml" ]
  [ ! -e "$HOME/spaces/acme/org-repo" ] && [ ! -e "$HOME/spaces/acme/main/ws-repo" ]
  run wsm install acme/main
  [ "$status" -eq 0 ]
  [ -d "$HOME/spaces/acme/main/ws-repo/.git" ] && [ ! -e "$HOME/spaces/acme/org-repo" ]
  run wsm install acme/
  [ "$status" -eq 0 ]
  [ -d "$HOME/spaces/acme/org-repo/.git" ]
  [[ "$output" == *"present ws-repo"* ]]
}

@test "install with no SPEC installs the level at ., which must hold a space.yml" {
  space_def acme main/tech <<<'repositories: []'
  space_def acme main/finance <<<'repositories: []'
  cd "$BATS_TEST_TMPDIR/srcs/acme/spaces/main/tech"
  run wsm install
  [ "$status" -eq 0 ]
  [[ "$output" == *"install acme/main/tech"* ]]
  [ ! -e "$HOME/spaces/acme/main/finance" ]
  cd "$HOME/spaces/acme/main"
  run wsm install
  [ "$status" -eq 64 ]
  echo 'repositories: []' > "$BATS_TEST_TMPDIR/srcs/acme/spaces/main/space.yml"
  wsm install acme/main/tech >/dev/null
  run wsm install
  [ "$status" -eq 0 ]
  [[ "$output" == *"install acme/main"* ]]
  [ -L "$HOME/spaces/acme/main/finance/space.yml" ]
}

@test "stow links: relative, README kept, and a re-run finds them stowed" {
  space_def acme main/tech <<<'repositories: []'
  space_file acme main/tech/README.md
  space_file acme main/tech/LICENSE.txt
  wsm install acme/main/tech >/dev/null
  [[ "$(readlink "$HOME/spaces/acme/main/tech/README.md")" == ../* ]]
  [ -L "$HOME/spaces/acme/main/tech/LICENSE.txt" ]
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked 0 of 3 file(s)"* ]]
  # the user's HOME is not where stow found its ignore list
  [ ! -e "$HOME/.stow-global-ignore" ]
}

@test "a repository path that escapes its level is refused, and a failed clone leaves nothing" {
  space_def acme main/tech <<'YML'
repositories:
  - url: file:///nowhere.git
    path: ../escaped
  - url: file:///definitely/not/a/repo.git
    path: repos/nope
YML
  run wsm install acme/main/tech
  [ "$status" -ne 0 ]
  [[ "$output" == *"inside its level"* ]]
  [[ "$output" == *"clone failed"* ]]
  [ ! -e "$HOME/spaces/acme/main/escaped" ]
  [ ! -e "$HOME/spaces/acme/main/tech/repos/nope" ]
}

@test "--dry-run reports but links, clones and records nothing" {
  local a
  a=$(mkbare alpha)
  space_def acme main/tech <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  run wsm install acme/main/tech --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would link 1 of 1 file(s)"* ]]
  [[ "$output" == *"would clone repos/alpha"* ]]
  [ ! -e "$HOME/spaces" ]
  [ "$(installed)" -eq 0 ]
}

@test "absolute links from wsm 0.3 are replaced by stow's on a re-run" {
  space_def acme main/tech <<<'repositories: []'
  wsm install acme/main/tech >/dev/null
  rm "$HOME/spaces/acme/main/tech/space.yml"
  ln -s "$HOME/.local/share/anfs/sources/acme/spaces/main/tech/space.yml" "$HOME/spaces/acme/main/tech/space.yml"
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"linked 1 of 1 file(s)"* ]]
  [[ "$(readlink "$HOME/spaces/acme/main/tech/space.yml")" == ../* ]]
}

@test "a source or workspace with no spaces installs by name, with its repositories; a bare source name is source/" {
  local a b src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  a=$(mkbare alpha) b=$(mkbare beta)
  printf 'repositories:\n  - url: %s\n    path: technical/infra\n' "$a" > "$src/space.yml"
  run wsm install acme
  [ "$status" -eq 0 ]
  [ -L "$HOME/spaces/acme/space.yml" ]
  [ -d "$HOME/spaces/acme/technical/infra/.git" ]
  [ "$(yq -r '.named' "$TRACKERS/acme.yml")" = true ]
  [ "$(installed)" -eq 0 ]

  mkdir -p "$src/ops"
  printf 'repositories:\n  - url: %s\n    path: tools\n' "$b" > "$src/ops/space.yml"
  run wsm install acme/ops
  [ "$status" -eq 0 ]
  [ -L "$HOME/spaces/acme/ops/space.yml" ]
  [ -d "$HOME/spaces/acme/ops/tools/.git" ]
  [ "$(yq -r '.named' "$TRACKERS/acme/ops.yml")" = true ]
}

@test "a repository with no path clones where git clone would; two in one place fail the second" {
  local a b
  a=$(mkbare alpha) b=$(mkbare beta)
  space_def acme main/tech <<YML
repositories:
  - url: $a
  - url: $b/
YML
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [ -d "$HOME/spaces/acme/main/tech/alpha/.git" ] && [ -d "$HOME/spaces/acme/main/tech/beta/.git" ]
  run wsm ls -r acme/main/tech
  [[ "$output" == *"acme/main/tech/alpha"*clean* ]]

  mkdir -p "$BATS_TEST_TMPDIR/other"
  git clone -q --bare "$a" "$BATS_TEST_TMPDIR/other/alpha.git"
  space_def acme main/tech <<YML
repositories:
  - url: $a
  - url: $BATS_TEST_TMPDIR/other/alpha.git
YML
  run wsm install acme/main/tech
  [ "$status" -ne 0 ]
  [[ "$output" == *"two repositories in alpha"* ]]
}
