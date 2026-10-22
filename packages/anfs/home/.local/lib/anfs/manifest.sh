#!/usr/bin/env bash
# anfs: links:, files: and platforms: of a package.yml or a space.yml, read into one plan input
#
# BOOTSTRAP SET: install.sh sources this under whatever bash started it, which on a vanilla Mac is
# 3.2 (core/anfs declares a directory link, and the bootstrap links core/anfs). Keep it parseable
# and runnable there: no bash 4+ syntax (see bash.sh). Functions only. Needs yq, and link.sh
# (sourced first: _anfs_link_norm).
#
# The vocabulary is one for both manifests. Everything under the tree (a package's home/, a space's
# own files) is linked file by file unless an entry says otherwise:
#
#   links:
#     - .local/lib/anfs/                   a directory (a trailing /), as one link at the same path
#     - {path: <p>, platforms: [macos]}    only on those platforms: a file; a directory without a
#                                          trailing / file by file; with one, as one link
#     - {src: <outside>, dest: <d>}        a link at dest (default: src's basename) to src; ~ and
#                                          $NAME / ${NAME} expanded (no eval; unset is an error);
#                                          platforms: too
#   files:
#     - .config/foo/defaults.conf          copied when missing, never again: then it is the user's
#     - {path: <p>, platforms: [debian]}
#   platforms: macos, linux (any distro), debian, fedora; on the manifest it is the whole
#     package's (the tool's business), on an entry that entry's
#
# One src: entry that cannot be (an unset variable, a relative src in a package.yml, a dest outside
# the target, a link to /) is only that entry: ANFS_MF_INVALID, skipped, the rest placed.
# Refused (every one listed, ANFS_MF_ERR; the manifest is invalid): a links: string without a
# trailing /; a path or files: entry not in the tree, absolute or with ..; a trailing / on what is
# not a directory; a files: entry that is a directory; a directory link inside another, a platform
# entry or a files: entry inside a directory link; the same path twice; an unknown platform or
# platforms: []; a map with both path and src or neither, or another key; a kind the tool does not
# take (ANFS_MF_KINDS, default "dir path src file": each tool says which it accepts).
#
#   anfs_manifest_read  <yml>...       one yq over all of them (one at a time only if that fails);
#                                      rows "<i>\t<kind>\t<path>\t<dest>\t<platforms csv>", <i> the
#                                      yml's index, <kind> dir|path|src|file (src: <path> is the src
#                                      as written), or "<i>\terror\t<message>"; with
#                                      ANFS_MF_YQ_EXTRA, that expression's lines too, which must
#                                      start "<fileIndex>\x1fX\x1f", as "<i>\textra\t<the rest>"
#   anfs_manifest_plan  <rows> <tree> <platform> [files-file]
#                                      the plan input for one manifest's rows (the <i> column is not
#                                      read); [files-file] is the candidate per-file list (wsm's),
#                                      else every file under <tree>
#   anfs_manifest_match <platform> <csv>   true when the csv names <platform> (linux: any distro)
#
# anfs_manifest_plan sets, newline-separated:
#   ANFS_MF_LINKS    paths for link.sh, relative to <tree>: the per-file set, then the directory
#                    links that apply here (plain paths, no trailing /)
#   ANFS_MF_SRCS     "<dest>\t<src>": src expanded, normalised, absolute
#   ANFS_MF_COPIES   paths for files.sh
#   ANFS_MF_OFF      "<path>\t<platforms>" filtered out on this platform (a directory with its /)
#   ANFS_MF_DIRS     the directory links that apply here, alone
#   ANFS_MF_INVALID  "<dest>\t<src as written>\t<why>": a src: entry wrong on its own (an unset
#                    variable, a relative src where none may be, a dest outside the target, a link
#                    to /): skipped and said by the tool, while the rest is placed
#   ANFS_MF_ERR      one line per refusal; the plan returns 2 when there is any (the rest unset)

ANFS_MF_PLATFORMS="macos linux debian fedora"

