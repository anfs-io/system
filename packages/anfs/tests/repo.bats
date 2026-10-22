#!/usr/bin/env bats
# lib/anfs/repo.sh (anfs_repo_*): one clone at one path. Name, clone (branch, tag, SHA, failures),
# status, update, the ssh rewrite. Remotes are local bare repos over file://; no network.
# Run: bats packages/anfs/tests/

setup() {
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../home/.local/lib/anfs/repo.sh"
  T="$BATS_TEST_TMPDIR"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_CONFIG_GLOBAL=/dev/null
}

# A bare remote <name> with a commit on main, a branch `other` and a tag v1 on the first commit;
# prints its file:// URL
remote() {
  local bare="$T/remotes/$1.git" work="$T/work/$1"
  git init -q --bare "$bare"
  git init -q -b main "$work"
  echo one > "$work/README"
  git -C "$work" add README
  git -C "$work" commit -qm one
  git -C "$work" tag v1
  git -C "$work" checkout -qb other
  echo other > "$work/OTHER"
  git -C "$work" add OTHER
  git -C "$work" commit -qm other
  git -C "$work" checkout -q main
  echo two > "$work/README"
  git -C "$work" commit -qam two
  git -C "$work" push -q "$bare" main other v1
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  echo "file://$bare"
}

# A commit pushed to <name>'s remote from its work tree
push_more() {
  echo "$2" > "$T/work/$1/README"
  git -C "$T/work/$1" commit -qam "$2"
  git -C "$T/work/$1" push -q "$T/remotes/$1.git" main
}

@test "name: the directory git clone would make, or nothing" {
  local u
  for u in git@github.com:org/app.git https://host/org/app/ https://host/org/app.git/ /srv/app.git \
           /srv/app/.git host:app file:///srv/app https://host/org/app; do
    [ "$(anfs_repo_name "$u")" = app ] || { echo "$u -> $(anfs_repo_name "$u")"; return 1; }
  done
  [ -z "$(anfs_repo_name "")" ]
  [ -z "$(anfs_repo_name /)" ]
  [ -z "$(anfs_repo_name ..)" ]
  anfs_repo_name_reply git@host:x/y.git
  [ "$REPLY" = y ]
}

@test "clone: the default branch, then a branch, a tag, a SHA" {
  local url sha
  url=$(remote r)
  anfs_repo_clone "$url" "$T/a/b/plain"
  [ "$(cat "$T/a/b/plain/README")" = two ]
  anfs_repo_clone "$url" "$T/br" other
  [ "$(git -C "$T/br" branch --show-current)" = other ]
  [ -f "$T/br/OTHER" ]
  anfs_repo_clone "$url" "$T/tag" v1
  [ "$(cat "$T/tag/README")" = one ]
  sha=$(git -C "$T/work/r" rev-parse other)
  anfs_repo_clone "$url" "$T/sha" "$sha"
  [ "$(git -C "$T/sha" rev-parse HEAD)" = "$sha" ]
}

@test "clone: a bad ref or a bad URL fails (1) and leaves nothing; an existing dir is 2, untouched" {
  local url
  url=$(remote r)
  run anfs_repo_clone "$url" "$T/badref" nope
  [ "$status" -eq 1 ]
  [ ! -e "$T/badref" ]
  run anfs_repo_clone "file://$T/nowhere.git" "$T/badurl"
  [ "$status" -eq 1 ]
  [ ! -e "$T/badurl" ]
  mkdir "$T/there"
  echo mine > "$T/there/f"
  run anfs_repo_clone "$url" "$T/there"
  [ "$status" -eq 2 ]
  [ "$(cat "$T/there/f")" = mine ]
  [ ! -e "$T/there/.git" ]
  ln -s "$T/nowhere" "$T/dangling"
  run anfs_repo_clone "$url" "$T/dangling"
  [ "$status" -eq 2 ]
  [ -L "$T/dangling" ]
}

@test "status and ahead in each state; dirty" {
  local url d="$T/c"
  url=$(remote r)
  [ "$(anfs_repo_status "$T/none")" = missing ]
  mkdir "$T/plain"
  [ "$(anfs_repo_status "$T/plain")" = local ]
  anfs_repo_clone "$url" "$d"
  [ "$(anfs_repo_status "$d")" = clean ]
  [ "$(anfs_repo_ahead "$d")" = 0 ]
  ! anfs_repo_dirty "$d"
  echo x > "$d/untracked"
  anfs_repo_dirty "$d"
  [ "$(anfs_repo_status "$d")" = dirty ]
  rm "$d/untracked"
  git -C "$d" commit -q --allow-empty -m local
  [ "$(anfs_repo_status "$d")" = unpushed ]
  [ "$(anfs_repo_ahead "$d")" = 1 ]
  echo x >> "$d/README"
  [ "$(anfs_repo_status "$d")" = "dirty, unpushed" ]
  git -C "$d" checkout -q -- README
  git -C "$d" checkout -qb loose
  [ "$(anfs_repo_status "$d")" = "no upstream" ]
  [ -z "$(anfs_repo_ahead "$d")" ]
  git -C "$d" add -A
  echo y > "$d/staged"
  git -C "$d" add staged
  [ "$(anfs_repo_status "$d")" = "dirty, no upstream" ]
}

