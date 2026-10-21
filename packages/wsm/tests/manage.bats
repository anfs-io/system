#!/usr/bin/env bats
# What comes after install: ls (the state, read off the links), path (what `wsm cd` is built on),
# remove, new, add, repo, implode. Nothing is recorded: every test reads what the tree says.
# Run: bats packages/wsm/tests/manage.bats

load helper
setup() {
  wsm_setup
  mksource acme >/dev/null
  space_def acme main/tech <<<'repositories: []'
  space_def acme main/finance <<<'repositories: []'
  space_def acme spikes/tech <<<'repositories: []'
}

# --- ls: the state -------------------------------------------------------------------------

@test "ls lists every space, null when not installed, ok when every link is right" {
  run wsm ls
  [ "$status" -eq 0 ]
  [ "$output" = $'acme/main/finance\t-\t-\t-\nacme/main/tech\t-\t-\t-\nacme/spikes/tech\t-\t-\t-' ]
  ANFS_TABLE=aligned run wsm ls
  [[ "${lines[0]}" == "SPACE"*"STATUS"*"DIR"*"NOTE" ]]
  wsm install acme/main/tech >/dev/null
  run wsm ls
  [[ "$output" == *$'acme/main/tech\tok\t~/spaces/acme/main/tech\t-'* ]]
  # nothing is recorded
  [ ! -e "$XDG_STATE_HOME/wsm" ]
}

@test "ls --json: space, status, dir, the counts; a space by id adds its files" {
  wsm install acme/main/tech >/dev/null
  run wsm ls --json
  [ "$status" -eq 0 ]
  local json="$output"
  run yq -p json -r '.[0] | keys | join(" ")' <<< "$json"
  [ "$output" = "space status dir missing wrong in_the_way leftover" ]
  run yq -p json -r '.[] | select(.space == "acme/main/tech") | .dir + " " + .status + " " + .missing' <<< "$json"
  [ "$output" = "$HOME/spaces/acme/main/tech ok 0" ]
  run yq -p json -r '.[] | select(.space == "acme/spikes/tech") | (.dir | tag) + " " + (.status | tag)' <<< "$json"
  [ "$output" = "!!null !!null" ]
  space_file acme main/tech/new.md
  run wsm ls acme/main/tech --json
  [ "$status" -eq 0 ]
  run yq -p json -r '.[0].files[] | .file + "=" + .status' <<< "$output"
  [ "$output" = $'new.md=missing\nspace.yml=ok' ]
  # a prefix has no files
  run wsm --json ls acme/main/
  [ "$(yq -p json -r 'length' <<< "$output")" = 2 ]
  [ "$(yq -p json -r '.[0].files | tag' <<< "$output")" = '!!null' ]
}

@test "partial: a file gone from the source is a leftover, a new one missing; a re-install is ok" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  space_file acme main/tech/gone.md
  wsm install acme/main/tech >/dev/null
  rm "$src/main/tech/gone.md"
  run wsm ls
  [[ "$output" == *$'acme/main/tech\tpartial\t~/spaces/acme/main/tech\t1 leftover'* ]]
  space_file acme main/tech/new.md
  run wsm ls acme/main/tech
  [ "$output" = $'acme/main/tech\tpartial\t~/spaces/acme/main/tech\t1 missing, 1 leftover' ]
  run wsm ls acme/main/tech --json
  [ "$(yq -p json -r '.[0].files[] | select(.status == "leftover") | .file' <<< "$output")" = gone.md ]
  wsm install acme/main/tech >/dev/null
  run wsm ls acme/main/tech
  [[ "$output" == *$'\tok\t'* ]]
}

@test "partial: a user file where a link goes is in the way, a link elsewhere wrong" {
  space_file acme main/tech/a.md
  space_file acme main/tech/b.md
  wsm install acme/main/tech >/dev/null
  rm "$HOME/spaces/acme/main/tech/a.md" "$HOME/spaces/acme/main/tech/b.md"
  echo mine > "$HOME/spaces/acme/main/tech/a.md"
  ln -s /etc/hosts "$HOME/spaces/acme/main/tech/b.md"
  run wsm ls acme/main/tech
  [ "$output" = $'acme/main/tech\tpartial\t~/spaces/acme/main/tech\t1 wrong, 1 in the way' ]
}

