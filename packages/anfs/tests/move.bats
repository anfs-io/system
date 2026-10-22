#!/usr/bin/env bats
# lib/anfs/move.sh: a resource moves to another source with its history (format-patch, am), or in
# one commit when the replay would not reproduce it; the checks before (anfs_move_check) and the
# command's declaration. Sources are git repositories made here, with bare remotes over file://;
# no network, no real repository.
# Run: bats packages/anfs/tests/move.bats

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  T=$(cd -P "$BATS_TEST_TMPDIR" && pwd -P)
  export HOME="$T/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export ANFS_LOG=off
  ANFS_SOURCES_HOME="$HOME/.local/share/anfs/sources"
  GITSRC_USER_LIST="$T/user.list" GITSRC_SYSTEM_LIST="$T/system.list"
  GITSRC_REPOS_DIR="$ANFS_SOURCES_HOME" GITSRC_LINK_LOCAL=false
  : > "$GITSRC_USER_LIST"
  CLI_TOOL=anfs
  # shellcheck source=/dev/null
  source "$lib/log.sh"
  source "$lib/sources.sh"
  source "$lib/resolve.sh"
  source "$lib/cli.sh"
  source "$lib/move.sh"
  S="$ANFS_SOURCES_HOME"
  ANFS_MOVE_MANIFEST=package.yml
}

# Sources <alias>..., in priority order (the first highest): each a repository on main with one
# commit, pushed to a bare remote
src() {
  local a
  for a in "$@"; do
    git init -q -b main "$S/$a"
    git -C "$S/$a" commit -q --allow-empty -m "init $a"
    git init -q --bare "$T/remotes/$a.git"
    git -C "$S/$a" remote add origin "file://$T/remotes/$a.git"
    git -C "$S/$a" push -q -u origin main 2>/dev/null
    printf 'file://%s  %s\n' "$T/remotes/$a.git" "$a" >> "$GITSRC_USER_LIST"
  done
}

# put <alias> <path> [content]: a file in a source's working tree
put() { mkdir -p "$(dirname "$S/$1/$2")"; printf '%s\n' "${3:-$2}" > "$S/$1/$2"; }

# commit <alias> <author> <date> <message>...: everything, as that author at that date (the
# committer date a day later, as an amend or a rebase leaves it)
commit() {
  local a="$1" who="$2" date="$3"
  shift 3
  git -C "$S/$a" add -A
  GIT_AUTHOR_NAME="$who" GIT_AUTHOR_EMAIL="$who@example.org" GIT_AUTHOR_DATE="$date" \
    GIT_COMMITTER_DATE="$(( ${date%% *} + 86400 )) ${date#* }" git -C "$S/$a" commit -q "${@/#/-m}"
}

# What a commit list must keep: author, author date, whole message
hist() { git -C "$S/$1" log --reverse --date=raw --format='%an <%ae>|%ad|%B' "${@:2}"; }
tree() { git -C "$S/$1" rev-parse "HEAD:$2"; }
clean() { [ -z "$(git -C "$S/$1" status --porcelain)" ]; }
state() { for a in "$@"; do git -C "$S/$a" rev-parse HEAD; git -C "$S/$a" status --porcelain; (cd "$S/$a" && find . -path ./.git -prune -o -print | LC_ALL=C sort); done; }
deps() { yq -r '.depends[]?' "$1/package.yml" 2>/dev/null || true; }

# A package with five commits: two authors a year apart, a commit that touches another package
# too, a rename inside, a binary file, a symlink, an executable, a CRLF file, a [wip] subject
five() {
  src a b
  put a packages/tool/package.yml "version: 0.1.0"
  put a packages/tool/home/rc one
  printf 'x\r\ny\r\n' > "$S/a/packages/tool/home/dos.txt"
  commit a alice "1700000000 +0100" "tool: first" "The body, two lines
of it."
  printf '\x00\x01\x02\xff' > "$S/a/packages/tool/home/blob.bin"
  ln -s rc "$S/a/packages/tool/home/link"
  printf '#!/bin/sh\necho hi\n' > "$S/a/packages/tool/home/run"
  chmod +x "$S/a/packages/tool/home/run"
  commit a alice "1700100000 +0100" "tool: binary, link, executable"
  put a packages/tool/home/rc two
  put a packages/other/package.yml "version: 0.1.0"
  commit a bob "1731700000 -0500" "[wip] tool and other"
  git -C "$S/a" mv packages/tool/home/rc packages/tool/home/rc2
  commit a bob "1731800000 -0500" "tool: rename"
  printf 'a\r\nb\r\n' > "$S/a/packages/tool/home/dos.txt"
  commit a alice "1731900000 +0100" "tool: crlf"
  git -C "$S/a" push -q origin main
  git -C "$S/b" push -q origin main
}

