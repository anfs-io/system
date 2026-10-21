#!/usr/bin/env bash
# anfs: linking files from one directory into another (what GNU stow did for ppm and wsm)
#
# BOOTSTRAP SET: install.sh sources this under whatever bash started it, which on a vanilla Mac is
# 3.2. Keep it parseable and runnable there: no bash 4+ syntax (see bash.sh). Functions only.
#
# The library knows nothing about packages or spaces: it links a list of files from one directory
# (<from>) into another (<to>), skipping a set, and says who a link points into. Layers, trackers,
# backups and platforms are the tools'.
#
# - Paths in a list are relative to <from>; a list is a file of newline-separated paths (a process
#   substitution will do). A name with a newline or a tab is refused, once, by the plan.
# - A link is per file and relative, exactly as `stow --no-folding` writes it: from the link's
#   directory up to <to>, then to the file (../../.local/share/anfs/sources/...). The directories
#   on the way are real and are made; they are never links. So an install stow made is taken over
#   as it is, and `stow -D` still undoes one this made.
# - Paths are compared canonical (macOS's /var is /private/var): a link's target is its directory
#   resolved, then the link text applied without resolving, so a dangling link is judged too.
#
# The plan prints one line per file, "<class><TAB><path>", plus "<TAB><detail>" for other and
# conflict:
#   link      nothing there: a link is made
#   keep      a relative link to this very file: left as it is
#   replace   ours to rewrite: a link into <from> (absolute, or to another of its files, or
#             dangling), or a dangling link into $ANFS_SOURCES_HOME (a file that moved away)
#   skip      in the skip set, or .DS_Store (the one name the library skips by itself)
#   other     a live link into another directory under $ANFS_SOURCES_HOME: another layer's or
#             package's; the detail is anfs_link_owner's answer
#   conflict  anything else: a file, a directory where a file goes, a link elsewhere, a directory
#             on the way that is a file or a link out of <to>
# What to do with other and conflict is the caller's: ppm backs up on -f, wsm refuses.
#
#   anfs_link_plan   <from> <to> <files-file> [skip-file]   print the plan; 1 on any other or conflict
#   anfs_link_apply  <from> <to> <files-file> [skip-file]   the plan, then the links; nothing on a conflict
#   anfs_unlink      <from> <to> <files-file>               remove each link that points into <from>
#   anfs_unlink_tree <from> <to>                            the same for every file under <from>
#   anfs_link_one    <from-file> <to-path>                  one relative link, parents made
#   anfs_link_owner  <path>                                 the sources-relative target of a link into
#                                                           $ANFS_SOURCES_HOME, else 1
#   anfs_relpath     <from-dir> <to>                        <to> relative to <from-dir> (both canonical)
#
# Exit codes: 0 done; 1 other or conflict (nothing touched); 2 refused (a name with a newline or a
# tab, or a path the list names that <from> does not have).

# --- Paths --------------------------------------------------------------------------------------

# <path> without . and .. and repeated slashes, lexically (nothing is resolved). Sets _ANFS_P.
_anfs_link_norm() {
  local rest="${1#/}" out="" c
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) c="${rest%%/*}" rest="${rest#*/}" ;;
      *) c="$rest" rest="" ;;
    esac
    case "$c" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$c" ;;
    esac
  done
  _ANFS_P="${out:-/}"
}

# The canonical path of <path>, which need not exist: its deepest existing directory resolved, the
# rest appended. Sets _ANFS_P.
_anfs_link_canon() {
  local p rest="" d
  _anfs_link_norm "$1"
  p="$_ANFS_P"
  while [ "$p" != / ] && [ ! -d "$p" ]; do
    rest="/${p##*/}$rest"
    p="${p%/*}"
    [ -n "$p" ] || p=/
  done
  d=$(cd -P -- "$p" 2>/dev/null && pwd -P) || d="$p"
  _ANFS_P="${d%/}$rest"
  [ -n "$_ANFS_P" ] || _ANFS_P=/
}

# Where link <link> points, canonical. <dir>, when given, is the link's directory already made
# canonical (the plan knows it). Sets _ANFS_P; returns 1 when <link> is not a link.
_anfs_link_resolve() {
  local link="$1" dir="${2:-}" t
  t=$(readlink -- "$link") || return 1
  case "$t" in
    /*) ;;
    *)
      if [ -z "$dir" ]; then
        dir="${link%/*}"
        [ -n "$dir" ] || dir=/
        dir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
      fi
      t="$dir/$t"
      ;;
  esac
  _anfs_link_canon "$t"
}

# <to> relative to directory <from>, both absolute and canonical
anfs_relpath() {
  local from="${1%/}" to="${2%/}" up=""
  [ -n "$from" ] || from=/
  [ "$from" != "$to" ] || { printf '.\n'; return 0; }
  while [[ "$to" != "$from"/* ]]; do
    [ "$from" != / ] || { printf '%s\n' "$up${to#/}"; return 0; }
    from="${from%/*}" up="../$up"
    [ -n "$from" ] || from=/
  done
  printf '%s\n' "$up${to#"$from"/}"
}

# The canonical $ANFS_SOURCES_HOME, and the real directory of each source that is a link there (a
# local-path source), as "<alias><TAB><dir>" lines. Sets _ANFS_SRC and _ANFS_SRC_LINKS.
_anfs_link_sources() {
  local e d
  _ANFS_SRC="" _ANFS_SRC_LINKS=""
  [ -n "${ANFS_SOURCES_HOME:-}" ] && [ -d "$ANFS_SOURCES_HOME" ] || return 0
  _anfs_link_canon "$ANFS_SOURCES_HOME"
  _ANFS_SRC="$_ANFS_P"
  for e in "$ANFS_SOURCES_HOME"/*; do
    [ -L "$e" ] || continue
    d=$(cd -P -- "$e" 2>/dev/null && pwd -P) || continue
    _ANFS_SRC_LINKS="$_ANFS_SRC_LINKS${e##*/}	$d
