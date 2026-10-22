#!/usr/bin/env bats
# `anfs src push` (lib/anfs/repo.sh: anfs_repo_push_cli, the command wsm repo push shares): names
# or --all, -n, one row per source, the exit status. The real anfs in a temp $HOME; every source is
# cloned from a temporary bare repo under the test's directory, so nothing is pushed anywhere else.
# Run: bats packages/anfs/tests/push.bats

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

bats_require_minimum_version 1.5.0

setup() {
  local packages="$BATS_TEST_DIRNAME/../.." tools="$BATS_TEST_TMPDIR/tools" t
  ANFS="$packages/anfs/home/.local/bin/anfs"
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home"
  SOURCES="$HOME/.local/share/anfs/sources"
  mkdir -p "$HOME/.local/lib" "$HOME/.config/anfs" "$tools" "$SOURCES"
  ln -s "$(cd "$packages/anfs/home/.local/lib/anfs" && pwd)" "$HOME/.local/lib/anfs"
  for t in bash git; do ln -s "$(command -v "$t")" "$tools/$t"; done
  export PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_JSON ANFS_STATE_HOME
  export ANFS_LOG=off ANFS_TABLE=tsv GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  : > "$HOME/.config/anfs/user.list"
}

# Source <alias>: a bare remote with one commit on main, cloned into the sources
source_of() {
  local bare="$T/remotes/$1.git" work="$T/work/$1"
  git init -q --bare -b main "$bare"
  git init -q -b main "$work"
  echo "$1" > "$work/README"
  git -C "$work" add README
  git -C "$work" commit -qm init
  git -C "$work" push -q "$bare" main
  printf 'file://%s  %s\n' "$bare" "$1" >> "$HOME/.config/anfs/user.list"
  git clone -q "file://$bare" "$SOURCES/$1"
}

# <n> commits in source <alias>'s clone
commits() { local i; for (( i = 0; i < $2; i++ )); do git -C "$SOURCES/$1" commit -q --allow-empty -m "c$i"; done; }

# The commit main is at in <alias>'s remote, and in its clone
at_remote() { git -C "$T/remotes/$1.git" rev-parse main; }
at_clone() { git -C "$SOURCES/$1" rev-parse HEAD; }

push() { "$ANFS" src push "$@" </dev/null; }

@test "names: each outcome is a row; one failure is exit 1, and every source is still tried" {
  source_of ahead; source_of same; source_of loose; source_of loose2; source_of moved; source_of dirty
  commits ahead 2
  git -C "$SOURCES/loose" checkout -qb topic
  commits loose 1
  git -C "$SOURCES/loose2" checkout -q --detach
  commits moved 1
  git -C "$T/work/moved" commit -q --allow-empty -m theirs
  git -C "$T/work/moved" push -q "$T/remotes/moved.git" main
  commits dirty 1
  echo mine >> "$SOURCES/dirty/README"
  run push ahead same loose loose2 moved dirty
  [ "$status" -eq 1 ]
  [[ "$output" == *$'ahead\tpushed 2\tmain\torigin/main'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'same\tup to date\tmain\torigin/main'* ]]
  [[ "$output" == *$'loose\tno upstream\ttopic\t-'* ]]
  [[ "$output" == *$'loose2\tdetached\t-\t-'* ]]
  [[ "$output" == *$'moved\trejected\tmain\torigin/main'* ]]
  [[ "$output" == *"anfs: moved: rejected: ! [rejected] main -> main (fetch first)"* ]]
  [[ "$output" == *$'dirty\tpushed 1 (uncommitted changes left)\tmain\torigin/main'* ]]
  [ "$(at_remote ahead)" = "$(at_clone ahead)" ]
  [ "$(at_remote dirty)" = "$(at_clone dirty)" ]
  [ "$(tail -1 "$SOURCES/dirty/README")" = mine ]
  [ "$(at_remote moved)" != "$(at_clone moved)" ]
  [ -z "$(git -C "$T/remotes/loose.git" branch --list topic)" ]
  # all pushed or up to date: 0
  run push ahead same dirty
  [ "$status" -eq 0 ]
  [[ "$output" == *$'ahead\tup to date'* && "$output" == *$'dirty\tup to date'* ]]
}