@test "a space whose space.yml left the source is not in the source, one level below a mirror; remove takes it" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  space_file acme main/old/notes.md
  space_def acme main/old <<<'repositories: []'
  wsm install acme/main/old acme/main/tech >/dev/null
  mkdir -p "$HOME/spaces/acme/main/old/clone/.git"
  rm -r "$src/main/old"
  run wsm ls
  [[ "$output" == *$'acme/main/old\tnot in the source\t~/spaces/acme/main/old'* ]]
  run wsm ls acme/main/old --json
  [ "$(yq -p json -r '.[0].status' <<< "$output")" = "not in the source" ]
  run wsm remove -y acme/main/old
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed acme/main/old"* ]]
  [ ! -L "$HOME/spaces/acme/main/old/notes.md" ] && [ ! -L "$HOME/spaces/acme/main/old/space.yml" ]
  [ -d "$HOME/spaces/acme/main/old/clone/.git" ]
  run wsm ls
  [[ "$output" != *"not in the source"* ]]
}

@test "a space that vanished two levels below the nearest mirror is not seen (the documented limit)" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  space_def acme x/y/z <<<'repositories: []'
  wsm install acme/x/y/z >/dev/null
  rm -r "$src/x"
  run wsm ls
  [[ "$output" != *"acme/x/y/z"* ]]
}

@test "the user's files and links, and an ovm-style link, are never listed, changed or removed" {
  local a
  a=$(mkbare alpha)
  space_def acme main/tech <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  wsm install acme/main/tech >/dev/null
  local d="$HOME/spaces/acme/main/tech"
  echo mine > "$d/TODO"
  ln -s TODO "$d/todo-link"
  mkdir -p "$HOME/vault/notes"
  ln -s "$HOME/vault/notes" "$d/notes"
  run wsm ls --json
  [[ "$output" != *TODO* && "$output" != *notes* ]]
  [ "$(ls_field acme/main/tech status)" = ok ]
  wsm install acme/main/tech >/dev/null
  wsm remove -y acme/main/tech >/dev/null
  [ -f "$d/TODO" ] && [ -L "$d/todo-link" ] && [ "$(readlink "$d/notes")" = "$HOME/vault/notes" ]
  [ -d "$d/repos/alpha/.git" ]
  wsm install acme/main/tech >/dev/null
  wsm implode -y >/dev/null 2>&1
  [ -f "$d/TODO" ] && [ -L "$d/todo-link" ] && [ -L "$d/notes" ]
}

@test "ls SPEC narrows: an id is that space, a prefix the spaces under it; nothing is 1" {
  run wsm ls acme/main/
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme/main/tech"* && "$output" != *"spikes"* ]]
  run wsm ls acme/spikes/tech
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  run wsm ls acme/
  [[ "$output" == *"spikes"* && "$output" == *"main"* ]]
  run wsm ls acme/nope
  [ "$status" -eq 1 ]
  run wsm ls -r
  [ "$status" -eq 64 ]
}

@test "an old tracker directory changes nothing, and status is no command" {
  mkdir -p "$XDG_STATE_HOME/wsm/installed/acme/main"
  printf 'source: acme\nworkspace: main\nspace: tech\ntarget: /x\ndir: /x/acme/main/tech\n' > "$XDG_STATE_HOME/wsm/installed/acme/main/tech.yml"
  run wsm ls
  [[ "$output" == *$'acme/main/tech\t-'* ]]
  run wsm status
  [ "$status" -eq 64 ]
  wsm install acme/main/tech >/dev/null
  [ -f "$XDG_STATE_HOME/wsm/installed/acme/main/tech.yml" ]
}

# --- repo ----------------------------------------------------------------------------------

