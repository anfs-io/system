#!/usr/bin/env bats
# wsm move: a space and the spaces under it go to another source with their history
# (lib/anfs/move.sh); when installed, the directory under the root moves in one rename (clones,
# copies and the user's files untouched) and the links are made again from the new source.
# The sources are git repositories made here.
# Run: bats packages/wsm/tests/move.bats

load helper
setup() {
  wsm_setup
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  T=$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)
  ROOT="$HOME/spaces"
  OUT="$T/outside"
  mkdir -p "$OUT"
  APP=$(mkbare app)
  mksource a >/dev/null
  mksource b >/dev/null
  space_def a <<<'{}'
  space_def a tech/web <<EOF
repositories: [{url: "file://$APP", path: repos/app}]
links: [{src: $OUT, dest: out}]
files: [local.conf]
EOF
  space_file a tech/web/notes.md
  space_file a tech/web/local.conf
  space_def a tech/web/api <<<'{}'
  space_file a tech/web/api/api.md
  space_def a ops <<<'{}'
  commit_all a
  commit_all b
}

# Everything in source <a> committed
commit_all() {
  local d="$BATS_TEST_TMPDIR/srcs/$1"
  [[ -d "$d/.git" ]] || git -C "$d" init -q -b main
  git -C "$d" add -A
  git -C "$d" commit -q --allow-empty -m "${2:-spaces}"
}
heads() { local a; for a in a b; do git -C "$BATS_TEST_TMPDIR/srcs/$a" rev-parse HEAD; git -C "$BATS_TEST_TMPDIR/srcs/$a" status --porcelain; done; }
spaces_tree() {
  (cd "$ROOT" 2>/dev/null && find . -path '*/.git' -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
    if [[ -L "$p" ]]; then echo "$p -> $(readlink "$p")"; else echo "$p"; fi
  done)
}
inode() { ls -id "$1" | awk '{print $1}'; }

@test "an installed space with one under it: the directory moves whole, the links are made again from b" {
  wsm install -y a/tech/web/ >/dev/null
  echo mine > "$ROOT/a/tech/web/mine.txt"
  echo scratch > "$ROOT/a/tech/web/repos/app/untracked"
  echo changed > "$ROOT/a/tech/web/local.conf"
  local head st ino
  head=$(git -C "$ROOT/a/tech/web/repos/app" rev-parse HEAD)
  st=$(git -C "$ROOT/a/tech/web/repos/app" status --porcelain)
  ino=$(inode "$ROOT/a/tech/web/repos/app")

  run wsm move a/tech/web b
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved spaces/tech/web: a -> b, 1 commit replayed"* ]]
  [ ! -e "$ROOT/a/tech" ]
  [ ! -e "$ROOT/a" ]
  [ "$(git -C "$ROOT/b/tech/web/repos/app" rev-parse HEAD)" = "$head" ]
  [ "$(git -C "$ROOT/b/tech/web/repos/app" status --porcelain)" = "$st" ]
  [ "$(inode "$ROOT/b/tech/web/repos/app")" = "$ino" ]
  [ "$(cat "$ROOT/b/tech/web/mine.txt")" = mine ]
  [ "$(cat "$ROOT/b/tech/web/local.conf")" = changed ]
  [[ "$(readlink "$ROOT/b/tech/web/notes.md")" == *"/srcs/b/spaces/tech/web/notes.md" || "$(readlink "$ROOT/b/tech/web/notes.md")" == *"/sources/b/spaces/tech/web/notes.md" ]]
  [ "$(cat "$ROOT/b/tech/web/api/api.md")" = tech/web/api/api.md ]
  [ "$(cd "$ROOT/b/tech/web/out" && pwd -P)" = "$OUT" ]
  [ "$(ls_field b/tech/web status)" = ok ]
  [ "$(ls_field b/tech/web/api status)" = ok ]
  [ -z "$(wsm ls --json | yq -p json -r '.[] | select(.space | test("^a/tech")) | .space')" ]
}

@test "a clone's linked worktree elsewhere still works after the move" {
  wsm install -y a/tech/web/ >/dev/null
  git -C "$ROOT/a/tech/web/repos/app" worktree add -q "$T/wt" -b side
  run wsm move a/tech/web b
  [ "$status" -eq 0 ]
  [[ "$output" == *"worktrees repaired: repos/app"* ]]
  git -C "$T/wt" status >/dev/null
  [ "$(git -C "$T/wt" rev-parse --git-common-dir)" = "$ROOT/b/tech/web/repos/app/.git" ]
}

