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
# - A path in a list may be a directory of <from>: it is one link (a directory link), planned,
#   applied, checked and unlinked like a file. A real directory at its place is a conflict.
# - A link is per file and relative, exactly as `stow --no-folding` writes it: from the link's
#   directory up to <to>, then to the file (../../.local/share/anfs/sources/...). The directories
#   on the way are real and are made; they are never links. So an install stow made is taken over
#   as it is, and `stow -D` still undoes one this made.
# - Relative everywhere, but one rule: when the link's directory and its target share only /
#   (a source on another volume, /Volumes/x), the link is absolute (anfs_link_text).
# - A directory on the way that is a link is followed only when it resolves inside <to> and not
#   into $ANFS_SOURCES_HOME: a path through a directory link (~/.local/lib/anfs) would be written
#   into a source's checkout, so it is a conflict (inside a directory link).
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
#             on the way that is a file, a link out of <to> or a directory link into the sources
#             (inside a directory link: <owner>); for a directory entry, a real directory (with
#             links into another package: <owner>, when it holds any)
# What to do with other and conflict is the caller's: ppm backs up on -f, wsm refuses.
#
#   anfs_link_plan   <from> <to> <files-file> [skip-file]   print the plan; 1 on any other or conflict
#   anfs_link_apply  <from> <to> <files-file> [skip-file]   the plan, then the links; nothing on a conflict
#   anfs_link_check  <from> <to> <files-file>...            the state of each file's link; read-only
#   anfs_unlink      <from> <to> <files-file>               remove each link that points into <from>
#   anfs_unlink_tree <from> <to>                            the same for every file under <from>
#   anfs_link_one    <from-file> <to-path>                  one relative link, parents made; 1 when
#                                                           anything is at <to-path>
#   anfs_link_owner  <path>                                 the sources-relative target of a link into
#                                                           $ANFS_SOURCES_HOME, else 1
#   anfs_relpath     <from-dir> <to>                        <to> relative to <from-dir> (both canonical)
#   anfs_link_text   <link-dir> <target>                    the text of a link in <link-dir> to <target>
#                                                           (both canonical): relative, or absolute
#                                                           when they share only /
#   anfs_link_src_state <link> <src>                        a link to a path outside any tree: ok,
#                                                           missing, missing src, wrong, in the way
#   anfs_unlink_src  <link> <src>                           remove <link> while it resolves to <src>
#
# The check prints "<state><TAB><path>" per file, in the list's order, and changes nothing:
#   ok          a link whose text is what anfs_link_apply writes, or that resolves to the file
#               (relative or absolute)
#   missing     nothing there (a directory on the way may be missing too)
#   wrong       a link to anything else, dangling or not
#   in the way  a file or a directory there, or a directory on the way that is a file or a link
#               out of <to>
# It forks a constant number of times however many files there are: tests in the shell, the
# expected text built by string operations, and every link's text read with one readlink (BSD's
# and GNU's take many operands), for one triplet or several. Only a link whose text differs is
# resolved.
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
  _anfs_link_physical "$p"
  _ANFS_P="${_ANFS_PHYS%/}$rest"
  [ -n "$_ANFS_P" ] || _ANFS_P=/
}

# The physical path of existing directory <dir>, into _ANFS_PHYS (<dir> itself when it cannot be
# entered). It changes directory in this shell and back, so it forks nothing: a check of a whole
# tree resolves many. When the current directory cannot be returned to, a subshell does it.
_anfs_link_physical() {
  local here="$PWD"
  if [ -n "$here" ] && [ -d "$here" ] && builtin cd -P -- "$1" 2>/dev/null; then
    _ANFS_PHYS="$PWD"
    builtin cd -- "$here" 2>/dev/null || builtin cd -P -- "$here" 2>/dev/null || true
  else
    _ANFS_PHYS=$(cd -P -- "$1" 2>/dev/null && pwd -P) || _ANFS_PHYS="$1"
  fi
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
  _anfs_relpath "$1" "$2"
  printf '%s\n' "$_ANFS_P"
}

