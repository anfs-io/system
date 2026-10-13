#!/usr/bin/env bats
# anfs onboard (lib/anfs/onboard.sh, lib/ppm/onboard.sh): the runner, with the real anfs and ppm
# commands in a temp $HOME. The steps come from a fixture source (demo) whose packages declare
# them the way any package does; `ppm install` is stubbed (it records the package as installed and
# links user.list), `ppm __onboard` is the real one. No network.
# The steps real packages bring (git, ssh, op) are tested where they live, in the stack repo.
# Run: bats packages/anfs/tests/

bats_require_minimum_version 1.5.0

setup() {
  local packages="$BATS_TEST_DIRNAME/../.." tools="$BATS_TEST_TMPDIR/tools" t
  ANFS="$packages/anfs/home/.local/bin/anfs"

  export HOME="$BATS_TEST_TMPDIR/home"
  ST="$HOME/stub-state"
  SOURCES="$HOME/.local/share/anfs/sources"
  INSTALLED="$HOME/.local/state/ppm/installed"
  mkdir -p "$HOME/.local/lib" "$HOME/.local/bin" "$HOME/.config/anfs" "$ST" "$tools" "$SOURCES" "$INSTALLED/stack"
  ln -s "$(cd "$packages/anfs/home/.local/lib/anfs" && pwd)" "$HOME/.local/lib/anfs"
  ln -s "$(cd "$packages/ppm/home/.local/lib/ppm" && pwd)" "$HOME/.local/lib/ppm"

  # Only bash (the floor) and yq from wherever they are; the rest from the system dirs
  for t in bash yq; do ln -s "$(command -v "$t")" "$tools/$t"; done
  # ppm puts Homebrew on PATH when brew is not there (brew_env), and with it whatever is
  # installed: a brew that is found keeps the PATH as it is
  printf '#!/bin/sh\nexit 0\n' > "$tools/brew"
  chmod +x "$tools/brew"
  export PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin"

  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_JSON
  export ANFS_LOG=off ANFS_TABLE=tsv GIT_CONFIG_NOSYSTEM=1

  printf '# Your anfs sources\n' > "$HOME/.config/anfs/user.list"
  echo "$SOURCES/demo  demo" > "$HOME/.config/anfs/system.list"
  # The shell row reads the login shell of whoever runs the tests: say its package is installed
  for t in bash zsh fish sh dash; do touch "$INSTALLED/stack/$t.yml"; done

  USER_REPO="$SOURCES/user"
  PPMLOG="$ST/ppm.log"
  : > "$PPMLOG"

  # ppm: the real one for the plumbing; install only records, and links user.list the way stow would
  cat > "$HOME/.local/bin/ppm" <<SH
#!/bin/bash
if [ "\$1" = __onboard ]; then exec "$packages/ppm/home/.local/bin/ppm" "\$@"; fi
echo "\$*" >> "$PPMLOG"
[ "\$1" = install ] || exit 0
shift
for arg in "\$@"; do
  case "\$arg" in -*) continue ;; esac
  mkdir -p "$INSTALLED/\${arg%%/*}"
  touch "$INSTALLED/\$arg.yml"
  [ "\$arg" != user/anfs ] || ln -sf "$SOURCES/user/packages/anfs/home/.config/anfs/user.list" "$HOME/.config/anfs/user.list"
done
SH
  chmod +x "$HOME/.local/bin/ppm"

  # demo/alpha: one step before repo and one after it, which reads what the first one found
  package alpha <<'YML'
version: 0.1.0
onboard:
  offer: "Alpha, the first one"
  steps:
    - name: first
      summary: Pick a color
      before: [repo]
    - name: last-one
      after: [repo]
  options:
    - "--color COLOR: Your color"
YML
  cat > "$SOURCES/demo/packages/alpha/install.sh" <<'SH'
onboard_first_detect() {
  [[ -f "$HOME/first.done" ]] || { onboard_detail "no color yet"; return 1; }
  onboard_set color "$(cat "$HOME/first.done")"
  onboard_detail "color $(cat "$HOME/first.done")"
}
onboard_first() {
  ! onboard_first_detect || return 0
  onboard_ask color "Your color"
  echo "$REPLY" > "$HOME/first.done"
  onboard_first_detect
}
onboard_last_one_detect() {
  onboard_detail "saw $(onboard_get color), repo $(onboard_user_repo)"
  [[ -f "$HOME/last.done" ]]
}
onboard_last_one() {
  ! onboard_last_one_detect || return 0
  onboard_propose "Finish" || return 1
  touch "$HOME/last.done"
  onboard_last_one_detect
}
SH

  # demo/beta: a step that places itself between alpha's first and repo
  package beta <<'YML'
version: 0.1.0
onboard:
  offer: "Beta"
  steps:
    - name: mid
      after: [first, not-a-step]
      before: [repo]
YML
  cat > "$SOURCES/demo/packages/beta/install.sh" <<'SH'
onboard_mid_detect() { onboard_state optional; onboard_detail "up to you"; return 1; }
onboard_mid() { onboard_mid_detect; }
SH

  # demo/plain: a package that takes no part
  package plain <<'YML'
version: 0.1.0
YML
}

package() {
  mkdir -p "$SOURCES/demo/packages/$1"
  cat > "$SOURCES/demo/packages/$1/package.yml"
}

onboard() { run "$ANFS" onboard "$@" </dev/null; }

# One column of a step's row: 2 package, 3 state, 4 detail
col() { awk -F'\t' -v s="$1" -v c="$2" '$1 == s { print $c }' <<< "$output"; }
state() { col "$1" 3; }
# The steps in the order the table lists them
order() { awk -F'\t' 'NF >= 3 && $3 ~ /^(ok|todo|optional|skip|n\/a)$/ { printf "%s ", $1 }' <<< "$output"; }