@test "a replay: every commit with its author, date and message; the tree; one commit out; clean; nothing pushed" {
  five
  local want t0 ra rb
  want=$(hist a HEAD -- packages/tool)
  t0=$(tree a packages/tool)
  ra=$(git -C "$T/remotes/a.git" rev-parse main) rb=$(git -C "$T/remotes/b.git" rev-parse main)

  anfs_move_tree packages a/tool b > "$T/out"
  [ "$ANFS_MOVE_METHOD" = replay ]
  [ "$ANFS_MOVE_COMMITS" = 5 ]
  [ "$(cat "$T/out")" = "moved packages/tool: a -> b, 5 commits replayed" ]
  [ "$(hist b HEAD~5..HEAD)" = "$want" ]
  [[ "$(hist b HEAD~5..HEAD)" == *"[wip] tool and other"* ]]
  [ "$(git -C "$S/b" log -5 --format='%at %ct' | awk '$1 != $2')" = "" ]
  [ "$(tree b packages/tool)" = "$t0" ]
  [ "$(git -C "$S/b" show HEAD:packages/tool/home/dos.txt | od -c | grep -c '\\r')" -ge 1 ]
  [ -x "$S/b/packages/tool/home/run" ] && [ -L "$S/b/packages/tool/home/link" ]
  [ -z "$(git -C "$S/b" log --format=%h -- packages/other)" ]
  [ ! -e "$S/a/packages/tool" ]
  [ "$(git -C "$S/a" log -1 --format=%s)" = "packages/tool: moved to b (replay, $(git -C "$S/b" rev-parse --short HEAD))" ]
  [ "$(git -C "$S/a" log -1 --format=%h --name-only | sed 1,2d | grep -vc '^packages/tool/')" = 0 ]
  clean a && clean b
  [ "$(git -C "$T/remotes/a.git" rev-parse main)" = "$ra" ]
  [ "$(git -C "$T/remotes/b.git" rev-parse main)" = "$rb" ]
}

@test "a history with two branches deleting the same file, merged, is copied in one commit naming its origin" {
  src a b
  put a packages/tool/package.yml "version: 0.1.0"
  put a packages/tool/home/x
  put a packages/tool/home/y
  commit a alice "1700000000 +0000" "tool"
  git -C "$S/a" checkout -q -b side
  git -C "$S/a" rm -q packages/tool/home/x
  put a packages/tool/home/z side
  commit a alice "1700000100 +0000" "drop x on a side"
  git -C "$S/a" checkout -q main
  git -C "$S/a" rm -q packages/tool/home/x
  put a packages/tool/home/y changed
  commit a bob "1700000200 +0000" "drop x on main"
  git -C "$S/a" merge -q --no-edit side
  local t0 sha n
  t0=$(tree a packages/tool) sha=$(git -C "$S/a" rev-parse HEAD) n=$(git -C "$S/b" rev-list --count HEAD)

  anfs_move_tree packages a/tool b > "$T/out"
  [ "$ANFS_MOVE_METHOD" = copy ]
  [[ "$ANFS_MOVE_WHY" == "git am failed: "* ]]
  [ "$(git -C "$S/b" rev-list --count HEAD)" = $((n + 1)) ]
  [ "$(tree b packages/tool)" = "$t0" ]
  run git -C "$S/b" log -1 --format=%B
  [[ "$output" == "packages/tool: moved from a"* ]]
  [[ "$output" == *"Copied from a (file://$T/remotes/a.git) at $sha"* ]]
  [[ "$output" == *"git log $sha -- packages/tool"* ]]
  [[ "$(cat "$T/out")" == *"copied in one commit (the replay failed: git am failed"*"its history stays in a" ]]
  [ ! -e "$S/a/.git/rebase-apply" ] && [ ! -e "$S/b/.git/rebase-apply" ]
  [ "$(git -C "$S/a" log -1 --format=%s)" = "packages/tool: moved to b (copy, $(git -C "$S/b" rev-parse --short HEAD))" ]
  clean a && clean b
}

