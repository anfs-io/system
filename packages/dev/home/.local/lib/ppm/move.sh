#!/usr/bin/env bash
# anfs/dev — adds `ppm move`: relocate a package to another source repo
# Stowed to ~/.local/lib/ppm/ and sourced by ppm, so cmd_move() is the command `ppm move`
#
# Moving a package is four things, not one: unstow it from the old location, move the directory,
# stow it from the new one, and carry ppm's bookkeeping across (the install tracker, and any
# `ppm file claim` that names the package as claimant or owner). Both repos are then committed,
# because a package that has only moved on disk comes back on the next `anfs src update`.
#
# Install hooks are deliberately NOT re-run: the package's content is unchanged, only its path,
# so pre_remove/post_install would tear down services and rewrite generated config for nothing.
#
# Two refusals, both overridable with -f:
#   - either repo has uncommitted changes (the commits below would be built on top of them)
#   - the move would break a dependent: _resolve_one passes the depending layer's repo index as
#     min_index, so a dependency can only ever resolve to the same or a lower-priority repo.
#     Moving a package UP in priority therefore orphans anything below it that depends on it.

_move_usage() {
  echo "Usage: ppm move <repo/package> <target-repo>"
  echo "  Move a package to another source repo, restowing it if it is installed,"
  echo "  and commit the change in both repos."
  echo ""
  echo "  -f, --force   move despite uncommitted changes or a broken dependency"
}

cli_cmd move "move <repo/package> <target-repo>" "Move a package to another source repo (trackers, claims and commits too)"