@test "--check on a bare home: what is on offer, the repo to do, nothing run or changed" {
  onboard --check
  [ "$status" -eq 1 ]
  [ "$(state packages)" = optional ]
  [[ "$(col packages 4)" == "on offer: demo/alpha demo/beta (--install)" ]]
  [ "$(state repo)" = todo ]
  [ "$(order)" = "shell packages repo " ]
  [ ! -s "$PPMLOG" ]
  [ ! -e "$USER_REPO" ]
}

@test "an installed package's steps join the walk, ordered by before and after" {
  onboard -y --install all --color red --repo local
  [ "$status" -eq 0 ]
  grep -qx "install demo/alpha demo/beta" "$PPMLOG"
  # The steps of what was just installed ran in this same walk
  [ "$(order)" = "shell packages first mid repo last-one " ]
  [ "$(col first 2)" = demo/alpha ]
  [ "$(col mid 2)" = demo/beta ]
  [ "$(cat "$HOME/first.done")" = red ]
  [ -f "$HOME/last.done" ]
}

@test "what one step finds, a later one reads; and anfs's repo is there for those after it" {
  onboard -y --install alpha --color red --repo local
  [ "$status" -eq 0 ]
  [ "$(col last-one 4)" = "saw red, repo $USER_REPO" ]
  [ "$(state packages)" = optional ]      # beta is still on offer: not something to do
}

@test "an option is known before the package that declares it is installed" {
  onboard -y --install alpha --color red first
  [ "$(cat "$HOME/first.done")" = red ]
}

@test "an option no package declares is a usage error" {
  onboard -y --flavor mint
  [ "$status" -eq 64 ]
}

@test "-y alone installs nothing that is on offer" {
  onboard -y --repo local
  [ "$status" -eq 0 ]
  ! grep -q "^install demo/" "$PPMLOG"
  [ "$(order)" = "shell packages repo " ]
}

@test "a step's question no option answered ends the walk as a usage error" {
  onboard -y --install alpha --repo local
  [ "$status" -eq 64 ]
  [[ "$output" == *"--color"* ]]
  [ ! -e "$HOME/first.done" ]
  [ ! -e "$USER_REPO" ]                   # the walk stopped before repo
}

@test "named steps: only those change anything, the others are still looked at" {
  touch "$INSTALLED/demo/alpha.yml" 2>/dev/null || { mkdir -p "$INSTALLED/demo"; touch "$INSTALLED/demo/alpha.yml"; }
  echo blue > "$HOME/first.done"
  onboard -y --repo local last-one
  [ "$status" -eq 1 ]                     # repo was not named, so it is still to do
  [ -f "$HOME/last.done" ]
  [ "$(col last-one 4)" = "saw blue, repo " ]
  [ ! -e "$USER_REPO" ]
}

@test "a rerun does nothing" {
  onboard -y --install alpha --color red --repo local
  [ "$status" -eq 0 ]
  cp "$PPMLOG" "$ST/ppm.before"
  onboard -y
  [ "$status" -eq 0 ]
  cmp "$PPMLOG" "$ST/ppm.before"
  [ "$(git -C "$USER_REPO" rev-list --count HEAD)" = 1 ]
}

@test "repo: a local one is a git repo whose anfs package owns user.list, listed first" {
  onboard -y --repo local repo
  [ "$status" -eq 0 ]
  [ -d "$USER_REPO/.git" ]
  [ -L "$HOME/.config/anfs/user.list" ]
  [ "$(head -n 1 "$HOME/.config/anfs/user.list")" = "$USER_REPO  user" ]
  grep -qx "install -f user/anfs" "$PPMLOG"
  [ "$(git -C "$USER_REPO" rev-list --count HEAD)" = 1 ]
  [ -z "$(git -C "$USER_REPO" status --porcelain)" ]
}

@test "repo: --repo <url> lists and clones one you have, and stows its anfs package" {
  local work="$ST/work"
  git init -q --bare "$ST/mine.git"
  git init -q "$work"
  mkdir -p "$work/packages/anfs/home/.config/anfs"
  echo "file://$ST/mine.git  user" > "$work/packages/anfs/home/.config/anfs/user.list"
  git -C "$work" add -A
  git -C "$work" -c user.name=t -c user.email=t@t commit -q -m init
  git -C "$work" push -q "$ST/mine.git" HEAD

  onboard -y --repo "file://$ST/mine.git" repo
  [ "$status" -eq 0 ]
  [ -d "$USER_REPO/packages/anfs" ]
  grep -qx "install -f user/anfs" "$PPMLOG"
  [ "$(col repo 4)" = "file://$ST/mine.git" ]
}

@test "no terminal and no options: the first question is a usage error naming its option" {
  onboard
  [ "$status" -eq 64 ]
  [[ "$output" == *"--repo"* ]]
}

@test "an unknown step is a usage error that lists the steps there are" {
  onboard nonsense
  [ "$status" -eq 64 ]
  [[ "$output" == *"'nonsense' is not a step (packages repo)"* ]]
}

@test "a declared step with no function says so" {
  mkdir -p "$INSTALLED/demo"
  touch "$INSTALLED/demo/alpha.yml"
  echo "# nothing" > "$SOURCES/demo/packages/alpha/install.sh"
  onboard --check
  [ "$status" -eq 70 ]
  [[ "$output" == *"does not define onboard_first_detect"* ]]
}

@test "help lists the options packages declare" {
  run "$ANFS" onboard --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--color"*"Your color"* ]]
  [[ "$output" == *"--install"* ]]
}