@test "a message holding a diff line is copied; one holding a --- line is caught by the verification" {
  src a b c
  put a packages/tool/package.yml one
  commit a alice "1700000000 +0000" "tool" "see:
diff --git a/x b/x"
  put a packages/tool/package.yml two
  commit a alice "1700000100 +0000" "more"
  anfs_move_tree packages a/tool b > /dev/null
  [ "$ANFS_MOVE_METHOD" = copy ]
  [[ "$ANFS_MOVE_WHY" == "git am failed: "* ]]
  [ "$(git -C "$S/b" log --format=%s | head -1)" = "packages/tool: moved from a" ]

  put b packages/dash/package.yml one
  commit b alice "1700000000 +0000" "dash" "a body

---
cut here"
  run anfs_move_tree -n packages b/dash c
  [[ "$output" == *"replay"$'\t'"would copy: the replay changed the message: "*" dash"* ]]
  anfs_move_tree packages b/dash c > /dev/null
  [ "$ANFS_MOVE_METHOD" = copy ]
  [[ "$ANFS_MOVE_WHY" == "the replay changed the message: "*" dash" ]]
  [[ "$(git -C "$S/c" log -1 --format=%B)" == *"The history was not replayed: the replay changed the message"* ]]
  [ -z "$(git -C "$S/c" log --format=%s | grep -x dash || true)" ]
}

@test "the real am failing after a good trial: the destination back at its HEAD, no rebase-apply, then a copy" {
  five
  local head real
  head=$(git -C "$S/b" rev-parse HEAD) real=$(command -v git)
  mkdir -p "$T/bin"
  # the second am applies its first patch twice: one commit in, then a failure that leaves
  # rebase-apply behind
  cat > "$T/bin/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [[ "\$a" == am ]]; then
    n=\$(( \$(cat "$T/ams" 2>/dev/null || echo 0) + 1 )); echo \$n > "$T/ams"
    if [[ \$n == 2 ]]; then
      args=() first=""
      for x in "\$@"; do
        if [[ "\$x" == *.patch ]]; then [[ -n "\$first" ]] || first="\$x"; else args+=("\$x"); fi
      done
      exec "$real" "\${args[@]}" "\$first" "\$first"
    fi
  fi
done
exec "$real" "\$@"
EOF
  chmod +x "$T/bin/git"
  PATH="$T/bin:$PATH"
  hash -r
  anfs_move_tree packages a/tool b > /dev/null
  [ "$(cat "$T/ams")" -ge 2 ]  # the trial, the real one (then its --abort)
  [ "$ANFS_MOVE_METHOD" = copy ]
  [[ "$ANFS_MOVE_WHY" == "git am failed in b: "* ]]
  [ ! -e "$S/b/.git/rebase-apply" ]
  [ "$(git -C "$S/b" rev-parse HEAD~1)" = "$head" ]
  clean a && clean b
}

@test "a destination pre-applypatch hook that refuses does not stop a replay" {
  five
  printf '#!/bin/sh\nexit 1\n' > "$S/b/.git/hooks/pre-applypatch"
  chmod +x "$S/b/.git/hooks/pre-applypatch"
  anfs_move_tree packages a/tool b > /dev/null
  [ "$ANFS_MOVE_METHOD" = replay ]
}

@test "dirty elsewhere: refused naming both, -f goes past and commits only the path" {
  five
  put a stray
  put b packages/x/package.yml
  git -C "$S/b" add packages/x/package.yml && git -C "$S/b" commit -qm x
  put b packages/x/package.yml changed
  run anfs_move_check packages a/tool b deps
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"$'\t'"repository"$'\t'"uncommitted changes in a: ?? stray"* ]]
  [[ "$output" == *"refused"$'\t'"repository"$'\t'"uncommitted changes in b:  M packages/x/package.yml"* ]]
  run anfs_move_check -f packages a/tool b deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"forced"$'\t'"repository"* ]]

  anfs_move_tree packages a/tool b > /dev/null
  [ "$ANFS_MOVE_METHOD" = replay ]
  [ "$(git -C "$S/a" status --porcelain)" = "?? stray" ]
  [ "$(git -C "$S/b" status --porcelain)" = " M packages/x/package.yml" ]
  [ -z "$(git -C "$S/b" log -5 --name-only --format= | grep -v '^packages/tool/' | grep . || true)" ]
}

@test "a staged change in the destination under -f: a copy, said; a change inside the path: never" {
  five
  put b staged
  git -C "$S/b" add staged
  anfs_move_tree packages a/tool b > /dev/null
  [ "$ANFS_MOVE_METHOD" = copy ]
  [ "$ANFS_MOVE_WHY" = "b has staged changes (git am needs a clean index)" ]
  [ "$(git -C "$S/b" status --porcelain)" = "A  staged" ]

  five_again() { put b packages/new/package.yml; commit b bob "1700000000 +0000" new; }
  five_again
  put b packages/new/extra
  run anfs_move_check packages b/new a
  [ "$status" -eq 2 ]
  [[ "$output" == *"refused"$'\t'"package"$'\t'"uncommitted changes in b/packages/new (?? packages/new/extra)"* ]]
  run anfs_move_check -f packages b/new a
  [ "$status" -eq 2 ]
}

