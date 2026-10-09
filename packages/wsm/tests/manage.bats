#!/usr/bin/env bats
# What comes after install: ls, path (what `wsm cd` is built on), remove, new, add, status, implode.
# Run: bats packages/wsm/tests/manage.bats

load helper
setup() {
  wsm_setup
  mksource acme >/dev/null
  space_def acme main/tech <<<'repositories: []'
  space_def acme main/finance <<<'repositories: []'
  space_def acme spikes/tech <<<'repositories: []'
}

@test "ls lists every source, workspace and space, with where each is installed" {
  run wsm ls
  [ "$status" -eq 0 ]
  [[ "$output" == *$'acme/\t-'* ]]
  [[ "$output" == *$'acme/main\t-'* ]]
  [[ "$output" == *$'acme/main/finance\t-'* ]]
  [[ "$output" == *$'acme/spikes/tech\t-'* ]]
  wsm install acme/main >/dev/null
  run wsm ls
  [[ "$output" == *$'acme/\t~/spaces/acme'* ]]
  [[ "$output" == *$'acme/main/tech\t~/spaces/acme/main/tech'* ]]
  [[ "$output" == *$'acme/spikes/tech\t-'* ]]
  rm -r "$HOME/spaces/acme/main/finance"
  run wsm ls
  [[ "$output" == *"~/spaces/acme/main/finance (stale)"* ]]
}

@test "ls SPEC narrows to that subtree" {
  run wsm ls acme/main
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme/main/tech"* && "$output" != *"spikes"* && "$output" != *$'acme/\t'* ]]
  run wsm ls acme/spikes/tech
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  run wsm ls acme
  [[ "$output" == *$'acme/\t'* && "$output" == *"spikes"* ]]
  run wsm ls acme/nope
  [ "$status" -eq 1 ]
}

@test "ls -r lists the repositories space.yml files declare, with their state" {
  local a b
  a=$(mkbare alpha) b=$(mkbare beta)
  space_def acme main/tech <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  space_def acme spikes/tech <<YML
repositories:
  - url: $b
    path: beta
YML
  wsm install acme/main/tech >/dev/null
  run wsm ls -r
  [ "$status" -eq 0 ]
  [[ "$output" == *$'acme/main/tech/repos/alpha\t'"$a"$'\tclean'* ]]
  [[ "$output" == *$'acme/spikes/tech/beta\t'"$b"$'\tnot installed'* ]]
  echo x > "$HOME/spaces/acme/main/tech/repos/alpha/new"
  run wsm ls --repositories acme/main
  [[ "$output" == *"dirty"* && "$output" != *"beta"* ]]
  rm -rf "$HOME/spaces/acme/main/tech/repos/alpha"
  run wsm ls -r acme/main/tech
  [[ "$output" == *"missing"* ]]
}

@test "path resolves space, ws/space and source/ws/space, then a workspace" {
  wsm install acme/ >/dev/null
  run wsm path finance
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/spaces/acme/main/finance" ]
  run wsm path spikes/tech
  [ "$output" = "$HOME/spaces/acme/spikes/tech" ]
  run wsm path acme/main/tech
  [ "$output" = "$HOME/spaces/acme/main/tech" ]
  run wsm path main
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/spaces/acme/main" ]
}

@test "an ambiguous query lists the candidates and exits 2; no match exits 1" {
  wsm install acme/ >/dev/null
  run wsm path tech
  [ "$status" -eq 2 ]
  [[ "$output" == *"acme/main/tech"* && "$output" == *"acme/spikes/tech"* ]]
  run wsm path nope
  [ "$status" -eq 1 ]
}

@test "path with no query is the installed space containing ." {
  wsm install acme/main >/dev/null
  mkdir -p "$HOME/spaces/acme/main/tech/deep/er"
  cd "$HOME/spaces/acme/main/tech/deep/er"
  run wsm path
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/spaces/acme/main/tech" ]
  cd "$HOME"
  run wsm path
  [ "$status" -eq 1 ]
}

