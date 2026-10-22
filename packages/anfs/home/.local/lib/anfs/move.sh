#!/usr/bin/env bash
# anfs: moving a resource to another source, with its history
#
# A move takes a resource's directory, <dir>/<name> (packages/rails, spaces/tech/web), out of one
# source and into another, as commits: its history is replayed into the destination (format-patch,
# then am), or, when the replay does not reproduce it exactly, copied in one commit that names where
# the history stays. Then one commit in the origin removes it. Nothing is ever pushed, and both
# repositories are left clean (or as they were, when the move fails). This is the one place the
# toolkit commits on the person's behalf: history is commits.
#
# The library supplies the building blocks; the tool orchestrates. A tool that has a move writes
# its own cmd_move, which reads top to bottom with its own functions around these three (ppm:
# check, unlink, tree, tracker, relink; wsm: check, tree, the installed directory, relink):
#
#   anfs_move_check [-f] <dir> <id> <to> [deps-fn]   may it move? One line per check:
#                                                     "<state><TAB><check><TAB><detail>", state ok,
#                                                     refused, forced (a refusal -f went past) or
#                                                     note. 0 go on; 1 refused (-f would go on);
#                                                     2 refused whatever the flags
#   anfs_move_tree [-n] <dir> <id> <to>               the directory and its history; -n: the commits
#                                                     that would be replayed, and whether the replay
#                                                     works. Sets ANFS_MOVE_METHOD (replay|copy),
#                                                     ANFS_MOVE_COMMITS, ANFS_MOVE_WHY; 0, or 1 with
#                                                     both repositories as they were
#   anfs_move_cli <noun> <arg-kind>                   declare `move <id> <source>` (-f, -n) for the
#                                                     tool that calls it, beside its own declarations
#
# <dir> is the tool's top-level directory; <id> is <source>/<name>, always qualified (a bare name
# is a layer in every source); <name> may be a path when the tool sets ANFS_NAME_NEST and
# ANFS_RESOLVE_MARKER (wsm: a space and every space under it move together). The path is
# <dir>/<name> in both repositories. deps-fn is the function the tool gives anfs_resolve (it prints
# a resource directory's dependencies). ANFS_MOVE_MANIFEST names the file a dependency is declared
# in, for messages, when there is no marker (ppm: package.yml).
#
# The replay (2026-10-22, on scratch clones of every source: 92 of 93 resources replayed exactly):
#   git format-patch -k --root HEAD -- <path>        every commit that touched the path, cut down
#                                                     to the path; merges are skipped
#   git am -k --keep-cr --whitespace=nowarn --no-3way --committer-date-is-author-date --no-verify
#     -k               a subject starting with [...] keeps it
#     --keep-cr        CRLF files stay CRLF
#     --whitespace=nowarn   no warnings, and no one's apply.whitespace=fix changes the content
#     --no-3way        a patch applies as it is or not at all
#     --committer-date-is-author-date   the dates are the author dates (the committer is whoever
#                      runs the move)
#     --no-verify      no applypatch-msg or pre-applypatch hook: the history was judged where it
#                      was made (the two new commits, the origin's removal and a copy, run the
#                      repository's hooks)
# It is tried first in a scratch repository and verified there (the tree of the path, and every
# commit's author, author date and whole message): a message with a line "---" is cut silently by
# am, a history with merged parallel deletions does not apply linearly. Only a replay known to
# work touches the destination, and it is verified there again. Otherwise: a copy of what is
# committed, in one commit.
#
# Requires sources.sh (after anfs_gitsrc_env), resolve.sh, log.sh and cli.sh (anfs_move_cli), and
# git; yq for the stacks check. Functions only; written for the bash floor (5.2, see bash.sh).

ANFS_MOVE_METHOD="" ANFS_MOVE_COMMITS=0 ANFS_MOVE_WHY=""

# --- Names --------------------------------------------------------------------------------------