@test "the path taken in the destination, by a directory, a tracked file or a file on the way: never, nothing changed" {
  five
  local before
  mkdir -p "$S/b/packages/tool"
  before=$(state a b)
  run anfs_move_check -f packages a/tool b
  [ "$status" -eq 2 ]
  [[ "$output" == *"refused"$'\t'"destination"$'\t'"b already has packages/tool"* ]]
  [ "$(state a b)" = "$before" ]
  rm -r "$S/b/packages"

  printf x > "$S/b/packages"
  run anfs_move_check -f packages a/tool b
  [ "$status" -eq 2 ]
  [[ "$output" == *"b has a file on the way: packages"* ]]
  rm "$S/b/packages"

  put b packages/tool x
  git -C "$S/b" add packages/tool && git -C "$S/b" commit -qm f && git -C "$S/b" rm -q --cached packages/tool
  git -C "$S/b" commit -qm "untrack" && git -C "$S/b" add -f packages/tool && rm "$S/b/packages/tool"
  run anfs_move_check -f packages a/tool b
  [ "$status" -eq 2 ]
  [[ "$output" == *"b tracks files at packages/tool"* ]]
}

@test "not a source, not git, the same source, missing, a bare name, a detached HEAD, a rebase: never" {
  five
  run anfs_move_check packages tool b
  [ "$status" -eq 2 ] && [[ "$output" == *"'tool' is not qualified"* ]]
  run anfs_move_check packages a/tool nosuch
  [ "$status" -eq 2 ] && [[ "$output" == *"nosuch is not a configured source (anfs src list)"* ]]
  run anfs_move_check packages a/tool a
  [ "$status" -eq 2 ] && [[ "$output" == *"a/tool is already in a"* ]]
  run anfs_move_check packages a/nope b
  [ "$status" -eq 2 ] && [[ "$output" == *"a has no packages/nope"* ]]
  mkdir -p "$S/plain"
  printf '/x/plain  plain\n' >> "$GITSRC_USER_LIST"
  run anfs_move_check packages a/tool plain
  [ "$status" -eq 2 ] && [[ "$output" == *"plain is a local directory, not a git repository: it has no history to carry"* ]]
  git -C "$S/b" checkout -q --detach
  run anfs_move_check packages a/tool b
  [ "$status" -eq 2 ] && [[ "$output" == *"b: it is on no branch (a detached HEAD"* ]]
  git -C "$S/b" checkout -q main
  mkdir -p "$S/b/.git/rebase-merge"
  run anfs_move_check -f packages a/tool b
  [ "$status" -eq 2 ] && [[ "$output" == *"b: a rebase is in progress"* ]]
}

@test "dependents and dependencies, by position: up hides it from those below; qualified never resolves" {
  src a b c
  put c packages/y/package.yml "version: 1"
  put b packages/x/package.yml "depends: [y]"
  commit c t "1700000000 +0000" y
  commit b t "1700000000 +0000" x
  # a has no packages/ yet: positions still right
  run anfs_move_check packages c/y a deps
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"$'\t'"dependents"$'\t'"b/x depends on y: after the move no source at or below b has it (~/.local/share/anfs/sources/b/packages/x/package.yml)"* ]]
  run anfs_move_check packages c/y b deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"$'\t'"dependents"* ]]

  put b packages/x/package.yml "depends: [c/y]"
  commit b t "1700000000 +0000" qualified
  run anfs_move_check packages c/y b deps
  [ "$status" -eq 1 ]
  [[ "$output" == *"b/x depends on c/y, which names c: it never resolves after the move"* ]]
  run anfs_move_check -f packages c/y b deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"forced"$'\t'"dependents"* ]]

  # its own: z in a needs w, which only b has; moved down to c it loses it
  put b packages/w/package.yml "version: 1"
  put a packages/z/package.yml "depends: [w]"
  commit b t "1700000000 +0000" w
  commit a t "1700000000 +0000" z
  run anfs_move_check packages a/z c deps
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"$'\t'"dependencies"$'\t'"a/z depends on w, which does not resolve from c down"* ]]
  run anfs_move_check packages a/z b deps
  [ "$status" -eq 0 ]
}

@test "layers: the order before and after is a note" {
  src a b c
  put a packages/git/package.yml one
  put c packages/git/package.yml two
  commit a t "1700000000 +0000" a
  commit c t "1700000000 +0000" c
  run anfs_move_check packages c/git b deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"note"$'\t'"layers"$'\t'"git: a, c -> a, b"* ]]
}