@test "a space whose directory is gone still prints, and exits 3" {
  wsm install acme/main/tech >/dev/null
  rm -r "$HOME/spaces/acme/main/tech"
  run wsm path tech
  [ "$status" -eq 3 ]
  [[ "$output" == *"$HOME/spaces/acme/main/tech"* ]]
}

@test "remove unlinks and forgets, keeping clones and the user's files" {
  local a
  a=$(mkbare alpha)
  space_def acme main/tech <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  space_file acme main/tech/docs/notes.md
  wsm install acme/main >/dev/null
  echo mine > "$HOME/spaces/acme/main/tech/TODO"

  run wsm remove acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed acme/main/tech"* ]]
  [ ! -e "$HOME/spaces/acme/main/tech/space.yml" ]
  [ ! -e "$HOME/spaces/acme/main/tech/docs" ]
  [ -f "$HOME/spaces/acme/main/tech/repos/alpha/README" ]
  [ -f "$HOME/spaces/acme/main/tech/TODO" ]
  [ "$(installed)" -eq 1 ]
}

@test "remove of a whole workspace leaves no empty directories behind" {
  wsm install acme/main >/dev/null
  run wsm remove acme/main
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/spaces/acme/main" ]
  [ "$(installed)" -eq 0 ]
  run wsm remove acme/main
  [ "$status" -eq 1 ]
}

@test "remove leaves a link the user replaced" {
  wsm install acme/main/tech >/dev/null
  rm "$HOME/spaces/acme/main/tech/space.yml"
  echo mine > "$HOME/spaces/acme/main/tech/space.yml"
  wsm remove acme/main/tech >/dev/null
  [ "$(cat "$HOME/spaces/acme/main/tech/space.yml")" = mine ]
}

@test "path takes source/ and a bare source for the source's directory" {
  wsm install acme/main >/dev/null
  run wsm path acme/
  [ "$output" = "$HOME/spaces/acme" ]
  run wsm path acme
  [ "$output" = "$HOME/spaces/acme" ]
  cd "$HOME/spaces/acme/main"
  run wsm path
  [ "$output" = "$HOME/spaces/acme/main" ]
}

@test "path -s gives the directory in the source instead" {
  local src="$HOME/.local/share/anfs/sources/acme/spaces"
  wsm install acme/main >/dev/null
  run wsm path -s finance
  [ "$status" -eq 0 ]
  [ "$output" = "$src/main/finance" ]
  run wsm path --source acme/main
  [ "$output" = "$src/main" ]
  # a source-qualified name needs nothing installed
  run wsm path -s acme/spikes/tech
  [ "$output" = "$src/spikes/tech" ]
  run wsm path -s acme
  [ "$output" = "$src" ]
  cd "$HOME/spaces/acme/main/tech"
  run wsm path -s
  [ "$output" = "$src/main/tech" ]
  run wsm path -s acme/nope
  [ "$status" -eq 1 ]
}

@test "new SOURCE/WS/SPACE works anywhere, and refuses one that exists" {
  run wsm new acme/main/marketing
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/srcs/acme/spaces/main/marketing/space.yml" ]
  [[ "$output" == *"next: wsm install acme/main/marketing"* ]]
  [ "$(installed)" -eq 0 ]
  run wsm install acme/main/marketing
  [ "$status" -eq 0 ]
  run wsm new acme/main/marketing
  [ "$status" -eq 73 ]
  run wsm new nope/main/x
  [ "$status" -eq 1 ]
  run wsm new acme/main/tech/x
  [ "$status" -eq 64 ]
  run wsm new ./x
  [ "$status" -eq 64 ]
}

