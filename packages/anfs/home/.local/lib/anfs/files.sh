#!/usr/bin/env bash
# anfs: real files in a target (what link.sh is for links). For now one operation, copy-if-missing,
# for the files: of a package.yml or a space.yml (lib/anfs/manifest.sh): a copy is made when
# nothing is there and never again, so once made it is the user's. This is also where the shared
# file operations of the `file` command group go (linker plan 03).
#
# BOOTSTRAP SET: install.sh sources this under whatever bash started it, which on a vanilla Mac is
# 3.2. Keep it parseable and runnable there: no bash 4+ syntax (see bash.sh). Functions only, no
# yq. Needs link.sh (sourced first): what is on the way to a target is judged as it judges it.
#
# The plan prints one line per file, "<state><TAB><path>", plus "<TAB><detail>" for in the way:
#   missing     nothing there: apply copies it (with its mode; the directories made)
#   present     a regular file with the same bytes
#   differs     a regular file with other bytes: information only, never touched, -f or not
#   in the way  a directory, a link of any kind, or an obstacle on the way (a file where a
#               directory goes, a link out of the target, a directory link into the sources)
#   skip        in the skip set
#
#   anfs_files_plan  <from> <to> <files-file> [skip-file]   print the plan; 1 on any in the way
#   anfs_files_apply <from> <to> <files-file> [skip-file]   the plan, then each missing file copied;
#                                                           nothing on an in the way
#
# A copy is written beside the target under a temporary name and moved into place only if nothing
# appeared there meanwhile (a hard link, which fails on an existing name). One cmp per file that
# exists; no fork for a missing one.
#
# Exit codes: 0 done; 1 in the way (nothing copied); 2 refused (a name with a newline or a tab, or a
# path the list names that <from> does not have as a file).

# The plan, printed; the files to copy left in _ANFS_CP, one per line
_anfs_files_classify() {
  local from="$1" to="$2" files="$3" skipf="${4:-}" nl='
' tab='	' skip="" f d name dest cto list rc=0 lastd
  lastd="$nl" _ANFS_CP=""
  [ -d "$from" ] || { echo "anfs: files: no directory $from" >&2; return 2; }
  [ -z "$skipf" ] || skip="$nl$(cat "$skipf" 2>/dev/null)$nl"
  list=$(cat "$files") || return 2
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      *"$tab"*) echo "anfs: files: a file name with a tab cannot be copied: $from/$f" >&2; return 2 ;;
    esac
    if [ ! -f "$from/$f" ]; then
      echo "anfs: files: not a file in $from: $f" >&2
      return 2
    fi
  done <<EOF
$list
EOF
  _anfs_link_canon "$to"; cto="$_ANFS_P"
  _anfs_link_sources

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$skip" in
      *"$nl$f$nl"*) printf 'skip\t%s\n' "$f"; continue ;;
    esac
    case "$f" in
      */*) d="${f%/*}" name="${f##*/}" ;;
      *) d=. name="$f" ;;
    esac
    if [ "$d" != "$lastd" ]; then
      lastd="$d"
      _anfs_link_dir "$cto" "$d" || _ANFS_D=""
    fi
    if [ -z "$_ANFS_D" ]; then
      printf 'in the way\t%s\t%s\n' "$f" "$_ANFS_WHY"; rc=1; continue
    fi
    dest="$_ANFS_D/$name"
    if [ -L "$dest" ]; then
      printf 'in the way\t%s\t%s\n' "$f" "a link"; rc=1
    elif [ -d "$dest" ]; then
      printf 'in the way\t%s\t%s\n' "$f" "a directory"; rc=1
    elif [ -e "$dest" ]; then
      if cmp -s -- "$from/$f" "$dest"; then printf 'present\t%s\n' "$f"
      else printf 'differs\t%s\n' "$f"; fi
    else
      printf 'missing\t%s\n' "$f"
      _ANFS_CP="$_ANFS_CP$f$nl"
    fi
  done <<EOF
$list
EOF
  return $rc
}

# Usage: anfs_files_plan <from> <to> <files-file> [skip-file]
anfs_files_plan() {
  _anfs_files_classify "$@"
}

# Usage: anfs_files_apply <from> <to> <files-file> [skip-file]
anfs_files_apply() {
  local from="$1" to="$2" rc=0 f dest tmp
  _anfs_files_classify "$@" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    dest="$to/$f"
    mkdir -p -- "${dest%/*}" || return 1
    tmp="${dest%/*}/.${dest##*/}.anfs-copy.$$"
    rm -f -- "$tmp"
    cp -p -- "$from/$f" "$tmp" || { rm -f -- "$tmp"; return 1; }
    # into place only if nothing is there now: ln fails on an existing name, mv would not
    if ! ln -- "$tmp" "$dest" 2>/dev/null; then
      printf 'in the way\t%s\t%s\n' "$f" "it appeared while copying" >&2
      rc=1
    fi
    rm -f -- "$tmp"
  done <<EOF
$_ANFS_CP
EOF
  return $rc
}