cmd_move() {
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force=true ;;
      -*) echo "Unknown flag: $1"; _move_usage; return 1 ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  if [[ ${#args[@]} -eq 0 ]]; then
    _move_usage
    return 0
  fi
  if [[ ${#args[@]} -ne 2 ]]; then
    _move_usage
    return 1
  fi

  local spec="${args[0]}" target="${args[1]%/}"

  # A bare name is ambiguous: it can match a layer in every repo
  if [[ "$spec" != */* ]]; then
    echo "Error: move needs a fully qualified package, e.g. <repo>/$spec"
    return 1
  fi
  local src_repo="${spec%%/*}" pkg="${spec##*/}"
  [[ -n "$src_repo" && -n "$pkg" ]] || { _move_usage; return 1; }

  collect_repos   # also collects every source (GITSRC_NAMES), with or without packages/

  local src_root="$ANFS_SOURCES_HOME/$src_repo" target_root="$ANFS_SOURCES_HOME/$target"
  local src_dir="$src_root/packages/$pkg" dst_dir="$target_root/packages/$pkg"

  [[ -d "$src_dir" ]] || { echo "Error: package '$spec' not found"; return 1; }
  [[ "$target" != "$src_repo" ]] || { echo "Error: $pkg is already in $target"; return 1; }

  if [[ "$(gitsrc_index "$target")" -ge 9999 ]]; then
    echo "Error: '$target' is not a configured source (see 'anfs src list')"
    return 1
  fi
  if [[ ! -d "$target_root" ]]; then
    echo "Error: $target_root does not exist; run 'anfs src update $target' first"
    return 1
  fi
  # -f must never overwrite package sources
  if [[ -e "$dst_dir" ]]; then
    echo "Error: $target/$pkg already exists; remove or rename it first"
    return 1
  fi
  if [[ "$src_repo/$pkg" == anfs/anfs || "$src_repo/$pkg" == anfs/ppm ]] && ! ${force:-false}; then
    echo "Error: $src_repo/$pkg is a base package — install.sh stows it from $PPM_REPO_DIR (use -f to override)"
    return 1
  fi

  # Uncommitted changes: the commits at the end would otherwise sit on top of them
  local dirty=()
  if _move_repo_dirty "$src_root"; then dirty+=("$src_repo"); fi
  if _move_repo_dirty "$target_root"; then dirty+=("$target"); fi
  if [[ ${#dirty[@]} -gt 0 ]]; then
    if ${force:-false}; then
      echo "Uncommitted changes in ${dirty[*]}; committing only packages/$pkg (-f)"
    else
      echo "Error: uncommitted changes in: ${dirty[*]}"
      echo "Commit or stash them, or pass -f (only packages/$pkg is then committed)"
      return 1
    fi
  fi

  # Dependents that could no longer resolve the package from their own repo's priority
  local broken
  broken=$(_move_broken_dependents "$pkg" "$src_repo" "$target")
  if [[ -n "$broken" ]]; then
    echo "Moving $pkg to $target puts it above these packages, which depend on it:"
    echo "$broken" | sed 's/^/  /'
    if ${force:-false}; then
      echo "Continuing anyway (-f); their dependency on $pkg will not resolve"
    else
      echo "A dependency only resolves to the same or a lower-priority repo. Use -f to move anyway."
      return 1
    fi
  fi

  # --- Act ---

  local installed=false
  if meta_is_installed "$src_repo" "$pkg"; then installed=true; fi
  local src_tracker="$PPM_INSTALLED_DIR/$src_repo/$pkg.yml"
  local dst_tracker="$PPM_INSTALLED_DIR/$target/$pkg.yml"

  PPM_CURRENT_PACKAGE="$target/$pkg"
  echo "Move $src_repo/$pkg -> $target/$pkg"

  if $installed; then
    debug "Unstowing from $src_dir"
    unstow_package "$src_dir"
  fi

  mkdir -p "$target_root/packages"
  if ! mv "$src_dir" "$dst_dir"; then
    echo "Error: failed to move $src_dir to $dst_dir"
    $installed && _move_rollback_stow "$src_repo" "$pkg" "$src_dir" || true
    flush_user_messages
    return 1
  fi

  if $installed; then
    # Moving the tracker keeps version, files and installed_deps intact
    mkdir -p "$PPM_INSTALLED_DIR/$target"
    mv "$src_tracker" "$dst_tracker"
    rmdir "$PPM_INSTALLED_DIR/$src_repo" 2>/dev/null || true

    if ! _move_restow "$target" "$pkg" "$dst_dir"; then
      echo "Error: failed to stow $target/$pkg; rolling back"
      mv "$dst_dir" "$src_dir"
      mkdir -p "$PPM_INSTALLED_DIR/$src_repo"
      mv "$dst_tracker" "$src_tracker"
      rmdir "$PPM_INSTALLED_DIR/$target" 2>/dev/null || true
      _move_rollback_stow "$src_repo" "$pkg" "$src_dir"
      flush_user_messages
      return 1
    fi
  else
    user_message "$pkg was not installed; run 'ppm install $pkg' to stow it from $target"
  fi

  _move_claims_rename "$src_repo/$pkg" "$target/$pkg"

  _move_commit "$src_root" "packages/$pkg" "move $pkg to $target" || true
  _move_commit "$target_root" "packages/$pkg" "move $pkg from $src_repo" || true

  PPM_CURRENT_PACKAGE=""
  flush_user_messages
}

# --- Helpers ---

# True when a git repo has staged, unstaged or untracked changes (false for a non-git directory)
_move_repo_dirty() {
  local dir="$1"
  [[ -d "$dir/.git" ]] || return 1
  [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]
}

# Print "repo/pkg" for every package that depends on <pkg> and would no longer resolve it
# after the move. Usage: _move_broken_dependents <pkg> <src_repo> <target_repo>
_move_broken_dependents() {
  local pkg="$1" src_repo="$2" target="$3" i repo dir other
  for i in "${!GITSRC_NAMES[@]}"; do
    repo="${GITSRC_NAMES[$i]}"
    for dir in "$ANFS_SOURCES_HOME/$repo/packages"/*/; do
      [[ -d "$dir" ]] || continue
      other="${dir%/}"; other="${other##*/}"
      # A layer of the package itself is satisfied by its own group (see _resolve_one)
      [[ "$other" == "$pkg" ]] && continue
      meta_depends "$dir" | grep -qxF -- "$pkg" || continue
      _move_resolvable "$pkg" "$i" "$src_repo" "$target" || echo "$repo/$other"
    done
  done
}

# True when a repo at index >= min_index still holds <pkg> once it has left <src_repo>
# Usage: _move_resolvable <pkg> <min_index> <src_repo> <target_repo>
_move_resolvable() {
  local pkg="$1" min_index="$2" src_repo="$3" target="$4" i repo
  for i in "${!GITSRC_NAMES[@]}"; do
    [[ $i -lt $min_index ]] && continue
    repo="${GITSRC_NAMES[$i]}"
    [[ "$repo" == "$src_repo" ]] && continue
    [[ "$repo" == "$target" ]] && return 0
    [[ -d "$ANFS_SOURCES_HOME/$repo/packages/$pkg" ]] && return 0
  done
  return 1
}

# Stow a moved package from its new directory, relinking exactly the files it had before.
# A plain stow_package would be wrong for a layered package: stow -D only removed the links
# pointing into THIS directory, so re-stowing everything would collide with the files a
# higher-priority layer owns. The tracker lists what this layer actually had, so ignore the
# complement — which also leaves `ppm file protect`ed files alone.
# Usage: _move_restow <repo> <pkg> <package_dir>
_move_restow() {
  local repo="$1" pkg="$2" dir="$3" subdir file kept
  kept=$(meta_installed_files "$repo" "$pkg")

  PPM_IGNORE_ARGS=()
  for subdir in home ${PPM_GROUP_ID:-}; do
    [[ -d "$dir/$subdir" ]] || continue
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      grep -qxF -- "$file" <<< "$kept" || PPM_IGNORE_ARGS+=("$(_stow_ignore_arg "$file")")
    done < <(package_links "$dir/$subdir")
  done

  for subdir in home ${PPM_GROUP_ID:-}; do
    [[ -d "$dir/$subdir" ]] || continue
    debug "Stowing $subdir from $dir"
    stow --no-folding ${PPM_IGNORE_ARGS[@]+"${PPM_IGNORE_ARGS[@]}"} -d "$dir" -t "$HOME" "$subdir" || return 1
  done
}

# Restow a package after a failed move put it back. stow aborts the whole operation on the first
# conflict, so the same conflict that failed the move usually fails this too, leaving the package
# in place but unlinked — say so rather than exiting quietly on a half-stowed package.
# Usage: _move_rollback_stow <repo> <pkg> <package_dir>
_move_rollback_stow() {
  _move_restow "$1" "$2" "$3" && return 0
  ppm_fail "$1/$2 is back in $3 but is no longer stowed; run 'ppm install -f $2'" || true
}

# Point claims at the package's new repo, so `ppm file reset` can still find it
# Usage: _move_claims_rename <old repo/pkg> <new repo/pkg>
_move_claims_rename() {
  [[ -s "$PPM_CLAIMS_FILE" ]] || return 0
  O="$1" N="$2" yq -i '
    (.[] | select(.claimant == strenv(O)).claimant) = strenv(N) |
    (.[] | select(.owner == strenv(O)).owner) = strenv(N)
  ' "$PPM_CLAIMS_FILE" 2>/dev/null || debug "move: could not update $PPM_CLAIMS_FILE"
}

# Commit one repo, limited to the package's path so unrelated changes (only possible under -f)
# stay out of the commit. The re-add afterwards resyncs the index: a partial commit leaves the
# pre-hook content staged for any file the pre-commit hook rewrote (the version bump).
# Usage: _move_commit <repo_dir> <pathspec> <message>
_move_commit() {
  local dir="$1" pathspec="$2" msg="$3" name rc=0
  name="$(basename "$dir")"

  if [[ ! -d "$dir/.git" ]]; then
    debug "move: $name is not a git repo, nothing committed"
    return 0
  fi

  if ! git -C "$dir" add -A -- "$pathspec" 2>/dev/null; then
    user_message "Could not stage $pathspec in $name; commit it yourself"
    return 1
  fi
  if git -C "$dir" diff --cached --quiet -- "$pathspec"; then
    debug "move: nothing to commit in $name"
    return 0
  fi

  git -C "$dir" commit -q -m "$msg" -- "$pathspec" || rc=$?
  git -C "$dir" add -A -- "$pathspec" 2>/dev/null || true
  if [[ $rc -ne 0 ]]; then
    user_message "Could not commit in $name; the files have moved, commit them yourself"
    return 1
  fi
  echo "  $name: $msg"
}
