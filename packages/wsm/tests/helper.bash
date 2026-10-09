# Shared setup for wsm's tests.
#
# Every test runs the script straight out of the package, with HOME and XDG_STATE_HOME inside
# the per-test temp directory, so nothing reaches the real trackers or the real home.

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
  unset WSM_CONFIG_HOME WSM_DATA_HOME WSM_STATE_HOME WSM_CACHE_HOME WSM_SPACES_HOME
  export HOME XDG_STATE_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
  TRACKERS="$XDG_STATE_HOME/wsm/installed"
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

# Write a space definition, <source>/spaces/<ws>/<space>/space.yml, from stdin
# Usage: space_def <source> <ws>/<space>  < body
space_def() {
  mkdir -p "$BATS_TEST_TMPDIR/srcs/$1/spaces/$2"
  cat > "$BATS_TEST_TMPDIR/srcs/$1/spaces/$2/space.yml"
}

# Any other file in a space: <source> <ws>/<space>/<path> [content]
space_file() {
  mkdir -p "$(dirname "$BATS_TEST_TMPDIR/srcs/$1/spaces/$2")"
  printf '%s\n' "${3:-$2}" > "$BATS_TEST_TMPDIR/srcs/$1/spaces/$2"
}

# Number of installed spaces (space trackers: <src>/<ws>/<space>.yml)
installed() { find "$TRACKERS" -mindepth 3 -name '*.yml' 2>/dev/null | grep -c . || true; }
