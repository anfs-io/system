#!/usr/bin/env bash
# ppm move: a package to another source, with its history (lib/anfs/move.sh)
#
#   ppm move <source/package> <to-source> [-n] [-f]
#
# The package's directory moves with its commits (replayed into the destination, or copied in one
# commit naming the origin when the replay would not reproduce them), and one commit in the origin
# removes it; nothing is pushed. Around that, what ppm keeps about the package follows it:
#   - its links: the tracker's files are unlinked from the origin and linked again from the
#     destination, exactly those (a higher layer's files and protected ones are left alone; a
#     directory link is one entry). The links out of the tree (links: {src}) point outside the
#     package and stay as they are; copies (files:) are the user's
#   - the tracker, unchanged (version, files, links, installed_deps, resources), under the new source
#   - claims (claimant and owner), the callback registration (else ppm_callback_invoke looks for
#     install.sh in the old directory), the backup manifest's owner (else ppm remove never puts the
#     user's original file back)
# No hook runs, nothing is installed: the content did not change, only where it lives. Before
# anything changes, every tracked link must still be the package's (the relink then cannot meet a
# conflict). core/anfs and core/ppm are refused without -f: install.sh links them from the core
# clone.
#
# Sourced by ~/.local/bin/ppm with ppm's other libraries; functions only. bin/ppm declares the
# command (anfs_move_cli).

# Usage: cmd_move <source/package> <to-source>
cmd_move() {
  local id="${1%/}" to="${2%/}" from pkg fdir tdir rc=0 installed=false files="" plan line bad=""
  local -a fl=()
  ${force:-false} && fl=(-f)
  collect_repos
  if [[ "$id" == core/anfs || "$id" == core/ppm ]] && ! ${force:-false}; then
    anfs_warn "$id is a base package: install.sh links it from $(_anfs_move_disp "$PPM_REPO_DIR") (-f to move it anyway)"
    return 1
  fi

  ANFS_MOVE_MANIFEST=package.yml
  anfs_move_check "${fl[@]}" packages "$id" "$to" meta_depends || rc=$?
  if (( rc != 0 )); then
    if (( rc == 1 )); then anfs_warn "move refused: -f moves despite what it says"; else anfs_warn "move refused"; fi
    return "$rc"
  fi
  from="${id%%/*}" pkg="${id#*/}"
  gitsrc_dir_reply "$from"; fdir="$REPLY/packages/$pkg"
  gitsrc_dir_reply "$to"; tdir="$REPLY/packages/$pkg"

  # Every link the tracker lists is still this package's, so the relink cannot meet anything
  if meta_is_installed "$from" "$pkg"; then
    installed=true
    files=$(meta_installed_files "$from" "$pkg")
    if [[ -n "$files" ]]; then
      rc=0
      plan=$(anfs_link_plan "$fdir/home" "$HOME" <(printf '%s\n' "$files") 2>&1) || rc=$?
      if (( rc == 2 )); then
        anfs_warn "$id's tracker lists files it no longer has: ppm install $id, then move"
        return 1
      fi
      while IFS=$'\t' read -r -a line; do
        [[ -n "${line[0]:-}" && "${line[0]}" != keep ]] || continue
        # an absolute link into the package, live, is the package's too (the relink makes it relative)
        [[ "${line[0]}" != replace || ! -e "$HOME/${line[1]}" ]] || continue
        bad+="  ~/${line[1]} is not $id's link any more (${line[0]}${line[2]:+: ${line[2]}})"$'\n'
      done <<< "$plan"
      if [[ -n "$bad" ]]; then
        printf '%s' "$bad" >&2
        anfs_warn "move refused: ppm install -f $id, or ppm file protect them, then move"
        return 1
      fi
    fi
  fi

  if ${dry_run:-false}; then
    anfs_move_tree -n packages "$id" "$to" || return 1
    _move_steps "$from" "$to" "$pkg" "$installed" "$files"
    return 0
  fi

  PPM_CURRENT_PACKAGE="$to/$pkg"
  # Only the tracker's files, never the hooks (and not unstow_package: it also unlinks the
  # links: {src} links, which point outside the package and stay)
  ! $installed || [[ -z "$files" ]] || anfs_unlink "$fdir/home" "$HOME" <(printf '%s\n' "$files")
  if ! anfs_move_tree packages "$id" "$to"; then
    if $installed && [[ -n "$files" ]] &&
       ! anfs_link_apply "$fdir/home" "$HOME" <(printf '%s\n' "$files") >/dev/null; then
      ppm_fail "$id is where it was, but its links are not all back: ppm install -f $id" || true
    fi
    PPM_CURRENT_PACKAGE=""
    flush_user_messages
    return 1
  fi

  if $installed; then
    mkdir -p "$PPM_INSTALLED_DIR/$to"
    mv -- "$(_tracker_path "$from" "$pkg")" "$(_tracker_path "$to" "$pkg")"
    rmdir -- "$PPM_INSTALLED_DIR/$from" 2>/dev/null || true
    if [[ -n "$files" ]] && ! anfs_link_apply "$tdir/home" "$HOME" <(printf '%s\n' "$files") >/dev/null; then
      ppm_fail "$to/$pkg moved, but its links are not all made: ppm install -f $to/$pkg" || true
    fi
  else
    user_message "$id was not installed: ppm install $to/$pkg links it"
  fi
  _move_rename "$id" "$to/$pkg"
  PPM_CURRENT_PACKAGE=""
  flush_user_messages
}

