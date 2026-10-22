#!/usr/bin/env bash
# anfs_repo_* — one git clone at one path: name it, clone it, read its state, pull it, switch its
# origin to ssh. `anfs src` (sources.sh) and `wsm repo` both use it; policy is theirs (sources pull
# on a TTL and skip a dirty clone; space repositories are never pulled). sources.sh loads it.
#
# Like everything in lib/anfs/ it only defines functions, depends on no tool, and is safe under
# `set -euo pipefail`. Written for the bash floor (5.2, see bash.sh); not in the bootstrap set
# (install.sh clones core with its own git clone before any library exists). It prints nothing of
# its own: messages are the caller's, and only git speaks, on error.

# The directory git clone would make for <url>, into REPLY: its last part, without a trailing /
# or .git (git@host:org/app.git, https://host/org/app/, /srv/app.git, host:app: app). Empty when
# it has none. No fork, for loops over many entries.
anfs_repo_name_reply() {
  local n="${1%/}"
  n="${n%.git}" n="${n%/}"
  n="${n##*/}" n="${n##*:}"
  REPLY=""
  [[ -z "$n" || "$n" == . || "$n" == .. ]] || REPLY="$n"
}

# anfs_repo_name_reply, printed; nothing when the URL names no directory
anfs_repo_name() {
  anfs_repo_name_reply "$1"
  [[ -z "$REPLY" ]] || printf '%s\n' "$REPLY"
}

# Clone <url> into <dir> (quiet), then check out [ref]: a branch, tag or SHA (after the clone, not
# --branch, so a SHA works). 2 when <dir> exists, untouched; 1 when the clone or the checkout
# fails, and nothing is left at <dir>.
anfs_repo_clone() {
  local url="$1" dir="$2" ref="${3:-}"
  [[ ! -e "$dir" && ! -L "$dir" ]] || return 2
  mkdir -p "$(dirname "$dir")" || return 1
  if ! git clone -q -- "$url" "$dir" ||
     { [[ -n "$ref" ]] && ! git -C "$dir" checkout -q "$ref" --; }; then
    rm -rf -- "$dir"
    return 1
  fi
}

# Commits a clone has that its upstream lacks, as of the last fetch; nothing for no upstream
anfs_repo_ahead() {
  git -C "$1" rev-list --count '@{upstream}..HEAD' 2>/dev/null || true
}

# True when the clone has uncommitted (staged or not) or untracked changes
anfs_repo_dirty() {
  [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]
}

# State of a directory: clean, dirty (uncommitted or untracked changes), unpushed (commits its
# upstream does not have, as of the last fetch), no upstream (a branch that tracks none, or no
# branch), "dirty, unpushed", "dirty, no upstream", local (exists, not a git repo) or missing.
# Reads only the clone: no fetch.
anfs_repo_status() {
  local dir="$1" dirty="" push="" ahead
  if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
    ! anfs_repo_dirty "$dir" || dirty=dirty
    if ! ahead=$(git -C "$dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null); then
      push="no upstream"
    elif (( ahead > 0 )); then
      push=unpushed
    fi
    if [[ -n "$dirty" && -n "$push" ]]; then echo "$dirty, $push"
    elif [[ -n "$dirty$push" ]]; then echo "$dirty$push"
    else echo clean
    fi
  elif [[ -d "$dir" ]]; then
    echo local
  else
    echo missing
  fi
}

# Pull the clone at <dir> (quiet). 2 without pulling when it is dirty; 1 when the pull fails (no
# upstream, unreachable, a conflict).
anfs_repo_update() {
  ! anfs_repo_dirty "$1" || return 2
  git -C "$1" pull -q
}

# https://github.com/<x> -> git@github.com:<x>; any other URL unchanged
anfs_repo_ssh_url() {
  if [[ "$1" == https://github.com/* ]]; then
    printf 'git@github.com:%s\n' "${1#https://github.com/}"
  else
    printf '%s\n' "$1"
  fi
}

# Switch the origin of the clone at <dir> from GitHub https to ssh, and print the new URL. 1 when
# there was nothing to switch (no clone, no origin, or an origin that is not GitHub https).
anfs_repo_ssh() {
  local remote new
  remote=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  [[ "$remote" == https://github.com/* ]] || return 1
  new=$(anfs_repo_ssh_url "$remote")
  git -C "$1" remote set-url origin "$new" || return 1
  printf '%s\n' "$new"
}