@test "nested: a space and the one under it move as one; a dependent on the inner one is found" {
  src a b
  ANFS_NAME_NEST=true ANFS_RESOLVE_MARKER=space.yml ANFS_RESOLVE_FIRST=true
  sdeps() { yq -r '.depends[]?' "$1/space.yml" 2>/dev/null || true; }
  put a spaces/space.yml "{}"
  put a spaces/tech/web/space.yml "{}"
  put a spaces/tech/web/api/space.yml "{}"
  put a spaces/tech/web/api/notes.md
  put a spaces/ops/space.yml "depends: [a/tech/web/api]"
  commit a t "1700000000 +0000" spaces
  run anfs_move_check spaces a/tech/web b sdeps
  [ "$status" -eq 1 ]
  [[ "$output" == *"a/ops depends on a/tech/web/api, which names a: it never resolves after the move (~/.local/share/anfs/sources/a/spaces/ops/space.yml)"* ]]
  anfs_move_tree spaces a/tech/web b > /dev/null
  [ "$ANFS_MOVE_METHOD" = replay ]
  [ -f "$S/b/spaces/tech/web/api/notes.md" ] && [ -f "$S/b/spaces/tech/web/space.yml" ]
  [ ! -e "$S/a/spaces/tech" ]
  run anfs_move_check spaces a b sdeps
  [ "$status" -eq 2 ] && [[ "$output" == *"'a' is not qualified"* ]]
}

@test "a stack that names it, as a string or a map key: refused, the file named" {
  src a b
  put a packages/tool/package.yml one
  put b stacks/s/stack.yml "packages: [a/tool, x]"
  put a stacks/m/stack.yml "packages:
  - a/tool: {}"
  commit a t "1700000000 +0000" a
  commit b t "1700000000 +0000" b
  run anfs_move_check packages a/tool b
  [ "$status" -eq 1 ]
  [[ "$output" == *"refused"$'\t'"stacks"$'\t'"~/.local/share/anfs/sources/b/stacks/s/stack.yml names a/tool"* ]]
  [[ "$output" == *"sources/a/stacks/m/stack.yml names a/tool"* ]]
}

@test "ignored files go with it; nothing is left at the origin's path" {
  five
  echo .DS_Store > "$S/a/.gitignore" && echo .DS_Store > "$S/b/.gitignore"
  commit a t "1700000000 +0000" ignore
  commit b t "1700000000 +0000" ignore
  touch "$S/a/packages/tool/home/.DS_Store"
  anfs_move_tree packages a/tool b > /dev/null
  [ -f "$S/b/packages/tool/home/.DS_Store" ]
  [ ! -e "$S/a/packages/tool" ]
  clean a && clean b
}

@test "a hook that refuses the origin's commit: both back as they were, 1" {
  five
  local before
  before=$(state a b)
  printf '#!/bin/sh\nexit 1\n' > "$S/a/.git/hooks/pre-commit"
  chmod +x "$S/a/.git/hooks/pre-commit"
  run anfs_move_tree packages a/tool b
  [ "$status" -eq 1 ]
  [[ "$output" == *"the commit in a failed"* ]]
  [ "$(state a b)" = "$before" ]
}

@test "-n: the checks, the commits and whether the replay works; nothing changes" {
  five
  local before
  before=$(state a b)
  run anfs_move_check packages a/tool b deps
  [ "$status" -eq 0 ]
  [[ "$output" == "ok"$'\t'"package"$'\t'"a/packages/tool"* ]]
  [[ "$output" == *"note"$'\t'"commits"$'\t'"one or more in b (on main), one in a (on main); nothing is pushed" ]]
  run anfs_move_tree -n packages a/tool b
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "commits"$'\t'"5 to replay from a" ]
  [[ "${lines[1]}" == "  "*" 2023-11-14 alice tool: first" ]]
  [ "${lines[6]}" = "replay"$'\t'"ok" ]
  [ "$(state a b)" = "$before" ]
}

@test "anfs_move_cli declares move with -f and -n, the tool's kind and a source" {
  cli_cmd() { printf '%s\n' "$@"; }
  run anfs_move_cli package package
  [ "${lines[0]}" = move ]
  [[ "$output" == *"--opt"$'\n'"-f --force: "* ]]
  [[ "$output" == *"--opt"$'\n'"-n --dry-run: "* ]]
  [[ "$output" == *"--arg"$'\n'"package"$'\n'"--arg"$'\n'"source" ]]
}