@test "repo ls lists the repositories space.yml files declare, with their state" {
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
  run wsm repo ls
  [ "$status" -eq 0 ]
  [[ "$output" == *$'acme/main/tech/repos/alpha\tclean\t'"$a"* ]]
  [[ "$output" == *$'acme/spikes/tech/beta\tnot installed\t'"$b"* ]]
  ANFS_TABLE=aligned run wsm repo ls
  [[ "${lines[0]}" == "REPOSITORY"*"STATUS"*"URL" ]]
  run wsm repo ls --json
  local json="$output"
  run yq -p json -r '.[0] | keys | join(" ")' <<< "$json"
  [ "$output" = "repository status url ahead space path dir" ]
  run yq -p json -r '.[] | select(.space == "acme/main/tech") | .path + " " + .dir' <<< "$json"
  [ "$output" = "repos/alpha $HOME/spaces/acme/main/tech/repos/alpha" ]
  run yq -p json -r '.[] | select(.space == "acme/spikes/tech") | .dir | tag' <<< "$json"
  [ "$output" = '!!null' ]
  echo x > "$HOME/spaces/acme/main/tech/repos/alpha/new"
  run wsm repo ls acme/main/
  [[ "$output" == *"dirty"* && "$output" != *"beta"* ]]
  rm "$HOME/spaces/acme/main/tech/repos/alpha/new"
  git -C "$HOME/spaces/acme/main/tech/repos/alpha" -c user.email=t@t -c user.name=t commit -qm x --allow-empty
  run wsm repo ls acme/main/tech
  [[ "$output" == *$'acme/main/tech/repos/alpha\tunpushed\t'* ]]
  rm -rf "$HOME/spaces/acme/main/tech/repos/alpha"
  run wsm repo ls acme/main/tech
  [[ "$output" == *"missing"* ]]
}

@test "repo install clones what an installed space declares and is missing; links nothing" {
  local a b
  a=$(mkbare alpha) b=$(mkbare beta)
  wsm install acme/main/tech >/dev/null
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
  echo new > "$BATS_TEST_TMPDIR/srcs/acme/spaces/main/tech/NEWFILE"
  run wsm repo install -n
  [ "$status" -eq 0 ]
  [[ "$output" == *"would clone repos/alpha"* ]]
  [ ! -e "$HOME/spaces/acme/main/tech/repos/alpha" ]
  run wsm repo install
  [ "$status" -eq 0 ]
  [ -d "$HOME/spaces/acme/main/tech/repos/alpha/.git" ]
  [ ! -e "$HOME/spaces/acme/spikes" ]
  [ ! -e "$HOME/spaces/acme/main/tech/NEWFILE" ]
  run wsm repo install acme/main/tech
  [[ "$output" == *"present repos/alpha"* ]]
  run wsm repo install acme/
  [ "$status" -eq 0 ]
}

@test "repo install REPOSITORY splits at the longest space and clones that one; its space must be installed" {
  local a b c
  a=$(mkbare alpha) b=$(mkbare beta) c=$(mkbare gamma)
  space_def acme a <<<'repositories: []'
  space_def acme a/b/c <<YML
repositories:
  - url: $a
    path: web
  - url: $c
YML
  space_def acme spikes/tech <<YML
repositories:
  - url: $b
    path: beta
YML
  wsm install acme/a acme/a/b/c >/dev/null
  rm -rf "$HOME/spaces/acme/a/b/c/web" "$HOME/spaces/acme/a/b/c/gamma"
  run wsm repo install -n acme/a/b/c/web
  [ "$status" -eq 0 ]
  [[ "$output" == *"would clone web"* && "$output" != *gamma* ]]
  run wsm repo install acme/a/b/c/web
  [ "$status" -eq 0 ]
  [ -d "$HOME/spaces/acme/a/b/c/web/.git" ]
  [ ! -e "$HOME/spaces/acme/a/b/c/gamma" ]
  run wsm repo install acme/spikes/tech/beta
  [ "$status" -ne 0 ]
  [[ "$output" == *"acme/spikes/tech is not installed"* ]]
  [ ! -e "$HOME/spaces/acme/spikes" ]
  run wsm repo install acme/a/b/c/nope
  [ "$status" -eq 1 ]
}

# --- path ----------------------------------------------------------------------------------

@test "path resolves an id, then the end of one: one segment or two" {
  wsm install -y acme/ >/dev/null
  run wsm path acme/main/tech
  [ "$output" = "$HOME/spaces/acme/main/tech" ]
  run wsm path finance
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/spaces/acme/main/finance" ]
  run wsm path spikes/tech
  [ "$output" = "$HOME/spaces/acme/spikes/tech" ]
}