@test "update: clean is pulled, dirty is 2 and untouched, no upstream is 1" {
  local url d="$T/c"
  url=$(remote r)
  anfs_repo_clone "$url" "$d"
  push_more r three
  run anfs_repo_update "$d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$d/README")" = three ]

  push_more r four
  echo mine > "$d/scratch"
  run anfs_repo_update "$d"
  [ "$status" -eq 2 ]
  [ "$(cat "$d/README")" = three ]
  [ -f "$d/scratch" ]
  rm "$d/scratch"

  git -C "$d" checkout -qb loose
  run anfs_repo_update "$d"
  [ "$status" -eq 1 ]
}

@test "ssh_url: GitHub https to ssh, anything else unchanged" {
  [ "$(anfs_repo_ssh_url https://github.com/o/r.git)" = git@github.com:o/r.git ]
  [ "$(anfs_repo_ssh_url https://github.com/o/r)" = git@github.com:o/r ]
  [ "$(anfs_repo_ssh_url git@github.com:o/r)" = git@github.com:o/r ]
  [ "$(anfs_repo_ssh_url https://gitlab.com/o/r)" = https://gitlab.com/o/r ]
}

@test "ssh: a GitHub https origin is switched; ssh, another host or no clone is 1 and unchanged" {
  local url
  url=$(remote r)
  anfs_repo_clone "$url" "$T/c"
  git -C "$T/c" remote set-url origin https://github.com/o/r.git
  run anfs_repo_ssh "$T/c"
  [ "$status" -eq 0 ]
  [ "$output" = git@github.com:o/r.git ]
  [ "$(git -C "$T/c" remote get-url origin)" = git@github.com:o/r.git ]
  run anfs_repo_ssh "$T/c"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  git -C "$T/c" remote set-url origin https://gitlab.com/o/r
  run anfs_repo_ssh "$T/c"
  [ "$status" -eq 1 ]
  [ "$(git -C "$T/c" remote get-url origin)" = https://gitlab.com/o/r ]
  run anfs_repo_ssh "$T/none"
  [ "$status" -eq 1 ]
}

# The commit <ref> of <name>'s bare remote
remote_rev() { git -C "$T/remotes/$1.git" rev-parse "$2"; }

@test "push: ahead is pushed (plain git push), and what was found is set; nothing ahead is 2" {
  local url d="$T/c" rc=0
  url=$(remote r)
  anfs_repo_clone "$url" "$d"
  anfs_repo_push "$d" || rc=$?
  [ "$rc" -eq 2 ]
  [ "$ANFS_REPO_BRANCH $ANFS_REPO_UPSTREAM $ANFS_REPO_AHEAD" = "main origin/main 0" ]
  git -C "$d" commit -q --allow-empty -m a
  git -C "$d" commit -q --allow-empty -m b
  git -C "$d" tag local-tag
  rc=0
  anfs_repo_push "$d" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$ANFS_REPO_BRANCH $ANFS_REPO_UPSTREAM $ANFS_REPO_AHEAD" = "main origin/main 2" ]
  [ "$(remote_rev r main)" = "$(git -C "$d" rev-parse HEAD)" ]
  # tags only as the repo's config says
  [ "$(git -C "$T/remotes/r.git" tag)" = v1 ]
  run anfs_repo_push "$d"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "push: -n pushes nothing; a dirty clone pushes its commits and keeps its changes" {
  local url d="$T/c" before rc=0
  url=$(remote r)
  anfs_repo_clone "$url" "$d"
  git -C "$d" commit -q --allow-empty -m a
  before=$(remote_rev r main)
  anfs_repo_push "$d" -n || rc=$?
  [ "$rc" -eq 0 ]
  [ "$ANFS_REPO_AHEAD" = 1 ]
  [ "$(remote_rev r main)" = "$before" ]
  echo mine >> "$d/README"
  run anfs_repo_push "$d"
  [ "$status" -eq 0 ]
  [ "$(remote_rev r main)" = "$(git -C "$d" rev-parse HEAD)" ]
  [ "$(tail -1 "$d/README")" = mine ]
}

@test "push: no upstream 3, detached 4, not a clone 5; the remote moved on is 1 with git's line" {
  local url d="$T/c" before rc=0
  url=$(remote r)
  anfs_repo_clone "$url" "$d"
  git -C "$d" checkout -qb loose
  git -C "$d" commit -q --allow-empty -m a
  rc=0; anfs_repo_push "$d" || rc=$?
  [ "$rc" -eq 3 ]
  [ "$ANFS_REPO_BRANCH" = loose ] && [ -z "$ANFS_REPO_UPSTREAM" ]
  [ "$(git -C "$T/remotes/r.git" branch --list loose)" = "" ]
  git -C "$d" checkout -q --detach
  rc=0; anfs_repo_push "$d" || rc=$?
  [ "$rc" -eq 4 ]
  [ -z "$ANFS_REPO_BRANCH" ]
  rc=0; anfs_repo_push "$T/none" || rc=$?
  [ "$rc" -eq 5 ]
  mkdir "$T/plain"
  rc=0; anfs_repo_push "$T/plain" || rc=$?
  [ "$rc" -eq 5 ]

  git -C "$d" checkout -q main
  git -C "$d" commit -q --allow-empty -m mine
  push_more r theirs
  before=$(remote_rev r main)
  rc=0; anfs_repo_push "$d" || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$REPLY" == "! [rejected] main -> main (fetch first)" ]] || { echo "$REPLY"; false; }
  [ "$(remote_rev r main)" = "$before" ]
  git -C "$d" remote set-url origin "file://$T/nowhere.git"
  rc=0; anfs_repo_push "$d" || rc=$?
  [ "$rc" -eq 1 ]
  [[ "$REPLY" == fatal:* ]]
}