"
  done
}

# The sources-relative path of canonical <target>, from _anfs_link_sources. Sets _ANFS_P.
_anfs_link_owned() {
  local t="$1" alias d
  _ANFS_P=""
  [ -n "$_ANFS_SRC" ] || return 1
  case "$t" in
    "$_ANFS_SRC"/*) _ANFS_P="${t#"$_ANFS_SRC"/}"; return 0 ;;
  esac
  while IFS='	' read -r alias d; do
    [ -n "$d" ] || continue
    case "$t" in
      "$d"/*) _ANFS_P="$alias/${t#"$d"/}"; return 0 ;;
    esac
  done <<EOF
$_ANFS_SRC_LINKS
EOF
  return 1
}

# Print "<source>/<path in it>" when <path> is a link into $ANFS_SOURCES_HOME (live or dangling;
# a local-path source is named by its alias), else return 1. Who owns a file: a link into
# <source>/packages/<p>/ is ppm's, into <source>/spaces/ wsm's.
anfs_link_owner() {
  [ -L "$1" ] || return 1
  _anfs_link_resolve "$1" || return 1
  local t="$_ANFS_P"
  _anfs_link_sources
  _anfs_link_owned "$t" || return 1
  printf '%s\n' "$_ANFS_P"
}

# --- The plan -----------------------------------------------------------------------------------

# Check the directories on the way to <to>/<dir>: real ones are fine, a link that resolves inside
# <to> is followed, anything else is a conflict. Sets _ANFS_D to the canonical directory (which may
# not exist yet) or _ANFS_WHY. <to> is canonical.
_anfs_link_dir() {
  local to="$1" rest="$2" p="$1" c r
  _ANFS_WHY=""
  [ "$rest" != . ] || rest=""
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) c="${rest%%/*}" rest="${rest#*/}" ;;
      *) c="$rest" rest="" ;;
    esac
    p="$p/$c"
    if [ -L "$p" ]; then
      r=$(cd -P -- "$p" 2>/dev/null && pwd -P) || { _ANFS_WHY="a dangling link on the way: ${p#"$to"/}"; return 1; }
      case "$r/" in
        "$to"/*) p="$r" ;;
        *) _ANFS_WHY="a link out of the target on the way: ${p#"$to"/}"; return 1 ;;
      esac
    elif [ -d "$p" ]; then
      :
    elif [ -e "$p" ]; then
      _ANFS_WHY="a file where a directory goes: ${p#"$to"/}"
      return 1
    else
      p="$p${rest:+/$rest}"
      break
    fi
  done
  _ANFS_D="$p"
}

# The plan, printed, for anfs_link_plan and anfs_link_apply; what to do is left in _ANFS_DO_F (the
# paths), _ANFS_DO_T (each link's text) and _ANFS_DO_R (true where something is replaced), one per
# line in step.
_anfs_link_classify() {
  local from="$1" to="$2" files="$3" skipf="${4:-}"
  local nl='
' tab='	' skip="" f s cfrom cto base d name dest text lastd="" up rc=0 bad=""
  _ANFS_DO_F="" _ANFS_DO_T="" _ANFS_DO_R=""

  [ -d "$from" ] || { echo "anfs: link: no directory $from" >&2; return 2; }
  [ -z "$skipf" ] || skip="$nl$(cat "$skipf" 2>/dev/null)$nl"
  _anfs_link_canon "$from"; cfrom="$_ANFS_P"
  _anfs_link_canon "$to"; cto="$_ANFS_P"
  base=$(anfs_relpath "$cto" "$cfrom")
  _anfs_link_sources

  # Every name first: a list cut by a newline in a name names paths <from> does not have
  local list
  list=$(cat "$files") || return 2
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      *"$tab"*) bad="a file name with a tab cannot be linked: $from/$f"; break ;;
    esac
    if [ ! -e "$from/$f" ] && [ ! -L "$from/$f" ]; then
      if [ -n "$(find "$from" -name "*$nl*" 2>/dev/null | head -n 1)" ]; then
        bad="a file name with a newline cannot be linked, in $from"
      else
        bad="not in $from: $f"
      fi
      break
    fi
  done <<EOF
$list
EOF
  [ -z "$bad" ] || { echo "anfs: link: $bad" >&2; return 2; }

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "${f##*/}" = .DS_Store ]; then printf 'skip\t%s\n' "$f"; continue; fi
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
      up=""
      if [ -n "$_ANFS_D" ]; then
        s="${_ANFS_D#"$cto"}"
        while [ -n "$s" ]; do up="../$up"; s="${s%/*}"; done
      fi
    fi
    if [ -z "$_ANFS_D" ]; then
      printf 'conflict\t%s\t%s\n' "$f" "$_ANFS_WHY"; rc=1; continue
    fi

    dest="$_ANFS_D/$name"
    text="$up$base/$f"
    [ "$base" != . ] || text="$up$f"
    if [ -L "$dest" ]; then
      s=$(readlink -- "$dest")
      if [ "$s" = "$text" ]; then printf 'keep\t%s\n' "$f"; continue; fi
      _anfs_link_resolve "$dest" "$_ANFS_D"
      if [ "$_ANFS_P" = "$cfrom/$f" ] && [ "${s#/}" = "$s" ]; then
        printf 'keep\t%s\n' "$f"; continue
      fi
      case "$_ANFS_P" in
        "$cfrom"/*) ;;
        *)
          if [ ! -e "$dest" ] && _anfs_link_owned "$_ANFS_P"; then
            :   # dangling, into the sources: ppm's own leftover
          elif [ -e "$dest" ] && _anfs_link_owned "$_ANFS_P"; then
            printf 'other\t%s\t%s\n' "$f" "$_ANFS_P"; rc=1; continue
          else
            printf 'conflict\t%s\t%s\n' "$f" "a link to $s"; rc=1; continue
          fi
          ;;
      esac
      printf 'replace\t%s\n' "$f"
      _ANFS_DO_R="${_ANFS_DO_R}true$nl"
    elif [ -d "$dest" ]; then
      printf 'conflict\t%s\t%s\n' "$f" "a directory"; rc=1; continue
    elif [ -e "$dest" ]; then
      printf 'conflict\t%s\t%s\n' "$f" "a file"; rc=1; continue
    else
      printf 'link\t%s\n' "$f"
      _ANFS_DO_R="${_ANFS_DO_R}false$nl"
    fi
    _ANFS_DO_F="$_ANFS_DO_F$f$nl"
    _ANFS_DO_T="$_ANFS_DO_T$text$nl"
  done <<EOF
$list
EOF
  return $rc
}

# Usage: anfs_link_plan <from> <to> <files-file> [skip-file]
anfs_link_plan() {
  _anfs_link_classify "$@"
}

# Usage: anfs_link_apply <from> <to> <files-file> [skip-file]
anfs_link_apply() {
  local to="$2" rc=0 f t r
  _anfs_link_classify "$@" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$_ANFS_DO_F" ] || return 0
  while IFS= read -r f <&3 && IFS= read -r t <&4 && IFS= read -r r <&5; do
    [ -n "$f" ] || continue
    case "$f" in
      */*) mkdir -p -- "$to/${f%/*}" || return 1 ;;
      *) mkdir -p -- "$to" || return 1 ;;
    esac
    [ "$r" != true ] || rm -f -- "$to/$f"
    ln -s -- "$t" "$to/$f" || return 1
  done 3<<EOF3 4<<EOF4 5<<EOF5
