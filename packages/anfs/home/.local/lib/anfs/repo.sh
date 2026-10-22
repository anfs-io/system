#!/usr/bin/env bash
# anfs_repo_* — one git clone at one path: name it, clone it, read its state, pull it, switch its
# origin to ssh. `anfs src` (sources.sh) and `wsm repo` both use it; policy is theirs (sources pull
# on a TTL and skip a dirty clone; space repositories are never pulled). sources.sh loads it.
#
# Like everything in lib/anfs/ it only defines functions, depends on no tool, and is safe under
# `set -euo pipefail`. Written for the bash floor (5.2, see bash.sh); not in the bootstrap set
# (install.sh clones core with its own git clone before any library exists). It prints nothing of
# its own: messages are the caller's, and only git speaks, on error. The one exception is the last
# section, anfs_repo_push_cli: the `push` command `anfs src push` and `wsm repo push` share, which
# prints a list and so needs what every tool has loaded (cli.sh, table.sh, log.sh).

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

# Push the current branch of the clone at <dir> to its upstream: plain `git push` (quiet), never
# forced, never --set-upstream, tags only as the repo's config says. With -n, only find out.
# ANFS_REPO_BRANCH, ANFS_REPO_UPSTREAM and ANFS_REPO_AHEAD hold what was found (empty when not).
# 0 pushed (with -n: would be); 1 git failed (non-fast-forward, auth, unreachable), with git's first
# error line in REPLY; 2 nothing ahead (as of the last fetch: nothing is fetched); 3 no upstream;
# 4 a detached HEAD; 5 not a clone.
anfs_repo_push() {
  local dir="$1" dry=false err line
  local -a w
  [[ "${2:-}" != -n ]] || dry=true
  ANFS_REPO_BRANCH="" ANFS_REPO_UPSTREAM="" ANFS_REPO_AHEAD="" REPLY=""
  [[ -n "$dir" && ( -d "$dir/.git" || -f "$dir/.git" ) ]] || return 5
  ANFS_REPO_BRANCH=$(git -C "$dir" symbolic-ref -q --short HEAD) || return 4
  ANFS_REPO_UPSTREAM=$(git -C "$dir" rev-parse -q --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) ||
    { ANFS_REPO_UPSTREAM=""; return 3; }
  ANFS_REPO_AHEAD=$(anfs_repo_ahead "$dir")
  (( ${ANFS_REPO_AHEAD:-0} > 0 )) || return 2
  ! $dry || return 0
  err=$(git -C "$dir" push -q 2>&1 >/dev/null) && return 0
  while IFS= read -r line; do
    case "$line" in
      " ! "*|error:*|fatal:*|ERROR:*|"remote: error"*) read -ra w <<< "$line"; REPLY="${w[*]}"; break ;;
    esac
  done <<< "$err"
  if [[ -z "$REPLY" ]]; then
    while IFS= read -r line; do [[ -z "$line" ]] || { REPLY="$line"; break; }; done <<< "$err"
  fi
  REPLY="${REPLY:-git push failed}"
  return 1
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

# --- push, the command: `anfs src push` and `wsm repo push` ----------------------------------------

# `<tool> ... push [name...] [--all] [-n]`. The caller fills ANFS_PUSH_IDS (every repo it has, in
# its list's order, named as its list names it) and ANFS_PUSH_DIRS (each one's clone; empty when
# it has none), and passes its kind (source, repository), its list command (for messages) and
# the names typed; --all and -n are CLI_OPT's. Names are resolved before anything is pushed. One
# row per repo (<KIND> STATUS BRANCH UPSTREAM; commits and error in --json only); every one is
# tried, and it returns 1 when any was not pushed (no upstream, detached, rejected, not cloned).
ANFS_PUSH_IDS=() ANFS_PUSH_DIRS=()
anfs_repo_push_cli() {
  local kind="$1" listcmd="$2" all=${CLI_OPT[all]:-false} dry=${CLI_OPT[dry-run]:-false}
  shift 2
  local plural="${kind}s" i j name status rc err failed=false rows="" ahead="" n
  local -a pick=()
  [[ "$kind" != *y ]] || plural="${kind%y}ies"

  if [[ $# -gt 0 ]]; then
    ! $all || cli_usage_err "names or --all, not both"
    for name in "$@"; do
      j=""
      for i in "${!ANFS_PUSH_IDS[@]}"; do
        [[ "${ANFS_PUSH_IDS[$i]}" == "$name" ]] && { j=$i; break; }
      done
      [[ -n "$j" ]] || anfs_fail 1 "no $kind '$name' ($listcmd)"
      [[ " ${pick[*]-} " == *" $j "* ]] || pick+=("$j")
    done
  else
    for i in "${!ANFS_PUSH_IDS[@]}"; do
      [[ -n "${ANFS_PUSH_DIRS[$i]}" ]] || continue
      n=$(anfs_repo_ahead "${ANFS_PUSH_DIRS[$i]}")
      (( ${n:-0} > 0 )) || continue
      pick+=("$i")
      ahead+="${ahead:+, }${ANFS_PUSH_IDS[$i]}"
    done
    if ! $all; then
      if [[ -n "$ahead" ]]; then
        cli_usage_err "name the $plural to push, or --all for every one ahead of its upstream: $ahead"
      else
        cli_usage_err "name the $plural to push, or --all (none is ahead of its upstream)"
      fi
    fi
    if [[ ${#pick[@]} -eq 0 ]]; then
      if anfs_json_on; then echo '[]'; else echo "Nothing to push: no $kind is ahead of its upstream"; fi
      return 0
    fi
  fi

  for i in "${pick[@]}"; do
    rc=0
    if $dry; then anfs_repo_push "${ANFS_PUSH_DIRS[$i]}" -n || rc=$?
    else anfs_repo_push "${ANFS_PUSH_DIRS[$i]}" || rc=$?
    fi
    err="$REPLY"
    case $rc in
      0) if $dry; then status="would push $ANFS_REPO_AHEAD"; else status="pushed $ANFS_REPO_AHEAD"; fi
         ! anfs_repo_dirty "${ANFS_PUSH_DIRS[$i]}" || status+=" (uncommitted changes left)" ;;
      1) status=rejected
         anfs_warn "${ANFS_PUSH_IDS[$i]}: rejected: $err" ;;
      2) status="up to date" ;;
      3) status="no upstream" ;;
      4) status=detached ;;
      *) status="not cloned" ;;
    esac
    [[ $rc -eq 0 || $rc -eq 2 ]] || failed=true
    rows+=$(anfs_row "${ANFS_PUSH_IDS[$i]}" "$status" "$ANFS_REPO_BRANCH" "$ANFS_REPO_UPSTREAM" \
      "$ANFS_REPO_AHEAD" "$([[ $rc -ne 1 ]] || printf '%s' "$err")")$'\n'
  done
  printf '%s' "$rows" | anfs_table "${kind^^} STATUS BRANCH UPSTREAM" "$kind status branch upstream commits error"
  ! $failed
}