@test "new WS/SPACE and SPACE take the source and workspace from a source checkout" {
  local src="$BATS_TEST_TMPDIR/srcs/acme"
  mkdir -p "$src/docs"
  cd "$src/docs"
  run wsm new ops/db
  [ "$status" -eq 0 ]
  [ -f "$src/spaces/ops/db/space.yml" ]
  # SPACE needs a workspace: the first directory below spaces/
  run wsm new y
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a workspace of acme"* ]]
  cd "$src/spaces/main/tech"
  run wsm new web
  [ "$status" -eq 0 ]
  [ -f "$src/spaces/main/web/space.yml" ]
  # spaces/ is created in a source that has none yet
  local fresh
  fresh=$(mksource fresh)
  rmdir "$fresh/spaces"
  cd "$fresh"
  run wsm new main/first
  [ "$status" -eq 0 ]
  [ -f "$fresh/spaces/main/first/space.yml" ]
}

@test "new from an installed tree creates in the source and installs into the workspace" {
  wsm install acme/main/tech >/dev/null
  cd "$HOME/spaces/acme/main/tech"
  run wsm new web
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/srcs/acme/spaces/main/web/space.yml" ]
  [ -L "$HOME/spaces/acme/main/web/space.yml" ]
  [[ "$output" == *"commit it in"* ]]
  # a workspace that is not installed is only created
  cd "$HOME/spaces/acme"
  run wsm new ops/db
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/srcs/acme/spaces/ops/db/space.yml" ]
  [ ! -e "$HOME/spaces/acme/ops" ]
  # outside any source or installed tree, the source must be named
  cd "$HOME/spaces"
  run wsm new main/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"wsm new SOURCE/WS/SPACE"* ]]
}

@test "add moves a file into the source at the matching level and links it back" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  wsm install acme/main/tech >/dev/null
  cd "$HOME/spaces/acme"
  echo org > mise.toml
  echo vault > main/opm.yml
  mkdir -p main/tech/docs && echo n > main/tech/docs/n.md
  run wsm add mise.toml main/opm.yml main/tech/docs
  [ "$status" -eq 0 ]
  [[ "$output" == *"added acme/mise.toml"*"added acme/main/opm.yml"*"added acme/main/tech/docs/n.md"* ]]
  [ "$(cat "$src/mise.toml")" = org ]
  [ "$(cat "$src/main/opm.yml")" = vault ]
  [ -f "$src/main/tech/docs/n.md" ]
  [ -L mise.toml ] && [ -L main/opm.yml ] && [ -L main/tech/docs/n.md ]
  # recorded at its own level, so remove takes it with that level
  yq -r '.files[]' "$TRACKERS/acme.yml" | grep -qx 'mise.toml'
  yq -r '.files[]' "$TRACKERS/acme/main.yml" | grep -qx 'opm.yml'
  yq -r '.files[]' "$TRACKERS/acme/main/tech.yml" | grep -qx 'docs/n.md'
  run wsm status
  [[ "$output" == *"clean"* ]]
  # add links as stow does, so the next install finds them stowed
  run wsm install acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"space acme/main/tech"*"linked 0 of 2 file(s)"* ]]
  [[ "$output" != *"linked 1"* ]]
  cd "$HOME"
  wsm remove acme/main/tech >/dev/null
  [ ! -e "$HOME/spaces/acme" ]
}

@test "add refuses what is not a level's own: clones, repositories, ignored files, the source" {
  local a src="$BATS_TEST_TMPDIR/srcs/acme"
  a=$(mkbare alpha)
  space_def acme main/tech <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  git -C "$src" init -q
  printf '.env\n' > "$src/.gitignore"
  wsm install acme/main/tech >/dev/null
  cd "$HOME/spaces/acme/main/tech"
  echo x > repos/alpha/x
  echo s > .env
  run wsm add repos/alpha/x
  [ "$status" -ne 0 ] && [[ "$output" == *"inside a git repo"* ]]
  run wsm add repos/alpha
  [ "$status" -ne 0 ]
  run wsm add .env
  [ "$status" -ne 0 ] && [[ "$output" == *"ignored by acme's .gitignore"* ]]
  [ -f .env ] && [ ! -L .env ]
  # a directory skips them quietly
  run wsm add .
  [ "$status" -eq 0 ]
  [ ! -e "$src/spaces/main/tech/.env" ]
  run wsm add "$src/spaces/main/tech/space.yml"
  [ "$status" -ne 0 ] && [[ "$output" == *"already in the source acme"* ]]
  run wsm add "$HOME/nowhere.txt"
  [ "$status" -ne 0 ]
  echo y > "$HOME/loose.txt"
  run wsm add "$HOME/loose.txt"
  [ "$status" -ne 0 ] && [[ "$output" == *"not in an installed tree"* ]]
}

