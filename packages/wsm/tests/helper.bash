# Shared setup for wsm's tests.
#
# Every test runs the script straight out of the package, with HOME, XDG_STATE_HOME and
# WSM_SPACES_HOME inside the per-test temp directory, so nothing reaches the real home.

wsm_setup() {
  WSM="$BATS_TEST_DIRNAME/../home/.local/bin/wsm"
  mkdir -p "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/state"
  # BATS_TEST_TMPDIR sits under /var on macOS, which is a symlink to /private/var. wsm
  # canonicalizes the targets it stores, so HOME has to be canonical too or nothing compares equal.
  HOME=$(cd "$BATS_TEST_TMPDIR/home" && pwd -P)
  XDG_STATE_HOME=$(cd "$BATS_TEST_TMPDIR/state" && pwd -P)
  # The rest of XDG under the test HOME, so anfs's paths never reach the real ones
  XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
  unset ANFS_CONFIG_HOME ANFS_DATA_HOME ANFS_CACHE_HOME ANFS_STATE_HOME
  unset WSM_CONFIG_HOME WSM_DATA_HOME WSM_STATE_HOME WSM_CACHE_HOME
  unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)
  WSM_SPACES_HOME="$HOME/spaces"
  export HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME WSM_SPACES_HOME
  export ANFS_LOG=off   # no log file from tests (lib/anfs/log.sh)
  export ANFS_EVENTS=off   # no event log either (lib/anfs/events.sh); a test about events turns it on
  WSM_STATE="$XDG_STATE_HOME/wsm"
  # anfs's libraries, where wsm looks for them
  mkdir -p "$HOME/.local/lib"
  ln -s "$(cd "$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs" && pwd)" "$HOME/.local/lib/anfs"
  cd "$HOME" || return 1
}

wsm() { "$WSM" "$@"; }

# A bare repo under $BATS_TEST_TMPDIR/bare, cloneable over file://. Prints its path.
# Usage: mkbare <name> [extra-branch]
mkbare() {
  local name="$1" branch="${2:-}" work="$BATS_TEST_TMPDIR/src/$1"
  mkdir -p "$work" "$BATS_TEST_TMPDIR/bare"
  git -C "$work" init -q
  git -C "$work" config user.email t@t
  git -C "$work" config user.name tester
  echo "$name" > "$work/README"
  git -C "$work" add -A
  git -C "$work" commit -q -m "init $name"
  if [[ -n "$branch" ]]; then
    git -C "$work" checkout -q -b "$branch"
    echo "on $branch" > "$work/BRANCH"
    git -C "$work" add -A
    git -C "$work" commit -q -m "$branch"
    git -C "$work" checkout -q -
  fi
  git clone -q --bare "$work" "$BATS_TEST_TMPDIR/bare/$name.git"
  printf '%s\n' "$BATS_TEST_TMPDIR/bare/$name.git"
}

# An anfs source <alias> (a local directory) registered in the test HOME's user.list and linked
# into the sources dir. Prints its path.
# Usage: mksource <alias>
mksource() {
  local dir="$BATS_TEST_TMPDIR/srcs/$1"
  mkdir -p "$dir/spaces" "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources"
  ln -sfn "$dir" "$HOME/.local/share/anfs/sources/$1"
  printf '%s  %s\n' "$dir" "$1" >> "$HOME/.config/anfs/user.list"
  printf '%s\n' "$dir"
}

# Write a space definition, <source>/spaces/<path>/space.yml (any depth; an empty path is the
# source's root space), from stdin. It gets a fresh id: line first (a {} body becomes the id
# alone), as wsm new writes one, unless the body has one or NOID=1.
# Usage: space_def <source> [path]  < body
space_def() {
  local d="$BATS_TEST_TMPDIR/srcs/$1/spaces${2:+/$2}" body id
  mkdir -p "$d"
  body=$(cat)
  if [[ "${NOID:-}" != 1 ]] && ! grep -q '^id:' <<< "$body"; then
    id=$(LC_ALL=C tr -dc 'a-z2-7' < /dev/urandom | head -c 10 || true)
    if [[ "$body" == "{}" ]]; then body="id: $id"; else body="id: $id"$'\n'"$body"; fi
  fi
  printf '%s\n' "$body" > "$d/space.yml"
}

# Any other file below a source's spaces/: <source> <path> [content]
space_file() {
  mkdir -p "$(dirname "$BATS_TEST_TMPDIR/srcs/$1/spaces/$2")"
  printf '%s\n' "${3:-$2}" > "$BATS_TEST_TMPDIR/srcs/$1/spaces/$2"
}

# The installed spaces, as wsm ls says (status not null), one id per line
installed() { wsm ls --json 2>/dev/null | yq -p json -r '.[] | select(.status != null and .status != "not in the source") | .space'; }

# The number of installed spaces
ninstalled() { installed | grep -c . || true; }

# A column of `wsm ls` for one space: ls_field <id> <key>
ls_field() { wsm ls --json 2>/dev/null | yq -p json -r ".[] | select(.space == \"$1\") | .$2"; }
