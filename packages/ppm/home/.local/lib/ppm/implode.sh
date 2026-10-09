#!/usr/bin/env bash
# The implode command: remove everything ppm has put on this machine
#
# Removes every installed package the way `ppm remove` would (hooks, unstow, the brew formulas and
# casks ppm installed, declared resources), dependents before their dependencies. core/anfs
# depends on the whole toolkit, so it goes first; ppm keeps running from what it already loaded.
# Then deletes ppm's own directories. Left alone:
#   - the bootstrap software install.sh brews untracked (Homebrew, stow, yq, mise, bash)
#   - system packages (apt/dnf), which ppm never removes
#   - what other tools manage (pcm containers, psm skills, wsm spaces); run their implode first,
#     or `anfs implode`, which does. A pcm with running containers refuses removal in its
#     pre_remove hook, which stops this run.
#   - the sources under ~/.local/share/anfs: they are anfs's (anfs implode deletes them)
#   - space contents: the wsm resource handler only deletes a space under -f, and implode never
#     passes it

cmd_implode() {
  local yes="${yes:-false}" arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) yes=true ;;
      *) echo "Usage: ppm implode [-y]"; return 1 ;;
    esac
  done

  local -a installed=()
  local tracker repo pkg
  for tracker in "$PPM_INSTALLED_DIR"/*/*.yml; do
    [[ -f "$tracker" ]] || continue
    repo=$(basename "$(dirname "$tracker")")
    pkg=$(basename "$tracker" .yml)
    installed+=("$repo/$pkg")
  done

  echo "ppm implode removes:"
  echo "  packages     ${#installed[@]} installed (${installed[*]:-none})"
  local dir
  for dir in "$PPM_STATE_HOME" "$PPM_DATA_HOME" "$PPM_CONFIG_HOME" "$PPM_CACHE_HOME" "$PPM_LIB_DIR"; do
    [[ -e "$dir" ]] && echo "  directory    ${dir/#$HOME/~}"
  done
  echo "Kept: Homebrew, stow, yq, mise and system packages"

  if ! $yes; then
    [[ -t 0 ]] || { echo "ppm: implode deletes everything ppm installed; pass -y to confirm without a terminal"; return 1; }
    local answer
    read -r -p "Implode ppm? [y/N] " answer
    [[ "$answer" == [yY]* ]] || { echo "Nothing removed"; return 1; }
  fi

  local -a order=()
  collect_repos
  _implode_order ${installed[@]+"${installed[@]}"}

  # remover reads these through dynamic scoping; force stays false so a refusing pre_remove
  # (pcm with containers running) stops the run instead of being overridden
  local force=false keep_tracker=false
  local qualified rel tracked_dirs=""
  # Every directory a tracked file sits in: stow --no-folding made them real, and unstowing
  # leaves them behind empty
  for qualified in ${order[@]+"${order[@]}"}; do
    while IFS= read -r rel; do
      [[ "$rel" == */* ]] && tracked_dirs="$tracked_dirs${rel%/*}"$'\n'
    done < <(meta_installed_files "${qualified%%/*}" "${qualified#*/}")
  done
  for qualified in ${order[@]+"${order[@]}"}; do
    repo="${qualified%%/*}" pkg="${qualified#*/}"
    if find_package_dir "$qualified" >/dev/null 2>&1; then
      remover "$qualified"
    fi
    # The package's repo is gone, or remover found no layer: undo what the tracker recorded
    meta_is_installed "$repo" "$pkg" && _implode_orphan "$repo" "$pkg"
  done
  flush_user_messages

  # Links into the sources that no tracker knew about (a tracker lost, a file moved by hand)
  _implode_sweep_links
  _implode_prune_dirs "$tracked_dirs"

  for dir in "$PPM_STATE_HOME" "$PPM_DATA_HOME" "$PPM_CACHE_HOME" "$PPM_CONFIG_HOME" "$PPM_LIB_DIR"; do
    [[ -e "$dir" ]] || continue
    echo "Deleting ${dir/#$HOME/~}"
    rm -rf "${dir:?}"
  done
  rm -f "$BIN_DIR/ppm"
  rm -f /tmp/ppm-messages.* 2>/dev/null || true
  echo "ppm imploded. Open a new shell: this one still has ppm's functions loaded."
}

# Order installed packages for removal into `order`: a package goes only once no package still
# waiting depends on it by name
_implode_order() {
  local -a pending=("$@") next=()
  local qualified other dep dir blocked progress

  while [[ ${#pending[@]} -gt 0 ]]; do
    next=()
    progress=false
    for qualified in "${pending[@]}"; do
      blocked=false
      for other in "${pending[@]}"; do
        [[ "$other" == "$qualified" ]] && continue
        dir=$(find_package_dir "$other" 2>/dev/null) || continue
        dir=$(cut -f3 <<< "$dir")
        while IFS= read -r dep; do
          [[ -n "$dep" ]] || continue
          [[ "$dep" == "$qualified" || "$dep" == "${qualified#*/}" ]] && blocked=true
        done < <(meta_depends "$dir")
        $blocked && break
      done
      if $blocked; then
        next+=("$qualified")
      else
        order+=("$qualified")
        progress=true
      fi
    done
    # A dependency cycle among what is left: remove the rest in any order
    $progress || { order+=("${next[@]}"); break; }
    pending=(${next[@]+"${next[@]}"})
  done
}

# A tracker with no package to remove it through: unlink its recorded files, drop the tracker
_implode_orphan() {
  local repo="$1" pkg="$2" rel
  echo "Remove $repo/$pkg (package gone; unlinking recorded files)"
  while IFS= read -r rel; do
    [[ -n "$rel" && -L "$HOME/$rel" ]] && rm -f "$HOME/$rel"
  done < <(meta_installed_files "$repo" "$pkg")
  meta_mark_removed "$repo" "$pkg"
}

# Remove the directories stow created that are now empty, deepest first, up to $HOME
_implode_prune_dirs() {
  local rel dir
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    dir="$HOME/$rel"
    while [[ "$dir" != "$HOME" && "$dir" == "$HOME"/* ]]; do
      rmdir "$dir" 2>/dev/null || break
      dir="${dir%/*}"
    done
  done < <(printf '%s' "$1" | sort -ru)
}

# Remove every symlink under $HOME that points into $ANFS_SOURCES_HOME. stow writes relative
# links, so match on the sources dir's $HOME-relative path rather than resolving each link
_implode_sweep_links() {
  local rel="${ANFS_SOURCES_HOME#$HOME/}" link
  [[ "$rel" != "$ANFS_SOURCES_HOME" ]] || return 0
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    _link_points_into "$link" "$ANFS_SOURCES_HOME" || continue
    echo "Removing leftover link ${link/#$HOME/~}"
    rm -f "$link"
  done < <(find "$HOME" \( -name .git -o -name node_modules -o -name Library -o -path "$ANFS_DATA_HOME" \) -prune \
             -o -type l -lname "*$rel/*" -print 2>/dev/null)
}