@test "--all is every source ahead of its upstream, in list order; none ahead says so" {
  source_of a; source_of b; source_of c
  run push --all
  [ "$status" -eq 0 ]
  [ "$output" = "Nothing to push: no source is ahead of its upstream" ]
  run "$ANFS" --json src push --all </dev/null
  [ "$output" = "[]" ]
  commits c 1
  commits a 3
  run push --all
  [ "$status" -eq 0 ]
  [ "$output" = $'a\tpushed 3\tmain\torigin/main\nc\tpushed 1\tmain\torigin/main' ]
  [ "$(at_remote a)" = "$(at_clone a)" ] && [ "$(at_remote c)" = "$(at_clone c)" ]
}

@test "neither names nor --all is a usage error that lists the ahead sources; both too" {
  source_of a; source_of b; source_of c
  run push
  [ "$status" -eq 64 ]
  [[ "$output" == *"name the sources to push, or --all (none is ahead of its upstream)"* ]]
  commits a 1
  commits c 1
  run push
  [ "$status" -eq 64 ]
  [[ "$output" == *"anfs: name the sources to push, or --all for every one ahead of its upstream: a, c"* ]]
  [[ "$output" == *"usage: anfs src push"* ]]
  run push a --all
  [ "$status" -eq 64 ]
  [[ "$output" == *"names or --all, not both"* ]]
  [ "$(at_remote a)" != "$(at_clone a)" ]
}

@test "-n says what would be pushed (branch, upstream, commits) and pushes nothing" {
  local before
  source_of a; source_of b
  commits a 2
  echo x >> "$SOURCES/a/README"
  before=$(at_remote a)
  run push -n --all
  [ "$status" -eq 0 ]
  [ "$output" = $'a\twould push 2 (uncommitted changes left)\tmain\torigin/main' ]
  run push --dry-run a b
  [ "$status" -eq 0 ]
  [[ "$output" == *$'b\tup to date'* ]]
  [ "$(at_remote a)" = "$before" ]
}

@test "an unknown name is 1 before anything is pushed; a name given twice is pushed once" {
  local before
  source_of a
  commits a 1
  before=$(at_remote a)
  run push a nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"no source 'nope' (anfs src list)"* ]]
  [ "$(at_remote a)" = "$before" ]
  run push a a
  [ "$status" -eq 0 ]
  [ "$output" = $'a\tpushed 1\tmain\torigin/main' ]
}

@test "a source listed but not cloned is a row (not cloned), and a failure" {
  source_of a
  printf 'file://%s/remotes/gone.git  gone\n' "$T" >> "$HOME/.config/anfs/user.list"
  run push gone a
  [ "$status" -eq 1 ]
  [[ "$output" == *$'gone\tnot cloned\t-\t-'* && "$output" == *$'a\tup to date'* ]]
}

@test "--json: the keys, with commits and git's error line" {
  source_of a; source_of moved
  commits a 1
  commits moved 1
  git -C "$T/work/moved" commit -q --allow-empty -m theirs
  git -C "$T/work/moved" push -q "$T/remotes/moved.git" main
  ANFS_TABLE= run --separate-stderr "$ANFS" src push a moved --json </dev/null
  [ "$status" -eq 1 ]
  [ "$output" = '[{"source":"a","status":"pushed 1","branch":"main","upstream":"origin/main","commits":"1","error":null},{"source":"moved","status":"rejected","branch":"main","upstream":"origin/main","commits":"1","error":"! [rejected] main -> main (fetch first)"}]' ]
}

@test "the argument completes with the sources; the options are declared" {
  source_of a; source_of b
  run "$ANFS" __complete src push ""
  [ "$output" = $'a\nb' ]
  run "$ANFS" __complete src push -
  [[ "$output" == *--all* && "$output" == *--dry-run* && "$output" == *-n* ]]
  run "$ANFS" __complete src ""
  [[ "$output" == *$'push\tPush the current branch'* ]]
}