@test "an ambiguous query lists the candidates and exits 2; none or not installed exits 1" {
  wsm install -y acme/main/ >/dev/null
  wsm install acme/spikes/tech >/dev/null
  run wsm path tech
  [ "$status" -eq 2 ]
  [[ "$output" == *"acme/main/tech"* && "$output" == *"acme/spikes/tech"* ]]
  run wsm path nope
  [ "$status" -eq 1 ]
  wsm remove -y acme/spikes/tech >/dev/null
  run wsm path spikes/tech
  [ "$status" -eq 1 ]
}

@test "a space whose directory is gone is not installed: 1, never 3" {
  wsm install acme/main/tech >/dev/null
  rm -r "$HOME/spaces/acme/main/tech"
  run wsm path acme/main/tech
  [ "$status" -eq 1 ]
}

@test "path with no query is the deepest installed space containing ." {
  space_def acme main/tech/web <<<'repositories: []'
  wsm install -y acme/main/ >/dev/null
  mkdir -p "$HOME/spaces/acme/main/tech/web/deep/er"
  cd "$HOME/spaces/acme/main/tech/web/deep/er"
  run wsm path
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/spaces/acme/main/tech/web" ]
  cd "$HOME/spaces/acme/main/tech"
  run wsm path
  [ "$output" = "$HOME/spaces/acme/main/tech" ]
  cd "$HOME"
  run wsm path
  [ "$status" -eq 1 ]
}

@test "path takes a source for its directory" {
  wsm install acme/main/tech >/dev/null
  run wsm path acme/
  [ "$output" = "$HOME/spaces/acme" ]
  run wsm path acme
  [ "$output" = "$HOME/spaces/acme" ]
}

@test "path -s gives the directory in the source; a qualified name needs nothing installed" {
  local src="$HOME/.local/share/anfs/sources/acme/spaces"
  run wsm path -s acme/spikes/tech
  [ "$status" -eq 0 ]
  [ "$output" = "$src/spikes/tech" ]
  run wsm path --source acme/main
  [ "$output" = "$src/main" ]
  run wsm path -s acme
  [ "$output" = "$src" ]
  run wsm path -s acme/nope
  [ "$status" -eq 1 ]
  wsm install acme/main/finance >/dev/null
  run wsm path -s finance
  [ "$output" = "$src/main/finance" ]
  cd "$HOME/spaces/acme/main/finance"
  run wsm path -s
  [ "$output" = "$src/main/finance" ]
}

# --- remove --------------------------------------------------------------------------------

@test "remove unlinks, keeping clones and the user's files; it asks" {
  local a
  a=$(mkbare alpha)
  space_def acme main/tech <<YML
repositories:
  - url: $a
    path: repos/alpha
YML
  space_file acme main/tech/docs/notes.md
  wsm install -y acme/main/ >/dev/null
  echo mine > "$HOME/spaces/acme/main/tech/TODO"
  run wsm remove acme/main/tech </dev/null
  [ "$status" -eq 77 ]
  [ -L "$HOME/spaces/acme/main/tech/space.yml" ]
  run wsm remove -y acme/main/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed acme/main/tech"* ]]
  [ ! -e "$HOME/spaces/acme/main/tech/space.yml" ]
  [ ! -e "$HOME/spaces/acme/main/tech/docs" ]
  [ -f "$HOME/spaces/acme/main/tech/repos/alpha/README" ]
  [ -f "$HOME/spaces/acme/main/tech/TODO" ]
  [ "$(installed)" = acme/main/finance ]
}

@test "remove of a prefix takes every installed space under it and leaves no empty directory" {
  wsm install -y acme/ >/dev/null
  run wsm remove -y acme/main/
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/spaces/acme/main" ]
  [ "$(installed)" = acme/spikes/tech ]
  run wsm remove -y acme/main/
  [ "$status" -eq 1 ]
  wsm remove -y acme/ >/dev/null
  [ ! -e "$HOME/spaces/acme" ] && [ -d "$HOME/spaces" ]
}

@test "removing a child space leaves its parent's links; removing the parent leaves the child's" {
  space_def acme main <<<'repositories: []'
  space_file acme main/org.md
  space_file acme main/tech/t.md
  wsm install acme/main acme/main/tech >/dev/null
  wsm remove -y acme/main/tech >/dev/null
  [ -L "$HOME/spaces/acme/main/org.md" ] && [ -L "$HOME/spaces/acme/main/space.yml" ]
  [ ! -e "$HOME/spaces/acme/main/tech" ]
  wsm install acme/main/tech >/dev/null
  wsm remove -y acme/main >/dev/null
  [ ! -e "$HOME/spaces/acme/main/org.md" ]
  [ -L "$HOME/spaces/acme/main/tech/t.md" ]
}