# The yq that reads one entry of links: (L) or files: (F) into 10 fields split by \x1f:
# fileIndex, L|F, the entry's tag, a string entry, path, src, dest, platforms csv, platforms' tag,
# keys a map should not have
_anfs_mf_entry() {
  printf '%s' '[fileIndex, "'"$1"'", tag, (select(tag == "!!str") // ""), ((select(tag == "!!map") | .path) // ""), ((select(tag == "!!map") | .src) // ""), ((select(tag == "!!map") | .dest) // ""), ((select(tag == "!!map") | .platforms | select(tag == "!!seq") | join(",")) // ""), ((select(tag == "!!map") | .platforms | tag) // ""), ((select(tag == "!!map") | keys - ["path", "src", "dest", "platforms"] | join(",")) // "")] | join(strenv(ANFS_MF_SEP))'
}

_anfs_mf_expr() {
  local k e=""
  for k in links files; do
    # (yq: != against a "!!..." string is always true, and or binds looser than ==: parenthesised)
    e="$e${e:+, }(select(.$k | ((tag == \"!!null\") or (tag == \"!!seq\")) | not) | [fileIndex, \"E\", \"$k: is not a list\"] | join(strenv(ANFS_MF_SEP)))"
  done
  e="$e, (select(.links | tag == \"!!seq\") | .links[] | $(_anfs_mf_entry L))"
  e="$e, (select(.files | tag == \"!!seq\") | .files[] | $(_anfs_mf_entry F))"
  [ -z "${ANFS_MF_YQ_EXTRA:-}" ] || e="$e, $ANFS_MF_YQ_EXTRA"
  printf '%s' "$e"
}

# Usage: anfs_manifest_read <yml>...
anfs_manifest_read() {
  local expr out f i=0 line sep=$'\x1f'
  [ $# -gt 0 ] || return 0
  expr=$(_anfs_mf_expr)
  if ! out=$(ANFS_MF_SEP="$sep" yq -r "$expr" "$@" 2>/dev/null); then
    # One at a time, to keep what can be read; the index is then this loop's
    out=""
    for f in "$@"; do
      if line=$(ANFS_MF_SEP="$sep" yq -r "$expr" "$f" 2>/dev/null); then
        [ -z "$line" ] || out="$out$(printf '%s\n' "$line" | sed "s/^0$sep/$i$sep/")
"
      else
        out="$out$i${sep}E${sep}cannot read $f
"
      fi
      i=$((i + 1))
    done
  fi
  _anfs_mf_rows "$out"
}

# The rows of yq's output (the fields split by \x1f)
_anfs_mf_rows() {
  local line i sect tag str p src dest pcsv ptag bad sep=$'\x1f' tab='	' why
  while IFS= read -r line; do
    case "$line" in [0-9]*"$sep"*) ;; *) continue ;; esac
    i="${line%%"$sep"*}" line="${line#*"$sep"}"
    sect="${line%%"$sep"*}" line="${line#*"$sep"}"
    case "$sect" in
      E) printf '%s\terror\t%s\n' "$i" "$line"; continue ;;
      X) printf '%s\textra\t%s\n' "$i" "$line"; continue ;;
    esac
    tag="${line%%"$sep"*}" line="${line#*"$sep"}"
    str="${line%%"$sep"*}" line="${line#*"$sep"}"
    p="${line%%"$sep"*}" line="${line#*"$sep"}"
    src="${line%%"$sep"*}" line="${line#*"$sep"}"
    dest="${line%%"$sep"*}" line="${line#*"$sep"}"
    pcsv="${line%%"$sep"*}" line="${line#*"$sep"}"
    ptag="${line%%"$sep"*}" bad="${line#*"$sep"}"
    why=""
    case "$str$p$src$dest" in *"$tab"*) why="a tab in an entry" ;; esac
    if [ -z "$why" ] && [ "$tag" != '!!str' ] && [ "$tag" != '!!map' ]; then
      why="an entry is a path or a map, not $tag"
    fi
    if [ -z "$why" ] && [ "$tag" = '!!map' ]; then
      if [ -n "$bad" ]; then why="unknown key ($bad) in {${p:+path: $p}${src:+src: $src}}"
      elif [ -n "$p" ] && [ -n "$src" ]; then why="an entry has a path or a src, not both: $p, $src"
      elif [ -z "$p" ] && [ -z "$src" ]; then why="an entry needs a path${sect#F}"
      elif [ "$sect" = F ] && [ -n "$src" ]; then why="files: takes a path, not a src: $src"
      elif [ -n "$dest" ] && [ -z "$src" ]; then why="dest goes with src: $p"
      elif [ -n "$ptag" ] && [ "$ptag" != '!!null' ] && [ "$ptag" != '!!seq' ]; then why="platforms: is a list: ${p:-$src}"
      elif [ "$ptag" = '!!seq' ] && [ -z "$pcsv" ]; then why="platforms: [] names none: ${p:-$src}"
      fi
    fi
    if [ -n "$why" ]; then
      [ "$why" != "an entry needs a pathL" ] || why="a links: entry needs a path or a src"
      [ "$why" != "an entry needs a path" ] || why="a files: entry needs a path"
      printf '%s\terror\t%s\n' "$i" "$why"
      continue
    fi
    if [ "$sect" = F ]; then
      printf '%s\tfile\t%s\t\t%s\n' "$i" "${str:-$p}" "$pcsv"
    elif [ -n "$src" ]; then
      printf '%s\tsrc\t%s\t%s\t%s\n' "$i" "$src" "$dest" "$pcsv"
    elif [ -n "$str" ]; then
      case "$str" in
        */) printf '%s\tdir\t%s\t\t\n' "$i" "${str%/}" ;;
        *) printf '%s\terror\t%s\n' "$i" "a links: path without a trailing / says nothing the default does not: $str (a directory as one link is $str/; for some platforms, {path: $str, platforms: [...]})" ;;
      esac
    else
      case "$p" in
        */) printf '%s\tdir\t%s\t\t%s\n' "$i" "${p%/}" "$pcsv" ;;
        *)
          if [ -z "$pcsv" ]; then
            printf '%s\terror\t%s\n' "$i" "{path: $p} without platforms says nothing the default does not"
          else
            printf '%s\tpath\t%s\t\t%s\n' "$i" "$p" "$pcsv"
          fi
          ;;
      esac
    fi
  done <<EOF