# A path for messages, ~ for $HOME
_anfs_move_disp() { local p="$1"; [[ "$p" != "$HOME"/* ]] || p="~/${p#"$HOME"/}"; printf '%s' "$p"; }

# <id> <to> into _AM_FROM, _AM_NAME, _AM_TO, _AM_PATH (<dir>/<name>), _AM_FROM_I and _AM_TO_I (their
# positions in the whole source order, -1 when not configured), _AM_FROM_DIR and _AM_TO_DIR.
# 1 when <id> is not qualified.
_anfs_move_parse() {
  local dir="$1" id="$2" to="${3%/}" i
  _AM_FROM="" _AM_NAME="" _AM_TO="$to" _AM_PATH="" _AM_FROM_I=-1 _AM_TO_I=-1 _AM_FROM_DIR="" _AM_TO_DIR=""
  id="${id%/}"
  [[ "$id" == */* ]] || return 1
  _AM_FROM="${id%%/*}" _AM_NAME="${id#*/}"
  [[ -n "$_AM_FROM" && -n "$_AM_NAME" ]] || return 1
  _AM_PATH="$dir/$_AM_NAME"
  gitsrc_collect
  for i in "${!GITSRC_NAMES[@]}"; do
    [[ "${GITSRC_NAMES[$i]}" != "$_AM_FROM" ]] || _AM_FROM_I=$i
    [[ "${GITSRC_NAMES[$i]}" != "$_AM_TO" ]] || _AM_TO_I=$i
  done
  gitsrc_dir_reply "$_AM_FROM"; _AM_FROM_DIR="$REPLY"
  gitsrc_dir_reply "$_AM_TO"; _AM_TO_DIR="$REPLY"
  return 0
}

# Whether <name> (a resource's name below <dir>) is the moved one, or inside it when names nest
_anfs_move_in() {
  [[ "$1" == "$_AM_NAME" ]] && return 0
  [[ "${ANFS_NAME_NEST:-false}" == true && "$1" == "$_AM_NAME"/* ]]
}

# Whether source <s> holds the resource <dir>/<name> (with its marker, when there is one)
_anfs_move_has() {
  local s="$1" dir="$2" name="$3" d
  gitsrc_dir_reply "$s"
  d="$REPLY/$dir${name:+/$name}"
  [[ -d "$d" ]] || return 1
  [[ -z "${ANFS_RESOLVE_MARKER:-}" || -f "$d/$ANFS_RESOLVE_MARKER" ]]
}

# The resources of <dir> in source directory <sdir>, one name per line ("" for a nesting kind's
# root, <source>/<dir>/ itself)
_anfs_move_names() {
  local sdir="$1" dir="$2" m="${ANFS_RESOLVE_MARKER:-}" e f
  [[ -d "$sdir/$dir" ]] || return 0
  if [[ -n "$m" ]]; then
    while IFS= read -r f; do
      f="${f#"$sdir/$dir"}" f="${f#/}" f="${f%"$m"}" f="${f%/}"
      printf '%s\n' "$f"
    done < <(find "$sdir/$dir/" -name "$m" -type f 2>/dev/null | sed 's|//*|/|g')
  else
    for e in "$sdir/$dir"/*/; do
      [[ -d "$e" ]] || continue
      e="${e%/}"
      printf '%s\n' "${e##*/}"
    done
  fi
}

# Whether dependency <spec> of a resource at position <min> (in the whole source order) resolves
# from there down, before the move or after it (<after>: the moved names have left <from> and are
# in <to>). The rule is resolve.sh's: a dependency resolves to the same or a lower-priority source,
# named bare or qualified.
_anfs_move_resolves() {
  local spec="$1" min="$2" after="$3" dir="$4" j s src name
  _anfs_split "$spec"
  src="$_ANFS_SRC" name="$_ANFS_NAME"
  for j in "${!GITSRC_NAMES[@]}"; do
    (( j >= min )) || continue
    s="${GITSRC_NAMES[$j]}"
    [[ -z "$src" || "$s" == "$src" ]] || continue
    if $after && _anfs_move_in "$name"; then
      [[ "$s" != "$_AM_FROM" ]] || continue
      [[ "$s" != "$_AM_TO" ]] || return 0
    fi
    _anfs_move_has "$s" "$dir" "$name" && return 0
  done
  return 1
}

# --- anfs_move_check ----------------------------------------------------------------------------

_anfs_move_line() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
# Refused, whatever the flags
_anfs_move_never() { _anfs_move_line refused "$1" "$2"; _AM_RC=2; }
# Refused, unless -f
_anfs_move_refuse() {
  if $_AM_FORCE; then
    _anfs_move_line forced "$1" "$2"
  else
    _anfs_move_line refused "$1" "$2"
    (( _AM_RC == 2 )) || _AM_RC=1
  fi
}

# Why repository <repo> cannot take part in a commit now, into REPLY (empty when it can)
_anfs_move_repo_busy() {
  local r="$1" p
  REPLY=""
  for p in rebase-apply rebase-merge MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    if [[ -e "$(git -C "$r" rev-parse --path-format=absolute --git-path "$p" 2>/dev/null)" ]]; then
      case "$p" in
        rebase-apply) REPLY="an am or a rebase is in progress" ;;
        rebase-merge) REPLY="a rebase is in progress" ;;
        MERGE_HEAD) REPLY="a merge is in progress" ;;
        CHERRY_PICK_HEAD) REPLY="a cherry-pick is in progress" ;;
        REVERT_HEAD) REPLY="a revert is in progress" ;;
      esac
      return 0
    fi
  done
  git -C "$r" rev-parse -q --verify HEAD >/dev/null 2>&1 || { REPLY="it has no commit yet"; return 0; }
  git -C "$r" symbolic-ref -q HEAD >/dev/null 2>&1 || REPLY="it is on no branch (a detached HEAD: the commits would be lost)"
  return 0
}