@test "remove takes space.yml last: an interrupted remove leaves the space partial" {
  space_file acme main/tech/docs/n.md
  wsm install acme/main/tech >/dev/null
  chmod 555 "$HOME/spaces/acme/main/tech/docs"
  run wsm remove -y acme/main/tech
  chmod 755 "$HOME/spaces/acme/main/tech/docs"
  [ "$status" -ne 0 ]
  [ -L "$HOME/spaces/acme/main/tech/space.yml" ]
  [ "$(ls_field acme/main/tech status)" = ok ]
  rm "$HOME/spaces/acme/main/tech/docs/n.md"
  [ "$(ls_field acme/main/tech status)" = partial ]
}

@test "remove leaves a link the user replaced" {
  wsm install acme/main/tech >/dev/null
  rm "$HOME/spaces/acme/main/tech/space.yml"
  echo mine > "$HOME/spaces/acme/main/tech/space.yml"
  run wsm remove -y acme/main/tech
  [ "$status" -eq 1 ]
  [ "$(cat "$HOME/spaces/acme/main/tech/space.yml")" = mine ]
}

# --- new and add ---------------------------------------------------------------------------

@test "new SOURCE/PATH works anywhere, at any depth, and refuses one that exists" {
  run wsm new acme/main/marketing/eu
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/srcs/acme/spaces/main/marketing/eu/space.yml" ]
  [[ "$output" == *"next: wsm install acme/main/marketing/eu"* ]]
  [ -z "$(installed)" ]
  run wsm new acme/main/marketing/eu
  [ "$status" -eq 73 ]
  run wsm new nope/x
  [ "$status" -eq 1 ]
  run wsm new ./x
  [ "$status" -eq 64 ]
  run wsm new acme/x/
  [ "$status" -eq 64 ]
}

@test "new PATH is below where you are: a source checkout's spaces/, or the tree" {
  local src="$BATS_TEST_TMPDIR/srcs/acme"
  mkdir -p "$src/docs"
  cd "$src/docs"
  run wsm new ops/db
  [ "$status" -eq 0 ]
  [ -f "$src/spaces/ops/db/space.yml" ]
  cd "$src/spaces/main/tech"
  run wsm new web
  [ "$status" -eq 0 ]
  [ -f "$src/spaces/main/tech/web/space.yml" ]
  # spaces/ is created in a source that has none yet
  local fresh
  fresh=$(mksource fresh)
  rmdir "$fresh/spaces"
  cd "$fresh"
  run wsm new first
  [ "$status" -eq 0 ]
  [ -f "$fresh/spaces/first/space.yml" ]
  cd "$HOME"
  run wsm new loose
  [ "$status" -eq 1 ]
  [[ "$output" == *"wsm new SOURCE/PATH"* ]]
}

@test "new inside an installed space creates it in the source and installs it" {
  space_file acme main/tech/web/index.md
  wsm install acme/main/tech >/dev/null
  cd "$HOME/spaces/acme/main/tech"
  run wsm new web
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/srcs/acme/spaces/main/tech/web/space.yml" ]
  [ -L "$HOME/spaces/acme/main/tech/web/space.yml" ]
  [[ "$output" == *"commit it in"* ]]
  # it took the file below it, whose link was already right
  [ "$(ls_field acme/main/tech/web status)" = ok ]
  [ "$(ls_field acme/main/tech status)" = ok ]
  # where no space around it is installed, it is only created
  cd "$HOME/spaces/acme"
  run wsm new ops
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/spaces/acme/ops" ]
}