# What a move would do besides the tree, for -n
# Usage: _move_steps <from> <to> <pkg> <installed> <files>
_move_steps() {
  local from="$1" to="$2" pkg="$3" installed="$4" files="$5" n=0 c
  [[ -z "$files" ]] || n=$(grep -c . <<< "$files")
  if $installed; then
    printf '%-8s %d links into %s/packages/%s (no remove hooks)\n' unlink "$n" "$from" "$pkg"
    printf '%-8s %d links from %s/packages/%s (no install hooks)\n' relink "$n" "$to" "$pkg"
    printf '%-8s installed/%s/%s.yml -> installed/%s/%s.yml\n' tracker "$from" "$pkg" "$to" "$pkg"
  else
    printf 'not installed: ppm install %s/%s links it\n' "$to" "$pkg"
  fi
  c=$(_move_claims_count "$from/$pkg")
  (( c == 0 )) || printf '%-8s %d entr%s (claimant or owner %s/%s)\n' claims "$c" "$([[ $c -eq 1 ]] && echo y || echo ies)" "$from" "$pkg"
  ! _move_callback_has "$from/$pkg" || printf '%-8s ppm: %s/%s -> %s/%s\n' callback "$from" "$pkg" "$to" "$pkg"
  c=$(_move_backup_count "$from/$pkg")
  (( c == 0 )) || printf '%-8s %d entr%s\n' backup "$c" "$([[ $c -eq 1 ]] && echo y || echo ies)"
}

# The claims naming <repo/pkg>, as claimant or owner
_move_claims_count() {
  [[ -s "$PPM_CLAIMS_FILE" ]] || { echo 0; return; }
  O="$1" yq -r '[.[] | select(.claimant == strenv(O) or .owner == strenv(O))] | length' "$PPM_CLAIMS_FILE" 2>/dev/null || echo 0
}

_move_callback_has() {
  local f
  f=$(anfs_callbacks_file ppm)
  [[ -s "$f" ]] && O="$1" yq -e 'has(strenv(O))' "$f" >/dev/null 2>&1
}

# The backup manifest's lines owned by <repo/pkg>
_move_backup_count() {
  local m="$PPM_STATE_HOME/backup/manifest"
  [[ -f "$m" ]] || { echo 0; return; }
  awk -F'\t' -v o="$1" '$1 == o { n++ } END { print n + 0 }' "$m"
}

# Everything of ppm's that names <old repo/pkg> names <new> afterwards: claims, the callback
# registration, the backup manifest. Each is a no-op when nothing names it.
# Usage: _move_rename <old> <new>
_move_rename() {
  local old="$1" new="$2" f m="$PPM_STATE_HOME/backup/manifest"
  if [[ -s "$PPM_CLAIMS_FILE" ]]; then
    O="$old" N="$new" yq -i '
      (.[] | select(.claimant == strenv(O)).claimant) = strenv(N) |
      (.[] | select(.owner == strenv(O)).owner) = strenv(N)
    ' "$PPM_CLAIMS_FILE" || ppm_fail "could not rename $old in $(_anfs_move_disp "$PPM_CLAIMS_FILE")" || true
  fi
  if _move_callback_has "$old"; then
    f=$(anfs_callbacks_file ppm)
    O="$old" N="$new" yq -i '.[strenv(N)] = .[strenv(O)] | del(.[strenv(O)])' "$f" ||
      ppm_fail "could not rename $old's callback in $(_anfs_move_disp "$f")" || true
  fi
  if [[ -f "$m" ]] && (( $(_move_backup_count "$old") > 0 )); then
    awk -F'\t' -v OFS='\t' -v o="$old" -v n="$new" '$1 == o { $1 = n } { print }' "$m" > "$m.tmp" &&
      mv -- "$m.tmp" "$m" || ppm_fail "could not rename $old in $(_anfs_move_disp "$m")" || true
  fi
  return 0
}