$_ANFS_DO_F
EOF3
$_ANFS_DO_T
EOF4
$_ANFS_DO_R
EOF5
}

# --- Unlinking ----------------------------------------------------------------------------------

# Remove each <to>/<file> that is a link into <from> (live or dangling). Anything else is left:
# a file, a link elsewhere, a link into another directory. Directories stay, as stow -D leaves them.
# Usage: anfs_unlink <from> <to> <files-file>
anfs_unlink() {
  local from="$1" to="$2" f cfrom list
  _anfs_link_canon "$from"; cfrom="$_ANFS_P"
  list=$(cat "$3") || return 1
  while IFS= read -r f; do
    [ -n "$f" ] && [ -L "$to/$f" ] || continue
    _anfs_link_resolve "$to/$f" || continue
    case "$_ANFS_P" in
      "$cfrom"/*) rm -f -- "$to/$f" ;;
    esac
  done <<EOF
$list
EOF
  return 0
}

# anfs_unlink for every file under <from>: for when there is no list (no tracker)
# Usage: anfs_unlink_tree <from> <to>
anfs_unlink_tree() {
  [ -d "$1" ] || return 0
  anfs_unlink "$1" "$2" <(cd -- "$1" && find . \( -type f -o -type l \) | sed 's|^\./||')
}

# One link: <to-path> to <from-file>, relative, its directory made. Fails when <to-path> exists.
# Usage: anfs_link_one <from-file> <to-path>
anfs_link_one() {
  local src="$1" dest="$2" d csrc
  case "$dest" in */*) d="${dest%/*}" ;; *) d=. ;; esac
  [ -n "$d" ] || d=/
  mkdir -p -- "$d" || return 1
  d=$(cd -P -- "$d" && pwd -P) || return 1
  _anfs_link_canon "$src"; csrc="$_ANFS_P"
  ln -s -- "$(anfs_relpath "$d" "$csrc")" "$dest"
}