# What `git status --porcelain` says about repository <repo>, as a short list in REPLY (empty when
# clean): with <skip>, the moved path left out; with <only>, that path alone
_anfs_move_dirty() {
  local r="$1" skip="${2:-}" only="${3:-}" line n=0 list=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ -z "$skip" || ( "${line:3}" != "$skip" && "${line:3}" != "$skip"/* ) ]] || continue
    [[ -z "$only" || "${line:3}" == "$only" || "${line:3}" == "$only"/* ]] || continue
    n=$((n + 1))
    (( n > 3 )) || list+="${list:+, }$line"
  done < <(git -C "$r" status --porcelain 2>/dev/null)
  (( n <= 3 )) || list+=", and $((n - 3)) more"
  REPLY="$list"
}

# Usage: anfs_move_check [-f] <dir> <id> <to> [deps-fn]
anfs_move_check() {
  _AM_FORCE=false _AM_RC=0
  [[ "${1:-}" != -f ]] || { _AM_FORCE=true; shift; }
  local dir="$1" id="$2" to="$3" deps_fn="${4:-}" kind m="${ANFS_RESOLVE_MARKER:-}" r p s d
  kind=$(anfs_kind "$dir")

  if ! _anfs_move_parse "$dir" "$id" "$to"; then
    _anfs_move_never "$kind" "'$id' is not qualified: <source>/<name> (a bare name is a layer in every source)"
    return 2
  fi
  local from="$_AM_FROM" name="$_AM_NAME" path="$_AM_PATH" fdir="$_AM_FROM_DIR" tdir="$_AM_TO_DIR"

  # --- What can never move
  if (( _AM_FROM_I < 0 )); then
    _anfs_move_never source "$from is not a configured source (anfs src list)"
  elif [[ "$from" == "$to" ]]; then
    _anfs_move_never source "$id is already in $to"
  elif (( _AM_TO_I < 0 )); then
    _anfs_move_never source "$to is not a configured source (anfs src list)"
  fi
  (( _AM_RC == 0 )) || return 2
  for s in "$from" "$to"; do
    gitsrc_dir_reply "$s"
    if [[ ! -d "$REPLY" ]]; then
      _anfs_move_never source "$s has no clone at $(_anfs_move_disp "$REPLY") (anfs src update $s)"
    elif [[ ! -e "$REPLY/.git" ]]; then
      _anfs_move_never source "$s is a local directory, not a git repository: it has no history to carry"
    fi
  done
  (( _AM_RC == 0 )) || return 2

  if [[ ! -d "$fdir/$path" ]]; then
    _anfs_move_never "$kind" "$from has no $path"
  elif [[ -n "$m" && ! -f "$fdir/$path/$m" ]]; then
    _anfs_move_never "$kind" "$from/$path has no $m: it is not a $kind"
  else
    _anfs_move_line ok "$kind" "$from/$path"
  fi

  # The destination's path: free, tracked by nothing, no file on the way
  p="" r=""
  local -a parts=()
  IFS=/ read -r -a parts <<< "$path"
  for d in "${parts[@]}"; do
    p+="${p:+/}$d"
    if [[ -L "$tdir/$p" || ( -e "$tdir/$p" && ! -d "$tdir/$p" ) ]]; then
      [[ "$p" == "$path" ]] || { r="$to has a file on the way: $p"; break; }
    fi
  done
  if [[ -z "$r" && ( -e "$tdir/$path" || -L "$tdir/$path" ) ]]; then
    r="$to already has $path"
  elif [[ -z "$r" && -n "$(git -C "$tdir" ls-files -- "$path" 2>/dev/null || true)" ]]; then
    r="$to tracks files at $path"
  fi
  if [[ -n "$r" ]]; then _anfs_move_never destination "$r (-f never overwrites a source)"
  else _anfs_move_line ok destination "$to/$path is free"; fi

  for s in "$from" "$to"; do
    gitsrc_dir_reply "$s"
    _anfs_move_repo_busy "$REPLY"
    [[ -z "$REPLY" ]] || _anfs_move_never repository "$s: $REPLY"
  done
  if [[ -d "$fdir/$path" ]]; then
    _anfs_move_dirty "$fdir" "" "$path"
    r="$REPLY"
    [[ -z "$r" ]] || _anfs_move_never "$kind" "uncommitted changes in $from/$path ($r): commit or stash them; what moves is what is committed"
  fi
  (( _AM_RC < 2 )) || return 2

  # --- What -f goes past
  local dirty=false
  for s in "$from" "$to"; do
    gitsrc_dir_reply "$s"
    _anfs_move_dirty "$REPLY" "$([[ "$s" == "$from" ]] && printf '%s' "$path")"
    if [[ -n "$REPLY" ]]; then
      dirty=true
      _anfs_move_refuse repository "uncommitted changes in $s: $REPLY (with -f the commits still hold only $path)"
    fi
  done
  $dirty || _anfs_move_line ok repository "$from and $to are clean"

  if [[ -n "$deps_fn" ]]; then
    _anfs_move_deps "$dir" "$deps_fn"
  else
    _anfs_move_line note dependents "not checked: the tool gave no dependency reader"
  fi
  _anfs_move_stacks "$dir"
  _anfs_move_layers "$dir"

  local bf bt
  bf=$(git -C "$fdir" symbolic-ref -q --short HEAD 2>/dev/null) || bf="?"
  bt=$(git -C "$tdir" symbolic-ref -q --short HEAD 2>/dev/null) || bt="?"
  _anfs_move_line note commits "one or more in $to (on $bt), one in $from (on $bf); nothing is pushed"
  return "$_AM_RC"
}

# The file a resource directory declares its dependencies in, for messages
_anfs_move_manifest() {
  local f="${ANFS_RESOLVE_MARKER:-${ANFS_MOVE_MANIFEST:-}}"
  _anfs_move_disp "$1${f:+/$f}"
}

# Dependents (every resource whose dependencies name a moved one, and would resolve it before the
# move but not after), then the moved resources' own dependencies (each must still resolve from
# the destination's position down)
_anfs_move_deps() {
  local dir="$1" deps_fn="$2" i s sdir n dep rdir broken=false own=false
  local -a moved=()
  anfs_sources "$dir"
  for i in "${!GITSRC_NAMES[@]}"; do
    s="${GITSRC_NAMES[$i]}"
    gitsrc_dir_reply "$s"
    sdir="$REPLY"
    while IFS= read -r n; do
      [[ -n "$n" || -n "${ANFS_RESOLVE_MARKER:-}" ]] || continue
      rdir="$sdir/$dir${n:+/$n}"
      if [[ "$s" == "$_AM_FROM" ]] && _anfs_move_in "$n"; then
        moved+=("$rdir")
        continue
      fi
      # a layer of the moved package itself is satisfied by its own group (resolve.sh)
      [[ "${ANFS_NAME_NEST:-false}" == true || "$n" != "$_AM_NAME" ]] || continue
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        _anfs_split "$dep"
        _anfs_move_in "$_ANFS_NAME" || continue
        _anfs_move_resolves "$dep" "$i" false "$dir" || continue
        _anfs_move_resolves "$dep" "$i" true "$dir" && continue
        broken=true
        if [[ -n "$_ANFS_SRC" ]]; then
          _anfs_move_refuse dependents "$s${n:+/$n} depends on $dep, which names $_AM_FROM: it never resolves after the move ($(_anfs_move_manifest "$rdir"))"
        else
          _anfs_move_refuse dependents "$s${n:+/$n} depends on $dep: after the move no source at or below $s has it ($(_anfs_move_manifest "$rdir"))"
        fi
      done < <("$deps_fn" "$rdir" 2>/dev/null)
    done < <(_anfs_move_names "$sdir" "$dir")
  done
  $broken || _anfs_move_line ok dependents "every dependent still resolves it"

  for rdir in ${moved[@]+"${moved[@]}"}; do
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      _anfs_move_resolves "$dep" "$_AM_FROM_I" false "$dir" || continue
      _anfs_move_resolves "$dep" "$_AM_TO_I" true "$dir" && continue
      own=true
      n="${rdir#"$_AM_FROM_DIR/$dir"}" n="${n#/}"
      _anfs_move_refuse dependencies "$_AM_FROM/$n depends on $dep, which does not resolve from $_AM_TO down ($(_anfs_move_manifest "$rdir"))"
    done < <("$deps_fn" "$rdir" 2>/dev/null)
  done
  $own || _anfs_move_line ok dependencies "each resolves from $_AM_TO down"
}

# Stacks that name a moved resource qualified (<from>/<name>): listed, never rewritten
_anfs_move_stacks() {
  local dir="$1" s f e any=false
  command -v yq >/dev/null 2>&1 || { _anfs_move_line note stacks "not checked: no yq"; return 0; }
  for s in "${GITSRC_NAMES[@]}"; do
    gitsrc_dir_reply "$s"
    for f in "$REPLY"/stacks/*/stack.yml; do
      [[ -f "$f" ]] || continue
      while IFS= read -r e; do
        [[ "$e" == "$_AM_FROM"/* ]] || continue
        _anfs_move_in "${e#*/}" || continue
        any=true
        _anfs_move_refuse stacks "$(_anfs_move_disp "$f") names $e (not rewritten)"
      done < <(D="$dir" yq -r '.[strenv(D)][]? | ((select(tag == "!!str")) // (select(tag == "!!map") | keys | .[]))' "$f" 2>/dev/null)
    done
  done
  $any || _anfs_move_line ok stacks "no stack names $_AM_FROM/$_AM_NAME"
}

# Other sources holding the same name: the layers before and after (a kind that layers), or which
# source a bare name finds (one that resolves first-match)
_anfs_move_layers() {
  local dir="$1" s before="" after="" others=false
  for s in "${GITSRC_NAMES[@]}"; do
    if [[ "$s" == "$_AM_TO" ]]; then
      after+="${after:+, }$s"
    elif _anfs_move_has "$s" "$dir" "$_AM_NAME"; then
      [[ "$s" == "$_AM_FROM" ]] || { others=true; after+="${after:+, }$s"; }
    fi
    if [[ "$s" == "$_AM_FROM" ]] || { [[ "$s" != "$_AM_TO" ]] && _anfs_move_has "$s" "$dir" "$_AM_NAME"; }; then
      before+="${before:+, }$s"
    fi
  done
  $others || return 0
  if [[ "${ANFS_RESOLVE_FIRST:-false}" == true ]]; then
    [[ "${before%%,*}" == "${after%%,*}" ]] ||
      _anfs_move_line note shadowing "a bare $_AM_NAME names ${before%%,*}/$_AM_NAME now, ${after%%,*}/$_AM_NAME after the move"
  else
    _anfs_move_line note layers "$_AM_NAME: $before -> $after (each layer's links are recomputed by its next install)"
  fi
}

# --- anfs_move_tree -----------------------------------------------------------------------------

# The flags every am of a replay takes (see the header)
_ANFS_MOVE_AM=(am -q -k --keep-cr --whitespace=nowarn --no-3way --committer-date-is-author-date --no-verify
  --no-message-id)
# Author, author date and whole message of each commit, records ended by RS
_ANFS_MOVE_FMT='%an <%ae>%x1f%ad%x1f%B%x1e'

# The replayed commits in <repo>, <base>..HEAD, against the origin's (_AM_WANT, _AM_WANT_IDS) and
# the path's tree: REPLY says what differs (empty when nothing does)
_anfs_move_verify() {
  local r="$1" base="$2" got i a b
  local -a ga=() wa=()
  REPLY=""
  if [[ "$(git -C "$r" rev-parse -q --verify "HEAD:$_AM_PATH" 2>/dev/null)" != "$_AM_TREE" ]]; then
    REPLY="the tree of $_AM_PATH"
    return 0
  fi
  got=$(git -C "$r" log --reverse --date=raw --format="$_ANFS_MOVE_FMT" "$base..HEAD")
  [[ "$got" != "$_AM_WANT" ]] || return 0
  mapfile -d $'\x1e' -t ga <<< "$got"
  mapfile -d $'\x1e' -t wa <<< "$_AM_WANT"
  for i in "${!wa[@]}"; do
    a="${wa[$i]#$'\n'}" b="${ga[$i]:-}" b="${b#$'\n'}"
    [[ "$a" != "$b" ]] || continue
    if [[ -z "$b" ]]; then REPLY="the number of commits"
    elif [[ "${a%%$'\x1f'*}" != "${b%%$'\x1f'*}" ]]; then REPLY="the author"
    else
      a="${a#*$'\x1f'}" b="${b#*$'\x1f'}"
      if [[ "${a%%$'\x1f'*}" != "${b%%$'\x1f'*}" ]]; then REPLY="the date"; else REPLY="the message"; fi
    fi
    REPLY+=": $(sed -n "$((i + 1))p" <<< "$_AM_WANT_IDS")"
    return 0
  done
  REPLY="the number of commits"
}

# The first line git said, for a reason
_anfs_move_first() { grep -m1 -v '^[[:space:]]*$' "$1" 2>/dev/null | sed 's/^error: //' || true; }

# Usage: anfs_move_tree [-n] <dir> <id> <to>
anfs_move_tree() {
  local dry=false tmp rc=0
  [[ "${1:-}" != -n ]] || { dry=true; shift; }
  ANFS_MOVE_METHOD="" ANFS_MOVE_COMMITS=0 ANFS_MOVE_WHY=""
  _anfs_move_parse "$1" "$2" "$3" || { anfs_warn "move: '$2' is not qualified"; return 1; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/anfs-move.XXXXXX") || return 1
  _anfs_move_tree "$dry" "$tmp" || rc=$?
  rm -rf -- "$tmp"
  return "$rc"
}

_anfs_move_tree() {
  local dry="$1" tmp="$2" from="$_AM_FROM" to="$_AM_TO" path="$_AM_PATH"
  local fdir="$_AM_FROM_DIR" tdir="$_AM_TO_DIR" fhead thead n=0 why="" sha url line
  local fst tst
  fhead=$(git -C "$fdir" rev-parse HEAD) || return 1
  thead=$(git -C "$tdir" rev-parse HEAD) || return 1
  fst=$(git -C "$fdir" status --porcelain) tst=$(git -C "$tdir" status --porcelain)
  _AM_TREE=$(git -C "$fdir" rev-parse -q --verify "HEAD:$path") || {
    anfs_warn "move: nothing is committed at $from/$path"
    return 1
  }

  # 1. The patches, and what they must reproduce
  mkdir -p "$tmp/patches"
  if ! git -C "$fdir" format-patch -q -k --no-signoff --no-attach --root -o "$tmp/patches" HEAD -- "$path" 2>"$tmp/err"; then
    why="format-patch failed: $(_anfs_move_first "$tmp/err")"
  fi
  local -a patches=()
  shopt -s nullglob
  patches=("$tmp"/patches/*.patch)
  shopt -u nullglob
  n=${#patches[@]}
  [[ -n "$why" || $n -gt 0 ]] || why="no commit touches $path"
  _AM_WANT=$(git -C "$fdir" log --no-merges --reverse --date=raw --format="$_ANFS_MOVE_FMT" HEAD -- "$path")
  _AM_WANT_IDS=$(git -C "$fdir" log --no-merges --reverse --format='%h %s' HEAD -- "$path")

  # 2. The trial, in a scratch repository: the destination is touched only by a replay that works
  if [[ -z "$why" ]]; then
    local -a sg=(git -C "$tmp/scratch" -c user.name=anfs -c user.email=anfs@localhost
      -c core.hooksPath=/dev/null -c commit.gpgSign=false)
    if ! { git init -q "$tmp/scratch" && "${sg[@]}" commit -q --no-verify --allow-empty -m scratch; } 2>"$tmp/err"; then
      why="no scratch repository: $(_anfs_move_first "$tmp/err")"
    elif ! "${sg[@]}" "${_ANFS_MOVE_AM[@]}" "${patches[@]}" >/dev/null 2>"$tmp/err"; then
      why="git am failed: $(_anfs_move_first "$tmp/err")"
    else
      _anfs_move_verify "$tmp/scratch" HEAD~"$n"
      [[ -z "$REPLY" ]] || why="the replay changed $REPLY"
    fi
  fi

  if $dry; then
    printf 'commits\t%d to replay from %s\n' "$n" "$from"
    git -C "$fdir" log --no-merges --reverse --date=short --format='  %h %ad %an %s' HEAD -- "$path"
    if [[ -z "$why" ]]; then printf 'replay\tok\n'; else printf 'replay\twould copy: %s\n' "$why"; fi
    ANFS_MOVE_METHOD=replay ANFS_MOVE_COMMITS=$n
    [[ -z "$why" ]] || ANFS_MOVE_METHOD=copy ANFS_MOVE_COMMITS=0 ANFS_MOVE_WHY="$why"
    return 0
  fi

  # 3. Into the destination
  if [[ -z "$why" ]] && ! git -C "$tdir" diff --cached --quiet 2>/dev/null; then
    why="$to has staged changes (git am needs a clean index)"
  fi
  if [[ -z "$why" ]]; then
    if git -C "$tdir" "${_ANFS_MOVE_AM[@]}" "${patches[@]}" >/dev/null 2>"$tmp/err"; then
      _anfs_move_verify "$tdir" "$thead"
      [[ -z "$REPLY" ]] || why="the replay in $to changed $REPLY"
    else
      why="git am failed in $to: $(_anfs_move_first "$tmp/err")"
    fi
    if [[ -n "$why" ]]; then
      [[ ! -d "$(git -C "$tdir" rev-parse --path-format=absolute --git-path rebase-apply)" ]] || git -C "$tdir" am --abort >/dev/null 2>&1 || true
      git -C "$tdir" reset -q --keep "$thead" 2>/dev/null || {
        anfs_warn "move: $to could not be put back at ${thead:0:7}: look at it (git -C $(_anfs_move_disp "$tdir") status)"
        return 1
      }
    else
      ANFS_MOVE_METHOD=replay ANFS_MOVE_COMMITS=$n
    fi
  fi
  if [[ -n "$why" ]]; then
    ANFS_MOVE_METHOD=copy ANFS_MOVE_COMMITS=0 ANFS_MOVE_WHY="$why"
    url=$(git -C "$fdir" remote get-url origin 2>/dev/null) || url="$fdir"
    # Exactly what is committed (modes and links kept), through an index of its own: the origin's
    # index and working tree are not touched, and no export attribute applies
    if ! { GIT_INDEX_FILE="$tmp/index" git -C "$fdir" read-tree --prefix="$path/" "$_AM_TREE" &&
           GIT_INDEX_FILE="$tmp/index" git -C "$fdir" checkout-index -a --prefix="$tdir/" &&
           git -C "$tdir" add -f -- "$path"; } 2>"$tmp/err"; then
      anfs_warn "move: copying into $to failed: $(_anfs_move_first "$tmp/err")"
      _anfs_move_undo_copy "$tdir" "$path" "$thead"
      return 1
    fi
    if ! git -C "$tdir" commit -q -m "$path: moved from $from" -m "Copied from $from ($url) at $fhead, where its history is:
git log $fhead -- $path. The history was not replayed: $why." -- "$path" 2>"$tmp/err"; then
      anfs_warn "move: the commit in $to failed: $(_anfs_move_first "$tmp/err")"
      _anfs_move_undo_copy "$tdir" "$path" "$thead"
      return 1
    fi
    # a hook that rewrote a file (the version bump) leaves its own content staged otherwise
    git -C "$tdir" add -A -- "$path" 2>/dev/null || true
  fi

  # 4. Out of the origin
  sha=$(git -C "$tdir" rev-parse --short HEAD)
  if ! { git -C "$fdir" rm -r -q -- "$path" &&
         git -C "$fdir" commit -q -m "$path: moved to $to ($ANFS_MOVE_METHOD, $sha)" -- "$path"; } 2>"$tmp/err"; then
    anfs_warn "move: the commit in $from failed: $(_anfs_move_first "$tmp/err"); both are as they were"
    git -C "$fdir" reset -q -- "$path" 2>/dev/null || true
    git -C "$fdir" checkout -q -- "$path" 2>/dev/null || true
    git -C "$tdir" reset -q --keep "$thead" 2>/dev/null ||
      anfs_warn "move: $to could not be put back at ${thead:0:7}: look at it"
    ANFS_MOVE_METHOD="" ANFS_MOVE_COMMITS=0
    return 1
  fi
  git -C "$fdir" add -A -- "$path" 2>/dev/null || true

  # What the origin ignores stays behind in its directory, which would still resolve as a resource
  # there (a directory is enough): it goes with the rest
  local f
  while IFS= read -r -d '' f; do
    [[ -e "$tdir/$f" || -L "$tdir/$f" ]] && continue
    mkdir -p -- "$tdir/$(dirname -- "$f")" && mv -- "$fdir/$f" "$tdir/$f"
  done < <(git -C "$fdir" ls-files -z -o -i --exclude-standard -- "$path" 2>/dev/null)
  [[ ! -d "$fdir/$path" ]] || find "$fdir/$path" -depth -type d -empty -delete 2>/dev/null || true
  [[ ! -e "$fdir/$path" ]] || anfs_warn "move: $(_anfs_move_disp "$fdir/$path") is still there (what git ignores in it could not all be moved)"

  # Both as clean as they were
  [[ "$(git -C "$fdir" status --porcelain)" == "$fst" ]] ||
    anfs_warn "move: $from is not as it was before the move: git -C $(_anfs_move_disp "$fdir") status"
  line=$(git -C "$tdir" status --porcelain)
  if [[ "$line" != "$tst" ]]; then
    if [[ -n "$(git -C "$tdir" status --porcelain -- "$path")" ]]; then
      anfs_warn "move: files $from ignored are untracked in $to: git -C $(_anfs_move_disp "$tdir") status -- $path"
    else
      anfs_warn "move: $to is not as it was before the move: git -C $(_anfs_move_disp "$tdir") status"
    fi
  fi

  if [[ "$ANFS_MOVE_METHOD" == replay ]]; then
    anfs_info "moved $path: $from -> $to, $n commit$([[ $n -eq 1 ]] || echo s) replayed"
  else
    anfs_info "moved $path: $from -> $to, copied in one commit (the replay failed: $why); its history stays in $from"
  fi
}

# A copy that did not commit, taken back out of <to>
_anfs_move_undo_copy() {
  git -C "$1" rm -r -q -f --cached --ignore-unmatch -- "$2" >/dev/null 2>&1 || true
  rm -rf -- "${1:?}/$2"
  git -C "$1" reset -q --keep "$3" 2>/dev/null || true
}

# --- anfs_move_cli ------------------------------------------------------------------------------

# Declare `<tool> move <id> <source>`, the same in every tool that has a move (the tool defines
# cmd_move, and complete_<arg-kind> and complete_source for the tab)
# Usage: anfs_move_cli <noun> <arg-kind>
anfs_move_cli() {
  cli_cmd move "Move a $1 to another source, with its history (commits in both; nothing is
pushed): replayed when it replays exactly, else copied in one commit naming the origin" \
    --opt "-f --force: Despite uncommitted changes elsewhere in either repository, a dependent
that will not resolve, or a stack that names it" \
    --opt "-n --dry-run: Print the checks, the commits to replay and the steps; change nothing" \
    --arg "$2" --arg "source"
}