@test "status lists local, changed, missing and unlinked files; add puts a changed copy back" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  space_file acme main/tech/README.md readme
  space_file acme main/tech/gone.md gone
  wsm install acme/main/tech >/dev/null
  cd "$HOME/spaces/acme/main/tech"
  echo mine > TODO
  rm README.md && echo edited > README.md
  rm gone.md
  space_file acme main/tech/NEW.md new
  run wsm status
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme  ~/spaces/acme"* ]]
  [[ "$output" == *"local     main/tech/TODO"* ]]
  [[ "$output" == *"changed   main/tech/README.md"* ]]
  [[ "$output" == *"missing   main/tech/gone.md"* ]]
  [[ "$output" == *"unlinked  main/tech/NEW.md"* ]]
  # under a directory a changed copy is only reported; named, it goes back to the source
  run wsm add .
  [ "$(cat "$src/main/tech/README.md")" = readme ]
  [[ "$output" == *"wsm add"*"README.md puts it back"* ]]
  run wsm add README.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated acme/main/tech/README.md"* ]]
  [ "$(cat "$src/main/tech/README.md")" = edited ]
  [ -L README.md ]
  run wsm status acme
  [[ "$output" != *"changed"* && "$output" != *"local"* ]]
  run wsm status nope
  [ "$status" -eq 1 ]
}

@test "implode unlinks every space and deletes the state, keeping clones" {
  local a
  a=$(mkbare alpha)
  space_def acme spikes/tech <<YML
repositories:
  - url: $a
    path: alpha
YML
  wsm install acme/ >/dev/null
  run wsm implode </dev/null
  [ "$status" -ne 0 ]
  run wsm implode -y
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_STATE_HOME/wsm" ]
  [ ! -e "$HOME/spaces/acme/main" ]
  [ -f "$HOME/spaces/acme/spikes/tech/alpha/README" ]
  [ -z "$(find "$HOME/spaces" -type l)" ]
}

@test "a level installed by name stays when its last space goes; remove of the level takes it" {
  mkdir -p "$BATS_TEST_TMPDIR/srcs/acme/spaces/ops"
  echo ops > "$BATS_TEST_TMPDIR/srcs/acme/spaces/ops/README.md"
  wsm install acme/ops >/dev/null
  run wsm path ops
  [ "$output" = "$HOME/spaces/acme/ops" ]
  cd "$HOME/spaces/acme/ops"
  run wsm path
  [ "$output" = "$HOME/spaces/acme/ops" ]
  cd "$HOME"

  # A space under a workspace installed by name: removing it leaves the workspace
  wsm install acme/main >/dev/null
  wsm remove acme/main/tech acme/main/finance >/dev/null
  [ -f "$TRACKERS/acme/main.yml" ]
  # A workspace installed only along with its space goes with it
  wsm install acme/spikes/tech >/dev/null
  wsm remove acme/spikes/tech >/dev/null
  [ ! -e "$TRACKERS/acme/spikes.yml" ] && [ ! -e "$HOME/spaces/acme/spikes" ]

  run wsm remove acme/ops
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed acme/ops"* ]]
  [ ! -e "$HOME/spaces/acme/ops" ]
  [ -f "$TRACKERS/acme.yml" ]

  run wsm remove acme
  [ "$status" -eq 0 ]
  [ ! -e "$TRACKERS/acme.yml" ] && [ ! -e "$TRACKERS/acme/main.yml" ]
  [ ! -e "$HOME/spaces/acme" ]
}