$1
EOF
}

# Usage: anfs_manifest_match <platform> <csv>
anfs_manifest_match() {
  case ",$2," in *",$1,"*) return 0 ;; esac
  [ -n "$1" ] && [ "$1" != macos ] || return 1
  case ",$2," in *,linux,*) return 0 ;; esac
  return 1
}

# A path from a manifest, as a path in the tree: no leading /, no .. (refused: 1), . and repeated
# slashes taken out. Into _ANFS_P.
_anfs_mf_path() {
  case "/$1/" in
    //|/*/../*|*/../|/../*) return 1 ;;
  esac
  case "$1" in /*) return 1 ;; esac
  _anfs_link_norm "$1"
  _ANFS_P="${_ANFS_P#/}"
  [ -n "$_ANFS_P" ] || return 1
}

# ~ and $NAME / ${NAME} expanded from the environment, no eval, into _ANFS_P; 1 (_ANFS_P the name)
# when a variable is unset
_anfs_mf_expand() {
  local s="$1" out="" name rest re1='^\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$' re2='^([A-Za-z_][A-Za-z0-9_]*)(.*)$'
  case "$s" in
    "~") s="$HOME" ;;
    "~/"*) s="$HOME/${s#\~/}" ;;
  esac
  while :; do
    case "$s" in *'$'*) ;; *) break ;; esac
    out="$out${s%%\$*}" s="${s#*\$}"
    if [[ "$s" =~ $re1 ]] || [[ "$s" =~ $re2 ]]; then
      name="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"
      eval "[ -n \"\${$name+x}\" ]" || { _ANFS_P="$name"; return 1; }
      eval "out=\"\$out\${$name}\""
      s="$rest"
    else
      out="$out\$"
    fi
  done
  _ANFS_P="$out$s"
}

# Usage: anfs_manifest_plan <rows> <tree> <platform> [files-file]
anfs_manifest_plan() {
  local rows="$1" tree="$2" plat="$3" ff="${4:-}" nl='
' tab='	'
  local line kind p dest pcsv i c x seen="$nl" dirs="" inside="" offp="" excl="$nl" kinds what
  ANFS_MF_LINKS="" ANFS_MF_SRCS="" ANFS_MF_COPIES="" ANFS_MF_OFF="" ANFS_MF_DIRS="" ANFS_MF_ERR="" ANFS_MF_INVALID=""
  kinds=" ${ANFS_MF_KINDS:-dir path src file} "

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line="${line#*"$tab"}"
    kind="${line%%"$tab"*}" line="${line#*"$tab"}"
    if [ "$kind" = error ]; then _anfs_mf_err "$line"; continue; fi
    [ "$kind" != extra ] || continue
    p="${line%%"$tab"*}" line="${line#*"$tab"}"
    dest="${line%%"$tab"*}" pcsv="${line#*"$tab"}"
    case "$kind" in
      dir) what="a directory link ($p/)" ;;
      path) what="a path entry ($p)" ;;
      src) what="a src: link ($p)" ;;
      file) what="files: ($p)" ;;
      *) _anfs_mf_err "unknown entry: $kind"; continue ;;
    esac
    case "$kinds" in *" $kind "*) ;; *) _anfs_mf_err "$what is not taken here"; continue ;; esac

    # The platforms, every one known
    if [ -n "$pcsv" ]; then
      x="" c=""
      for c in $(printf '%s' "$pcsv" | tr ',' ' '); do
        case " $ANFS_MF_PLATFORMS " in *" $c "*) ;; *) x="$x${x:+, }$c" ;; esac
      done
      [ -z "$x" ] || { _anfs_mf_err "unknown platform ($x) in $what; known: $ANFS_MF_PLATFORMS"; continue; }
    fi

    if [ "$kind" = src ]; then
      _anfs_mf_src "$p" "$dest" "$pcsv" "$plat" "$seen" || continue
      seen="$seen$_ANFS_P$nl"
      continue
    fi

    _anfs_mf_path "$p" || { _anfs_mf_err "a path in the tree is needed: $p"; continue; }
    p="$_ANFS_P"
    case "$seen" in *"$nl$p$nl"*) _anfs_mf_err "the same path twice: $p"; continue ;; esac
    seen="$seen$p$nl"
    if [ ! -e "$tree/$p" ] && [ ! -L "$tree/$p" ]; then _anfs_mf_err "not in the tree: $p"; continue; fi
    case "$kind" in
      dir)
        if [ ! -d "$tree/$p" ] || [ -L "$tree/$p" ]; then _anfs_mf_err "a trailing / on what is not a directory: $p/"; continue; fi
        dirs="$dirs$p$nl"
        if [ -z "$pcsv" ] || anfs_manifest_match "$plat" "$pcsv"; then
          ANFS_MF_DIRS="$ANFS_MF_DIRS$p$nl"
        else
          ANFS_MF_OFF="$ANFS_MF_OFF$p/$tab$pcsv$nl"
        fi
        ;;
      path)
        inside="$inside$p$nl"
        if ! anfs_manifest_match "$plat" "$pcsv"; then
          offp="$offp$p$nl"
          ANFS_MF_OFF="$ANFS_MF_OFF$p$tab$pcsv$nl"
        fi
        ;;
      file)
        if [ -d "$tree/$p" ] && [ ! -L "$tree/$p" ]; then _anfs_mf_err "files: a directory is not a file: $p"; continue; fi
        inside="$inside$p$nl"
        excl="$excl$p$nl"
        if [ -z "$pcsv" ] || anfs_manifest_match "$plat" "$pcsv"; then
          ANFS_MF_COPIES="$ANFS_MF_COPIES$p$nl"
        else
          ANFS_MF_OFF="$ANFS_MF_OFF$p$tab$pcsv$nl"
        fi
        ;;
    esac
  done <<EOF
$rows
EOF

  # A directory link brings the whole directory: nothing inside it can be left out or copied, nor
  # be another directory link
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    while IFS= read -r x; do
      [ -n "$x" ] && [ "$x" != "$c" ] || continue
      case "$x" in
        "$c"/*)
          case "$nl$dirs" in
            *"$nl$x$nl"*) _anfs_mf_err "a directory link inside another: $x/ is in $c/" ;;
            *) _anfs_mf_err "$x is inside the directory link $c/ (it brings the whole directory; it cannot leave a file out or copy one)" ;;
          esac
          ;;
      esac
    done <<EOF2
$dirs$inside
EOF2
  done <<EOF3
$dirs
EOF3
  [ -z "$ANFS_MF_ERR" ] || return 2

  # The per-file set: every candidate but what is under a directory link, a files: entry, or a
  # path entry filtered out here
  local f skip
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "${f##*/}" != .DS_Store ] || continue
    case "$excl" in *"$nl$f$nl"*) continue ;; esac
    skip=false
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      case "$f" in "$c"|"$c"/*) skip=true; break ;; esac
    done <<EOF4
$dirs$offp
EOF4
    $skip || ANFS_MF_LINKS="$ANFS_MF_LINKS$f$nl"
  done <<EOF5
$(if [ -n "$ff" ]; then cat "$ff"; else _anfs_mf_files "$tree"; fi)
EOF5
  ANFS_MF_LINKS="$ANFS_MF_LINKS$ANFS_MF_DIRS"
  return 0
}

# Every file (and link) under <tree>, relative to it
_anfs_mf_files() {
  [ -d "$1" ] || return 0
  (cd -- "$1" && find . \( -type f -o -type l \) ! -name .DS_Store | sed 's|^\./||')
}

_anfs_mf_err() {
  ANFS_MF_ERR="$ANFS_MF_ERR$1
"
}

# One src: entry checked, made absolute and normalised, its dest worked out; ANFS_MF_SRCS or
# ANFS_MF_OFF gets it. _ANFS_P is the dest. What is wrong with this one entry (an unset variable, a
# relative src where none may be, a dest outside the target, a link to /) does not refuse the
# manifest: the entry goes to ANFS_MF_INVALID, skipped, and the rest is placed. 1 when it is not
# placed.
# Usage: _anfs_mf_src <src> <dest> <platforms csv> <platform> <seen>
_anfs_mf_src() {
  local raw="$1" dest="$2" pcsv="$3" plat="$4" seen="$5" src d nl='
' tab='	'
  d="${dest:-${raw%/}}"; d="${d##*/}"
  [ -z "$dest" ] || d="$dest"
  # another platform's entry is only off, whatever it says
  if [ -n "$pcsv" ] && ! anfs_manifest_match "$plat" "$pcsv"; then
    ANFS_MF_OFF="$ANFS_MF_OFF$d$tab$pcsv$nl"
    return 1
  fi
  if ! _anfs_mf_expand "$raw"; then
    _anfs_mf_bad "$d" "$raw" "\$$_ANFS_P is not set"
    return 1
  fi
  src="$_ANFS_P"
  case "$src" in
    /*) ;;
    *)
      if [ -z "${ANFS_MF_SRC_BASE:-}" ]; then
        _anfs_mf_bad "$d" "$raw" "a src: here is absolute, or starts with ~ or a variable"
        return 1
      fi
      src="$ANFS_MF_SRC_BASE/$src"
      ;;
  esac
  _anfs_link_norm "$src"
  src="$_ANFS_P"
  [ "$src" != / ] || { _anfs_mf_bad "$d" "$raw" "a link to / is not one"; return 1; }
  [ -n "$dest" ] || dest="${src##*/}"
  while :; do case "$dest" in */) dest="${dest%/}" ;; *) break ;; esac; done
  if ! _anfs_mf_path "$dest" || [ "$_ANFS_P" = . ]; then
    _anfs_mf_bad "$dest" "$raw" "dest must stay inside the target: '$dest'"
    return 1
  fi
  dest="$_ANFS_P"
  case "$seen" in *"$nl$dest$nl"*) _anfs_mf_err "the same path twice: $dest"; return 1 ;; esac
  ANFS_MF_SRCS="$ANFS_MF_SRCS$dest$tab$src$nl"
  _ANFS_P="$dest"
}

# One invalid entry: "<dest>\t<src as written>\t<why>" into ANFS_MF_INVALID
_anfs_mf_bad() {
  ANFS_MF_INVALID="$ANFS_MF_INVALID$1	$2	$3
"
}