@test "events: remove with the old ids, install with the new" {
  wsm install -y a/tech/web/ >/dev/null
  local calls="$T/calls" reg="$XDG_STATE_HOME/anfs/callbacks/wsm.yml"
  mkdir -p "$T/bin" "${reg%/*}"
  printf '#!/bin/sh\necho "$*" >> "%s"\n' "$calls" > "$T/bin/listener"
  chmod +x "$T/bin/listener"
  PATH="$T/bin:$PATH"
  printf 'test/listener: listener heard\n' > "$reg"
  run wsm move a/tech/web b
  [ "$status" -eq 0 ]
  [ "$(cat "$calls")" = "heard remove a/tech/web a/tech/web/api"$'\n'"heard install b/tech/web b/tech/web/api" ]
}

@test "ids: a space that depends on it by id refuses the move; -f moves it, and that space then names nothing" {
  space_def a ops <<<'depends: [a/tech/web]'
  commit_all a ops
  run wsm move a/tech/web b
  [ "$status" -eq 1 ]
  [[ "$output" == *"a/ops depends on a/tech/web, which names a: it never resolves after the move"*"/a/spaces/ops/space.yml"* ]]
  run wsm move -f a/tech/web b
  [ "$status" -eq 0 ]
  run wsm install a/ops
  [ "$status" -ne 0 ]
  [[ "$output" == *"no space"* || "$output" == *"not found"* ]]
}

@test "a relative links: src out of the moved directory: refused, then -f" {
  space_def a tech/web/api <<<'links: [{src: ../../../ops, dest: ops}]'
  commit_all a rel
  run wsm move a/tech/web b
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"$'\t'"paths"$'\t'"a/tech/web/api: links: src ../../../ops: relative, out of a/tech/web"* ]]
  run wsm move -f a/tech/web b
  [ "$status" -eq 0 ]
  [[ "$output" == *"forced"$'\t'"paths"* ]]
}

@test "refusals: the root space, a bare path, the place taken under the root, a wrong link" {
  run wsm move a b
  [ "$status" -eq 64 ] && [[ "$output" == *"a is a source's root space"* ]]
  run wsm move tech/web b
  [ "$status" -eq 64 ] && [[ "$output" == *"'tech/web' names no source"* ]]

  wsm install -y a/tech/web/ >/dev/null
  mkdir -p "$ROOT/b/tech/web"
  local before
  before=$(heads)
  run wsm move a/tech/web b
  [ "$status" -eq 1 ] && [[ "$output" == *"/spaces/b/tech/web is there already"* ]]
  [ "$(heads)" = "$before" ]
  rm -r "$ROOT/b"

  ln -sfn /nowhere "$ROOT/a/tech/web/notes.md"
  run wsm move a/tech/web b
  [ "$status" -eq 1 ] && [[ "$output" == *"a/tech/web: 1 wrong (wsm install -f a/tech/web first"* ]]
  [ "$(heads)" = "$before" ]
}

@test "not installed: only the source moves; nothing appears under the root" {
  run wsm move a/tech/web b
  [ "$status" -eq 0 ]
  [[ "$output" == *"not installed: wsm install b/tech/web links it"* ]]
  [ -f "$BATS_TEST_TMPDIR/srcs/b/spaces/tech/web/api/space.yml" ]
  [ ! -e "$BATS_TEST_TMPDIR/srcs/a/spaces/tech" ]
  [ ! -e "$ROOT" ]
}

@test "-n: the checks, the commits and wsm's steps; nothing changes" {
  wsm install -y a/tech/web/ >/dev/null
  local before tree
  before=$(heads) tree=$(spaces_tree)
  run wsm move -n a/tech/web b
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"$'\t'"space"$'\t'"a/spaces/tech/web"* ]]
  [[ "$output" == *"replay"$'\t'"ok"* ]]
  [[ "$output" == *"move     ~/spaces/a/tech/web -> ~/spaces/b/tech/web (1 clone inside, untouched)"* ]]
  [[ "$output" == *"relink   a/tech/web: "*" links; a/tech/web/api: 2 links"* ]]
  [[ "$output" == *"events   wsm remove a/tech/web a/tech/web/api; install b/tech/web b/tech/web/api"* ]]
  [ "$(heads)" = "$before" ]
  [ "$(spaces_tree)" = "$tree" ]
}
