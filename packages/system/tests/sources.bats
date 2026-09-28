#!/usr/bin/env bats
# shared/sources.sh (gitsrc_*): source lists, status, add/remove, update, ssh.
# Remotes are local bare repos reached through file:// URLs, so nothing touches the network.
# Run: bats packages/system/tests/

setup() {
  # shellcheck source=/dev/null
  source "$BATS_TEST_DIRNAME/../home/.local/lib/ppm/shared/sources.sh"

  T="$BATS_TEST_TMPDIR"
  GITSRC_TOOL=tool
  GITSRC_USER_LIST="$T/config/user.list"
  GITSRC_SYSTEM_LIST="$T/config/system.list"
  GITSRC_REPOS_DIR="$T/repos"
  GITSRC_CACHE_DIR="$T/cache"
  GITSRC_LINK_LOCAL=false
  mkdir -p "$T/config"

  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_CONFIG_GLOBAL=/dev/null
}

# A bare remote with one commit; prints its file:// URL
remote() {
  local bare="$T/remotes/$1.git" work="$T/work/$1"
  git init -q --bare "$bare"
  git init -q "$work"
  echo "$1" > "$work/README"
  git -C "$work" add README
  git -C "$work" commit -qm init
  git -C "$work" push -q "$bare" HEAD:refs/heads/main
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  echo "file://$bare"
}

@test "collect: user entries first, alias dedup keeps the user one, alias defaults to basename" {
  printf 'file:///u/a.git  a\n# comment\n\nfile:///u/bee.git\n' > "$GITSRC_USER_LIST"
  printf 'file:///s/a.git  a\nfile:///s/c.git  c\n' > "$GITSRC_SYSTEM_LIST"
  gitsrc_collect
  [ "${GITSRC_NAMES[*]}" = "a bee c" ]
  [ "${GITSRC_URLS[0]}" = "file:///u/a.git" ]
  [ "$(gitsrc_index c)" = 2 ]
  [ "$(gitsrc_index nope)" = 9999 ]
}

@test "collect: no lists at all is empty, not an error" {
  gitsrc_collect
  [ "${#GITSRC_NAMES[@]}" -eq 0 ]
}

@test "add: appends, --top prepends, duplicate URL is a no-op" {
  run gitsrc_add file:///x/one.git
  [ "$output" = "Added source: file:///x/one.git (one)" ]
  gitsrc_add --top file:///x/two.git second
  run gitsrc_add file:///x/one.git
  [ "$output" = "Source already exists: file:///x/one.git" ]
  [ "$(cat "$GITSRC_USER_LIST")" = "$(printf 'file:///x/two.git  second\nfile:///x/one.git  one')" ]
}

@test "remove: by alias or URL; the system list is never edited" {
  printf 'file:///x/one.git  one\nfile:///x/two.git  two\n' > "$GITSRC_USER_LIST"
  printf 'file:///s/sys.git  sys\n' > "$GITSRC_SYSTEM_LIST"
  gitsrc_remove one
  gitsrc_remove file:///x/two.git
  [ ! -s "$GITSRC_USER_LIST" ]
  run gitsrc_remove sys
  [ "$status" -eq 1 ]
  [ "$output" = "Source not found in user list: sys (system.list is tool-managed)" ]
  grep -q sys "$GITSRC_SYSTEM_LIST"
}

@test "update clones, list shows clean/dirty/missing, dirty repos are skipped" {
  local a b
  a=$(remote a); b=$(remote b)
  printf '%s  a\n%s  b\n' "$a" "$b" > "$GITSRC_USER_LIST"
  printf 'file:///nowhere/c.git  c\n' > "$GITSRC_SYSTEM_LIST"

  gitsrc_update a b
  [ -d "$T/repos/a/.git" ] && [ -d "$T/repos/b/.git" ]
  [ -f "$T/cache/updated/a" ]

  echo change >> "$T/repos/b/README"
  run gitsrc_list
  [ "${lines[0]}" = "# user (user.list)" ]
  [ "${lines[1]}" = "$a  a  clean" ]
  [ "${lines[2]}" = "$b  b  dirty" ]
  [ "${lines[3]}" = "# system (system.list)" ]
  [ "${lines[4]}" = "file:///nowhere/c.git  c  missing" ]

  run gitsrc_update b
  [ "$status" -eq 1 ]
  [[ "$output" == *"Skipping b: has uncommitted changes"* ]]

  run gitsrc_update --auto a b
  [[ "$output" == *"Not updated (uncommitted changes): b"* ]]
}

@test "update pulls new commits" {
  local a
  a=$(remote a)
  echo "$a  a" > "$GITSRC_USER_LIST"
  gitsrc_update
  echo more >> "$T/work/a/README"
  git -C "$T/work/a" commit -qam more
  git -C "$T/work/a" push -q "$T/remotes/a.git" HEAD:refs/heads/main
  gitsrc_update a
  grep -q more "$T/repos/a/README"
}

@test "update_stale: only repos older than the TTL" {
  local a b
  a=$(remote a); b=$(remote b)
  printf '%s  a\n%s  b\n' "$a" "$b" > "$GITSRC_USER_LIST"
  gitsrc_update a
  GITSRC_UPDATE_TTL=3600
  gitsrc_stale b
  ! gitsrc_stale a
  run gitsrc_update_stale
  [[ "$output" == *"Cloning: $b"* ]]
  [[ "$output" != *"Updating: a"* ]]
}

@test "local paths: never cloned; LINK_LOCAL resolves them in place" {
  mkdir -p "$T/mine"
  echo "$T/mine  mine" > "$GITSRC_USER_LIST"
  run gitsrc_update
  [ "$status" -eq 0 ]
  [ ! -e "$T/repos/mine" ]

  gitsrc_collect
  [ "$(gitsrc_dir mine)" = "$T/repos/mine" ]
  GITSRC_LINK_LOCAL=true
  [ "$(gitsrc_dir mine)" = "$T/mine" ]
  [ "$(gitsrc_status mine)" = local ]
}

@test "ssh: rewrites user-list https entries; system-list ones are reported with the hint" {
  printf 'https://github.com/me/u.git  u\n' > "$GITSRC_USER_LIST"
  printf 'https://github.com/me/s.git  s\n' > "$GITSRC_SYSTEM_LIST"
  GITSRC_SYSTEM_LIST_HINT="protect it"
  run gitsrc_ssh
  [ "${lines[0]}" = "u: user.list -> git@github.com:me/u.git" ]
  [ "${lines[1]}" = "s: https in system.list (tool-managed); protect it" ]
  grep -q '^git@github.com:me/u.git  u$' "$GITSRC_USER_LIST"
  grep -q '^https://github.com/me/s.git' "$GITSRC_SYSTEM_LIST"
}

@test "ssh: the system list is rewritten when the hook allows it" {
  printf 'https://github.com/me/s.git  s\n' > "$GITSRC_SYSTEM_LIST"
  gitsrc_hook_system_writable() { return 0; }
  run gitsrc_ssh s
  [ "$output" = "s: system.list -> git@github.com:me/s.git" ]
}

@test "command: usage, and an unknown subcommand fails" {
  run gitsrc_command
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Usage: tool src <add|remove|list|ssh|update>" ]
  run gitsrc_command bogus
  [ "$status" -eq 1 ]
}