# anfs_relpath into _ANFS_P, for the library's own use (no subshell)
_anfs_relpath() {
  local from="${1%/}" to="${2%/}" up=""
  [ -n "$from" ] || from=/
  [ "$from" != "$to" ] || { _ANFS_P=.; return 0; }
  while [[ "$to" != "$from"/* ]]; do
    [ "$from" != / ] || { _ANFS_P="$up${to#/}"; return 0; }
    from="${from%/*}" up="../$up"
    [ -n "$from" ] || from=/
  done
  _ANFS_P="$up${to#"$from"/}"
}

# Whether canonical <a> and <b> share only / (their first components differ, or one is /)
_anfs_link_only_root() {
  local a="${1#/}" b="${2#/}"
  a="${a%%/*}" b="${b%%/*}"
  [ -z "$a" ] || [ -z "$b" ] || [ "$a" != "$b" ]
}

# The text of a link in directory <link-dir> to <target> (both canonical): relative, or <target>
# itself when the two share only / (a link across volumes stays absolute)
anfs_link_text() {
  _anfs_link_text "$1" "$2"
  printf '%s\n' "$_ANFS_P"
}

# anfs_link_text into _ANFS_P
_anfs_link_text() {
  if _anfs_link_only_root "$1" "$2"; then _ANFS_P="$2"; else _anfs_relpath "$1" "$2"; fi
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
# <to> (and not into the sources: a directory link, whose files are a source's) is followed,
# anything else is a conflict. Sets _ANFS_D to the canonical directory (which may not exist yet) or
# _ANFS_WHY. <to> is canonical; _anfs_link_sources has run.
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
        "$to"/*)
          if _anfs_link_owned "$r"; then
            _ANFS_WHY="inside a directory link: ${p#"$to"/} -> $_ANFS_P"
            return 1
          fi
          p="$r"
          ;;
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
' tab='	' skip="" f s cfrom cto base d name dest text lastd="" up rc=0 bad="" abs=false
  _ANFS_DO_F="" _ANFS_DO_T="" _ANFS_DO_R=""

  [ -d "$from" ] || { echo "anfs: link: no directory $from" >&2; return 2; }
  [ -z "$skipf" ] || skip="$nl$(cat "$skipf" 2>/dev/null)$nl"
  _anfs_link_canon "$from"; cfrom="$_ANFS_P"
  _anfs_link_canon "$to"; cto="$_ANFS_P"
  _anfs_relpath "$cto" "$cfrom"; base="$_ANFS_P"
  # <to> and <from> on different volumes: every link is absolute (anfs_link_text)
  ! _anfs_link_only_root "$cto" "$cfrom" || abs=true
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
    ! $abs || text="$cfrom/$f"
    if [ -L "$dest" ]; then
      s=$(readlink -- "$dest")
      if [ "$s" = "$text" ]; then printf 'keep\t%s\n' "$f"; continue; fi
      _anfs_link_resolve "$dest" "$_ANFS_D"
      if [ "$_ANFS_P" = "$cfrom/$f" ] && { $abs || [ "${s#/}" = "$s" ]; }; then
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
      # a directory entry over a real directory: say whose links it holds, if any (another
      # package's: ppm's -f must not move them aside)
      if [ -d "$from/$f" ] && [ ! -L "$from/$f" ] && _anfs_link_holds "$dest" "$cfrom/$f"; then
        printf 'conflict\t%s\t%s\n' "$f" "a directory, with links into another package: $_ANFS_P"
      else
        printf 'conflict\t%s\t%s\n' "$f" "a directory"
      fi
      rc=1; continue
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

# Whether directory <dir> holds a link into the sources that does not point into canonical <own>
# (another package's, live or dangling). Sets _ANFS_P to its target, sources-relative. One find,
# only for a real directory where a directory link goes.
_anfs_link_holds() {
  local l t
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    _anfs_link_resolve "$l" || continue
    t="$_ANFS_P"
    case "$t" in "$2"|"$2"/*) continue ;; esac
    _anfs_link_owned "$t" && return 0
  done <<EOF
$(find "$1" -type l 2>/dev/null)
EOF
  return 1
}

# Usage: anfs_link_plan <from> <to> <files-file> [skip-file]
anfs_link_plan() {
  _anfs_link_classify "$@"
}

# Usage: anfs_link_apply <from> <to> <files-file> [skip-file]
anfs_link_apply() {
  local to="$2" rc=0 f t r d cur=""
  _anfs_link_classify "$@" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$_ANFS_DO_F" ] || return 0
  # A directory's links are made together: one mkdir, one rm of what is replaced, one ln (a link
  # made into a directory is named for its text's last part, which is the file's name)
  _ANFS_RM=() _ANFS_LN=()
  while IFS= read -r f <&3 && IFS= read -r t <&4 && IFS= read -r r <&5; do
    [ -n "$f" ] || continue
    case "$f" in
      */*) d="$to/${f%/*}" ;;
      *) d="$to" ;;
    esac
    if [ "$d" != "$cur" ]; then
      [ -z "$cur" ] || _anfs_link_flush "$cur" || return 1
      cur="$d"
    fi
    [ "$r" != true ] || _ANFS_RM[${#_ANFS_RM[@]}]="$to/$f"
    _ANFS_LN[${#_ANFS_LN[@]}]="$t"
  done 3<<EOF3 4<<EOF4 5<<EOF5
$_ANFS_DO_F
EOF3
$_ANFS_DO_T
EOF4
$_ANFS_DO_R
EOF5
  [ -z "$cur" ] || _anfs_link_flush "$cur"
}

# The links queued for directory <dir> (_ANFS_RM, _ANFS_LN), made, and the queues emptied
_anfs_link_flush() {
  mkdir -p -- "$1" || return 1
  [ ${#_ANFS_RM[@]} -eq 0 ] || rm -f -- "${_ANFS_RM[@]}"
  ln -s -- "${_ANFS_LN[@]}" "$1/" || return 1
  _ANFS_RM=() _ANFS_LN=()
}

# --- The check ----------------------------------------------------------------------------------

# Usage: anfs_link_check <from> <to> <files-file> [<from> <to> <files-file>]...
# Several triplets are checked as one: their lines come out in order, triplet by triplet, and
# the links of all of them are read with the one readlink. The states are also left in the array
# _ANFS_ST, in the same order, for a caller that wants them without a subshell; _ANFS_ABS is set
# at the index of an ok that is an absolute link (the plan's replace, where a relative one is keep).
anfs_link_check() {
  local from to tab='	' nl='
' cfrom cto base f d name dest text lastd up s i n=0 j abs
  local -a st=() lk=() lx=() lf=() ld=() lc=() la=() got=()
  _ANFS_ST=()
  _anfs_link_sources
  [ $(($# % 3)) -eq 0 ] && [ $# -gt 0 ] || { echo "anfs: link: check takes <from> <to> <files-file>, one or more" >&2; return 2; }
  while [ $# -gt 0 ]; do
    from="$1" to="$2"
    [ -d "$from" ] || { echo "anfs: link: no directory $from" >&2; return 2; }
    [ -r "$3" ] || return 2
    _anfs_link_canon "$from"; cfrom="$_ANFS_P"
    _anfs_link_canon "$to"; cto="$_ANFS_P"
    _anfs_relpath "$cto" "$cfrom"; base="$_ANFS_P"
    abs=""
    ! _anfs_link_only_root "$cto" "$cfrom" || abs=1
    lastd=""

    # Every file's state that needs no link text; each link queued, its index kept
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        *"$tab"*) echo "anfs: link: a file name with a tab cannot be linked: $from/$f" >&2; return 2 ;;
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
      lf[$n]="$f"
      if [ -z "$_ANFS_D" ]; then
        st[$n]="in the way"
      else
        dest="$_ANFS_D/$name"
        if [ -L "$dest" ]; then
          text="$up$base/$f"
          [ "$base" != . ] || text="$up$f"
          [ -z "$abs" ] || text="$cfrom/$f"
          st[$n]=link
          j=${#lk[@]}
          lk[$j]="$dest" lx[$j]="$text" ld[$j]="$_ANFS_D" lc[$j]="$cfrom" la[$j]="$abs"
        elif [ -e "$dest" ]; then
          st[$n]="in the way"
        else
          st[$n]=missing
        fi
      fi
      n=$((n + 1))
    done < "$3"
    shift 3
  done

  # The links' texts, one readlink for all of them (through xargs past a few thousand, for the
  # length of a command line); a text with a newline would put the lines out of step: then each
  # is read on its own
  if [ ${#lk[@]} -gt 0 ]; then
    i=0
    while IFS= read -r s; do got[$i]="$s"; i=$((i + 1)); done <<EOF
$(if [ ${#lk[@]} -le 2000 ]; then readlink -- "${lk[@]}" 2>/dev/null; else printf '%s\0' "${lk[@]}" | xargs -0 readlink -- 2>/dev/null; fi)
EOF
    if [ "$i" -ne ${#lk[@]} ]; then
      got=()
      i=0
      while [ "$i" -lt ${#lk[@]} ]; do
        got[$i]=$(readlink -- "${lk[$i]}" 2>/dev/null) || got[$i]=""
        i=$((i + 1))
      done
    fi
  fi

  j=0
  i=0
  _ANFS_ST=() _ANFS_ABS=()
  while [ "$i" -lt "$n" ]; do
    s="${st[$i]}"
    if [ "$s" = link ]; then
      s="${got[$j]}"
      if [ "$s" = "${lx[$j]}" ]; then
        s=ok
      else
        # an absolute link is ok, but marked (where relative is expected)
        case "$s" in
          /*) [ -n "${la[$j]}" ] || _ANFS_ABS[$i]=1 ;;
          *) s="${ld[$j]}/$s" ;;
        esac
        _anfs_link_canon "$s"
        if [ "$_ANFS_P" = "${lc[$j]}/${lf[$i]}" ]; then s=ok; else s=wrong; unset "_ANFS_ABS[$i]"; fi
      fi
      j=$((j + 1))
    fi
    _ANFS_ST[$i]="$s"
    printf '%s\t%s\n' "$s" "${lf[$i]}"
    i=$((i + 1))
  done
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

# One link: <to-path> to <from-file>, relative (anfs_link_text: absolute across volumes), its
# directory made. Refuses (1, nothing made) when anything is at <to-path>, a link or a directory
# included: ln -s would put the link inside an existing directory.
# Usage: anfs_link_one <from-file> <to-path>
anfs_link_one() {
  local src="$1" dest="$2" d csrc
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    echo "anfs: link: something is already at $dest" >&2
    return 1
  fi
  case "$dest" in */*) d="${dest%/*}" ;; *) d=. ;; esac
  [ -n "$d" ] || d=/
  mkdir -p -- "$d" || return 1
  d=$(cd -P -- "$d" && pwd -P) || return 1
  _anfs_link_canon "$src"; csrc="$_ANFS_P"
  _anfs_link_text "$d" "$csrc"
  ln -s -- "$_ANFS_P" "$dest"
}

# --- Links out of a tree ------------------------------------------------------------------------
#
# A link to a path outside any tree (space.yml's and package.yml's links: {src, dest}): made with
# anfs_link_one, so relative. Judged on canonical paths: a relative or an absolute link that
# resolves to <src> is the same link.

# The state of <link> as a link to <src>: ok (it resolves to <src>, which exists), missing (nothing
# there), missing src (<src> is not there; the link may be, pointing at it), wrong (a link that
# resolves elsewhere), in the way (anything else there)
# Usage: anfs_link_src_state <link> <src>
anfs_link_src_state() {
  local link="$1" cs
  _anfs_link_canon "$2"; cs="$_ANFS_P"
  if [ -L "$link" ]; then
    if _anfs_link_resolve "$link" && [ "$_ANFS_P" = "$cs" ]; then
      if [ -e "$2" ]; then echo ok; else echo "missing src"; fi
    else
      echo wrong
    fi
  elif [ -e "$link" ]; then
    echo "in the way"
  elif [ -e "$2" ]; then
    echo missing
  else
    echo "missing src"
  fi
}

# Remove <link> only while it resolves to <src> (live or dangling); one the user repointed stays
# Usage: anfs_unlink_src <link> <src>
anfs_unlink_src() {
  local cs
  [ -L "$1" ] || return 0
  _anfs_link_canon "$2"; cs="$_ANFS_P"
  _anfs_link_resolve "$1" || return 0
  [ "$_ANFS_P" != "$cs" ] || rm -f -- "$1"
  return 0
}