@test "add moves a file into the source, into its nearest space, and links it back" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  space_def acme main <<<'repositories: []'
  wsm install acme/main acme/main/tech >/dev/null
  cd "$HOME/spaces/acme/main"
  echo vault > opm.yml
  mkdir -p tech/docs && echo n > tech/docs/n.md
  run wsm add opm.yml tech/docs
  [ "$status" -eq 0 ]
  [[ "$output" == *"added acme/main/opm.yml"*"added acme/main/tech/docs/n.md"* ]]
  [ "$(cat "$src/main/opm.yml")" = vault ]
  [ -f "$src/main/tech/docs/n.md" ]
  [ -L opm.yml ] && [ -L tech/docs/n.md ]
  [ "$(ls_field acme/main status)" = ok ]
  [ "$(ls_field acme/main/tech status)" = ok ]
  # add links as install does, so the next install finds them linked
  run wsm install acme/main/tech
  [[ "$output" == *"linked 0 of 2 file(s)"* ]]
  cd "$HOME"
  wsm remove -y acme/main acme/main/tech >/dev/null
  [ ! -e "$HOME/spaces/acme" ]
}

@test "add refuses what is not a space's own: clones, repositories, ignored files, no space, the source" {
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
  run wsm add .
  [ "$status" -eq 0 ]
  [ ! -e "$src/spaces/main/tech/.env" ]
  echo y > "$HOME/spaces/acme/main/loose.md"
  run wsm add "$HOME/spaces/acme/main/loose.md"
  [ "$status" -ne 0 ] && [[ "$output" == *"not in any space of acme"* ]]
  run wsm add "$src/spaces/main/tech/space.yml"
  [ "$status" -ne 0 ] && [[ "$output" == *"already in the source acme"* ]]
  echo y > "$HOME/elsewhere.txt"
  run wsm add "$HOME/elsewhere.txt"
  [ "$status" -ne 0 ] && [[ "$output" == *"not in the spaces tree"* ]]
}

@test "add puts a copy where the source has the file back in the source, only when named" {
  local src="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  space_file acme main/tech/README.md readme
  wsm install acme/main/tech >/dev/null
  cd "$HOME/spaces/acme/main/tech"
  rm README.md && echo edited > README.md
  run wsm ls acme/main/tech
  [[ "$output" == *"1 in the way"* ]]
  run wsm add .
  [ "$(cat "$src/main/tech/README.md")" = readme ]
  [[ "$output" == *"wsm add"*"README.md puts it in the source"* ]]
  run wsm add README.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated acme/main/tech/README.md"* ]]
  [ "$(cat "$src/main/tech/README.md")" = edited ]
  [ -L README.md ]
  run wsm ls acme/main/tech
  [[ "$output" == *$'\tok\t'* ]]
}

# --- implode -------------------------------------------------------------------------------

@test "implode unlinks every space and deletes the state, backups included, keeping clones" {
  local a
  a=$(mkbare alpha)
  space_def acme spikes/tech <<YML
repositories:
  - url: $a
    path: alpha
YML
  mkdir -p "$HOME/spaces/acme/main/tech" && echo mine > "$HOME/spaces/acme/main/tech/space.yml"
  wsm install -y -f acme/ >/dev/null
  [ -f "$XDG_STATE_HOME/wsm/backup/acme/main/tech/space.yml" ]
  run wsm implode </dev/null
  [ "$status" -ne 0 ]
  run wsm implode -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"the backups install -f made included"* ]]
  [ ! -e "$XDG_STATE_HOME/wsm" ]
  [ ! -e "$HOME/spaces/acme/main" ]
  [ -f "$HOME/spaces/acme/spikes/tech/alpha/README" ]
  [ -z "$(find "$HOME/spaces" -type l)" ]
}

# --- completion ----------------------------------------------------------------------------

@test "completion: ids and prefixes from the sources' file names; remove and cd the installed ones" {
  space_def acme <<<'repositories: []'
  wsm install acme/main/tech >/dev/null
  run wsm __complete install ""
  [ "$status" -eq 0 ]
  [ "$(cut -f1 <<< "$output" | LC_ALL=C sort | tr '\n' ' ')" = "$(printf '%s\n' acme acme/ acme/main/ acme/main/finance acme/main/finance/ acme/main/tech acme/main/tech/ acme/spikes/ acme/spikes/tech acme/spikes/tech/ | LC_ALL=C sort | tr '\n' ' ')" ]
  run wsm __complete remove ""
  [ "$(cut -f1 <<< "$output" | tr '\n' ' ')" = "acme/main/tech " ]
  run wsm __complete path ""
  [ "$(cut -f1 <<< "$output" | tr '\n' ' ')" = "acme/main/tech tech " ]
}
