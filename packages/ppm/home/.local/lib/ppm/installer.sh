#!/usr/bin/env bash
# Installing and removing packages: the install/remove commands, the hook lifecycle, and linking
# a package's files into $HOME (lib/anfs/link.sh)
#
# BOOTSTRAP SET: install.sh sources this under whatever bash started it, which on a vanilla Mac is
# 3.2. Keep it parseable and runnable there: no bash 4+ syntax (see lib/anfs/bash.sh)

# The files to skip, one per line (a temp file, for lib/anfs/link.sh). Layers of the same package
# name (e.g. user/git, stack/git) add to one list so lower-priority layers skip files linked by
# higher ones. cmd_install starts it again when moving on to a different package name.
PPM_SKIP_FILE=""

# Brew formulas and casks installed by the current run (newline-separated), for the trackers
PPM_NEW_BREW=""
PPM_NEW_CASK=""

# Packages remover() actually removed this run (repo/pkg), for the post-run callbacks
PPM_REMOVED=()

# --- Commands ---

# Install one or more packages as requested by the user
cmd_install() {
  # -n: the plan, and nothing else (no pull, no brew, no hooks, no links, no tracker)
  local dry=${dry_run:-false}
  $dry || update_ppm_if_needed
  $dry || update_brew_if_needed
  expand_packages "install" "$@"
  # Reinstall only re-stows files: bypass pre_remove guards, and keep trackers and dependencies
  if ! $dry && $reinstall; then force=true keep_tracker=true remover "${EXPANDED_PACKAGES[@]}"; fi

  collect_repos

  if ! $skip_deps; then
    resolve_deps "${EXPANDED_PACKAGES[@]}"
  else
    # Skip deps mode: just resolve the requested packages, no transitive deps
    RESOLVE_ORDER=()
    RESOLVE_DIRS=()
    local pkg matches repo_index repo_name pkg_dir
    for pkg in "${EXPANDED_PACKAGES[@]}"; do
      matches=$(find_package_dirs "$pkg") || { echo "Error: package '$pkg' not found"; exit 1; }
      while IFS=$'\t' read -r repo_index repo_name pkg_dir; do
        RESOLVE_ORDER+=("$repo_name/${pkg##*/}")
        RESOLVE_DIRS+=("$pkg_dir")
      done <<< "$matches"
    done
  fi

  local i unsupported=""
  for i in "${!RESOLVE_DIRS[@]}"; do
    if ! meta_supported "${RESOLVE_DIRS[$i]}"; then
      unsupported="$unsupported"$'\n'"  ${RESOLVE_ORDER[$i]} (platforms: $(echo $(meta_platforms "${RESOLVE_DIRS[$i]}")))"
    fi
  done
  if [[ -n "$unsupported" ]]; then
    echo "Error: not supported on $(platform):$unsupported"
    exit 1
  fi

  if $dry; then
    _install_plan
    return
  fi

  echo "Installing ${#RESOLVE_ORDER[@]} package(s):"
  for pkg in "${RESOLVE_ORDER[@]}"; do
    echo "  $pkg"
  done
  echo ""

  # Declared dependencies first, so hooks can rely on them
  if ! ${config:-false}; then
    _install_declared_deps || { flush_user_messages; exit 1; }
  fi

  # Install in topological order
  local idx=0 prev_name=""
  for qualified in "${RESOLVE_ORDER[@]}"; do
    local package_name="${qualified##*/}"

    # Layers of the same package name share one skip list
    if [[ "$package_name" != "$prev_name" ]]; then
      _reset_skip_file
      prev_name="$package_name"
    fi

    install_single_package "${qualified%%/*}" "$package_name" "${RESOLVE_DIRS[$idx]}"
    idx=$((idx + 1))
  done

  ${config:-false} || _mise_install_declared
  _run_callbacks install ${RESOLVE_ORDER[@]+"${RESOLVE_ORDER[@]}"}
  flush_user_messages
}

# `ppm install -n`: each resolved layer's plan, as an install would carry it out (lib/anfs/link.sh),
# changing nothing. Exits 1 when the install would stop on something in the way.
_install_plan() {
  local idx=0 prev_name="" qualified package_name subdir failed=false
  echo "Plan for ${#RESOLVE_ORDER[@]} package(s); nothing is changed (-n):"
  for qualified in "${RESOLVE_ORDER[@]}"; do
    package_name="${qualified##*/}"
    if [[ "$package_name" != "$prev_name" ]]; then
      _reset_skip_file
      prev_name="$package_name"
    fi
    echo "Install $qualified"
    for subdir in home ${PPM_GROUP_ID:-}; do
      plan_subdir "${RESOLVE_DIRS[$idx]}" "$subdir" || failed=true
    done
    idx=$((idx + 1))
  done
  if $failed; then
    echo "The install would stop: something is in the way (-f moves what it can aside)"
    exit 1
  fi
}

# Remove one or more packages as requested by the user
cmd_remove() {
  expand_packages "remove" "$@"
  echo "About to remove: ${EXPANDED_PACKAGES[*]}"
  anfs_confirm "remove takes away ${EXPANDED_PACKAGES[*]} and the software ppm installed for them" "Remove?"
  remover "${EXPANDED_PACKAGES[@]}"
  _run_callbacks remove ${PPM_REMOVED[@]+"${PPM_REMOVED[@]}"}
  flush_user_messages
}

# --- Lifecycle ---

# Install a single resolved package: pre_install, stow, install_<os>, post_install, track
# Hooks are skipped with -c (config only)
# Arguments: repo_name package_name package_dir
install_single_package() {
  local repo_name="$1" pkg_name="$2" pkg_dir="$3"
  local hook="$pkg_dir/install.sh" run_hooks=true
  [[ -f "$hook" ]] && ! ${config:-false} || run_hooks=false

  PPM_CURRENT_PACKAGE="$repo_name/$pkg_name"
  echo "Install $repo_name/$pkg_name"
  debug "Package dir: $pkg_dir"

  if $run_hooks; then
    (
      source "$hook"
      if type pre_install &>/dev/null; then
        pre_install
      fi
    )
  fi

  stow_package "$pkg_dir"
  meta_cleanup_stale "$repo_name" "$pkg_name" "$pkg_dir" "$STOWED_FILES"
  _reload_stowed_libs "$STOWED_FILES"
  _install_declared_resources "$repo_name" "$pkg_name" "$pkg_dir"

  if $run_hooks; then
    (
      source "$hook"
      local func_name="install_$(os)"
      if type "$func_name" &>/dev/null; then
        "$func_name"
      fi
      if type post_install &>/dev/null; then
        post_install
      fi
    )
  fi

  # Write tracker after all phases succeed. Record each declared formula/cask that ppm installed,
  # in this run or earlier for another package, so it is removed only when its last package goes.
  # Software the user installed themselves is never recorded.
  local manager name new="" new_brew="" new_cask="" installed_now
  for manager in brew cask; do
    new=""
    [[ "$manager" == "brew" ]] && installed_now="$PPM_NEW_BREW" || installed_now="$PPM_NEW_CASK"
    for name in $(meta_deps "$pkg_dir" "$manager"); do
      if grep -qxF -- "$name" <<< "$installed_now" || _dep_recorded_by_ppm "$manager" "$name"; then
        new="$new $name"
      fi
    done
    [[ "$manager" == "brew" ]] && new_brew="$new" || new_cask="$new"
  done
  meta_mark_installed "$repo_name" "$pkg_name" "$pkg_dir" "$STOWED_FILES" "$new_brew" "$new_cask"
}

# Remove packages by name; "pkg" removes every layer, "repo/pkg" only that one
# Arguments: package_spec [package_spec ...]
remover() {
  collect_repos
  local pkg pkg_name matches repo_index repo_name pkg_dir has_hook

  for pkg in "$@"; do
    pkg_name="${pkg##*/}"
    matches=$(find_package_dirs "$pkg") || continue

    # fd 3 keeps hooks that read stdin from consuming the match list
    while IFS=$'\t' read -r -u 3 repo_index repo_name pkg_dir; do
      PPM_CURRENT_PACKAGE="$repo_name/$pkg_name"
      echo "Remove $repo_name/$pkg_name"

      [[ -f "$pkg_dir/install.sh" ]] && has_hook=true || has_hook=false

      # Phase 1: pre_remove hook — a non-zero return aborts the removal unless -f
      if $has_hook; then
        if ! ( source "$pkg_dir/install.sh"; ! type pre_remove &>/dev/null || pre_remove ); then
          if ${force:-false}; then
            echo "Warning: pre_remove failed for $repo_name/$pkg_name; continuing (-f)"
          else
            echo "Aborted: $repo_name/$pkg_name not removed (use -f to force)"
            exit 1
          fi
        fi
      fi

      # Phase 2: unstow
      unstow_package "$pkg_dir"

      # Phase 3: OS-specific remove + post_remove
      if $has_hook; then
        (
          source "$pkg_dir/install.sh"
          func_name="remove_$(os)"
          type $func_name &>/dev/null && $func_name || true
          type post_remove &>/dev/null && post_remove || true
        )
      fi

      # Phase 4: dependencies ppm installed that nothing else needs, then the tracker
      # (skipped by reinstall, which installs the package again right away)
      if ! ${keep_tracker:-false}; then
        _remove_declared_resources "$repo_name" "$pkg_name"
        _remove_installed_deps "$repo_name" "$pkg_name" "$pkg_dir"
        _backup_restore "$repo_name/$pkg_name"
        meta_mark_removed "$repo_name" "$pkg_name"
        _callback_unregister "$repo_name/$pkg_name"
        PPM_REMOVED+=("$repo_name/$pkg_name")
      fi
    done 3<<< "$matches"
  done
}

# --- Post-run callbacks (registered with ppm_register_callback, see core.sh) ---

# Call every registered callback once with the packages this run installed or removed. The loop is
# anfs's (anfs_callbacks_run): one that fails is reported and the rest still run. Skipped with -c,
# like hooks.
# Usage: _run_callbacks <install|remove> <repo/pkg>...
_run_callbacks() {
  local event="$1"
  shift
  ${config:-false} && return 0
  [[ $# -gt 0 ]] || return 0
  _callbacks_migrate
  anfs_callbacks_run ppm "$event" "$@"
}

# How ppm runs a handler (anfs_callbacks_run calls this in a subshell): the handler is a function
# of the registering package's install.sh, sourced like a hook with PPM_CURRENT_PACKAGE set to
# that package. A package that is not installed any more is skipped.
# Usage: ppm_callback_invoke <repo/pkg> <function> <install|remove> <repo/pkg>...
ppm_callback_invoke() {
  local qualified="$1" fn="$2" dir
  shift 2
  dir="$ANFS_SOURCES_HOME/${qualified%%/*}/packages/${qualified#*/}"
  if [[ ! -f "$(_tracker_path "${qualified%%/*}" "${qualified#*/}")" || ! -f "$dir/install.sh" ]]; then
    debug "Skipping $qualified's callback $fn: not installed, or no install.sh"
    return 0
  fi
  PPM_CURRENT_PACKAGE="$qualified"
  debug "Calling $qualified's $fn $1 ($(( $# - 1 )) package(s))"
  source "$dir/install.sh"
  if ! declare -f "$fn" >/dev/null; then
    ppm_fail "registered callback '$fn' is not defined in install.sh" || true
    return 0
  fi
  ( "$fn" "$@" ) || ppm_fail "callback '$fn' failed" || true
  return 0
}

# --- Declared resources (any package.yml key ppm core does not own) ---
#
# ppm owns version, author, depends, platforms, brew, cask, system and meta. Any other top-level
# key is handed to ppm_resource_<key>, a function a package contributes by stowing a file into
# PPM_LIB_DIR. The handler gets <repo> <pkg> <package_dir> and records what it created with
# meta_add_resource, so removal can find it without the package directory.
#
# `meta:` is free-form metadata other packages read (core/psm reads `meta.agent`), never a resource.
# A key with no handler is deliberately silent. The cost is that a misspelled resource key does
# nothing quietly, which --debug will tell you about.

# Usage: _install_declared_resources <repo_name> <package_name> <package_dir>
_install_declared_resources() {
  local repo="$1" pkg="$2" dir="$3" key handler
  ${config:-false} && return 0

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    handler="ppm_resource_$key"
    if ! declare -f "$handler" >/dev/null; then
      # `meta:` is where free-form metadata belongs, so an unowned top-level key is either a
      # resource whose provider is missing or a typo. Both deserve saying out loud: the
      # alternative is a package that declares something and silently does nothing.
      # (install_single_package already set PPM_CURRENT_PACKAGE, so this is prefixed with it;
      # the trailing space matters, user_message strips each argument's leading whitespace.)
      user_message "declares '$key' but nothing handles it. Add the package providing $handler " \
                   "to depends:, or move it under meta: if it is only metadata."
      continue
    fi
    debug "Handling '$key' resources for $repo/$pkg"
    # One handler failing must not abandon the run or skip the tracker write
    "$handler" "$repo" "$pkg" "$dir" || ppm_fail "$repo/$pkg: '$key' resources failed" || true
  done < <(meta_extra_keys "$dir")
}

# Usage: _remove_declared_resources <repo_name> <package_name>
# Reads the keys back from the tracker: the package directory may already be gone.
_remove_declared_resources() {
  local repo="$1" pkg="$2" key handler
  ${config:-false} && return 0

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    handler="ppm_resource_${key}_remove"
    if ! declare -f "$handler" >/dev/null; then
      user_message "'$key' resources were left in place: $(echo $(meta_resources "$repo" "$pkg" "$key"))"
      continue
    fi
    PPM_CURRENT_PACKAGE="$repo/$pkg"
    "$handler" "$repo" "$pkg" || ppm_fail "$repo/$pkg: removing '$key' resources failed" || true
  done < <(meta_resource_keys "$repo" "$pkg")
}

# Re-source library files a package just stowed into PPM_LIB_DIR.
#
# `ppm` sources that directory once at startup, so a package installed in this very run — the
# usual case for `ppm install <thing that depends on wsm>` — would otherwise contribute neither
# its commands nor its resource handlers until the next invocation.
# Usage: _reload_stowed_libs <newline-separated stowed files>
_reload_stowed_libs() {
  local rel lib
  [[ -n "$1" ]] || return 0
  while IFS= read -r rel; do
    case "$rel" in
      .local/lib/ppm/*.sh) ;;
      *) continue ;;
    esac
    lib="$HOME/$rel"
    [[ -f "$lib" ]] || continue
    debug "Sourcing newly stowed library: $rel"
    source "$lib"
  done <<< "$1"
}

# --- Declared dependencies (package.yml brew, cask, system) ---

# Install what the resolved packages declare, one batch per manager, only what is missing.
# System packages first (one sudo prompt), then brew formulas and casks (Homebrew owner only).
# Sets PPM_NEW_BREW / PPM_NEW_CASK to what this run installed.
_install_declared_deps() {
  local dir names system_all="" brew_all="" cask_all="" missing i
  PPM_NEW_BREW=""
  PPM_NEW_CASK=""

  for i in "${!RESOLVE_DIRS[@]}"; do
    dir="${RESOLVE_DIRS[$i]}"
    if ! names=$(meta_deps "$dir" system); then
      ppm_fail "${RESOLVE_ORDER[$i]} declares system packages, but none for $(platform)"
      return 1
    fi
    system_all=$(_list_add "$system_all" $names)
    brew_all=$(_list_add "$brew_all" $(meta_deps "$dir" brew))
    cask_all=$(_list_add "$cask_all" $(meta_deps "$dir" cask))
  done
  debug "Declared system: $(echo $system_all) | brew: $(echo $brew_all) | cask: $(echo $cask_all)"

  missing=$(system_pkg_missing $system_all)
  if [[ -n "$missing" ]]; then
    echo "System packages to install: $(echo $missing)"
    system_pkg_install $missing || { ppm_fail "Failed to install system packages: $(echo $missing)"; return 1; }
  fi

  missing=$(brew_missing $brew_all)
  if [[ -n "$missing" ]]; then
    brew_require_owner "brew install $(echo $missing)" || return 1
    echo "Brew formulas to install: $(echo $missing)"
    brew_trust_taps $missing
    brew install --yes $missing </dev/null || { ppm_fail "brew install failed: $(echo $missing)"; return 1; }
    PPM_NEW_BREW="$missing"
  fi

  missing=$(cask_missing $cask_all)
  if [[ -n "$missing" ]]; then
    brew_require_owner "brew install --cask $(echo $missing)" || return 1
    echo "Casks to install: $(echo $missing)"
    brew_trust_taps $missing
    brew install --yes --cask $missing </dev/null || { ppm_fail "brew install --cask failed: $(echo $missing)"; return 1; }
    PPM_NEW_CASK="$missing"
  fi
}

# Install the mise tools named in the resolved packages' mise config (.config/mise/**/*.toml),
# in one call from $HOME so a project's config in the current directory doesn't interfere
_mise_install_declared() {
  local dir file tools=""
  for dir in "${RESOLVE_DIRS[@]}"; do
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      tools=$(_list_add "$tools" $(yq -p toml -oy -r '.tools // {} | keys | .[]' "$file" 2>/dev/null))
    done < <(find "$dir/home/.config/mise" ${PPM_GROUP_ID:+"$dir/$PPM_GROUP_ID/.config/mise"} -name '*.toml' 2>/dev/null)
  done
  [[ -n "$tools" ]] || return 0

  if ! command -v mise >/dev/null 2>&1; then
    ppm_fail "mise is not installed; these tools were not installed: $(echo $tools)"
    return 0
  fi
  echo "mise install $(echo $tools)"
  (cd "$HOME" && mise install $tools </dev/null) || ppm_fail "mise install failed for: $(echo $tools)"
}

# Uninstall the brew formulas and casks ppm installed for a package, unless another installed
# package also installed or declares them. System packages are never removed.
_remove_installed_deps() {
  local repo="$1" pkg="$2" pkg_dir="$3" manager name uninstall system_names
  PPM_CURRENT_PACKAGE="$repo/$pkg"

  system_names=$(meta_deps "$pkg_dir" system 2>/dev/null) || system_names=""
  [[ -z "$system_names" ]] || user_message "System packages were left installed: $(echo $system_names)"

  for manager in brew cask; do
    uninstall=""
    for name in $(meta_installed_deps "$repo" "$pkg" "$manager"); do
      if _dep_needed_elsewhere "$manager" "$name" "$repo/$pkg"; then
        debug "Keeping $name: another installed package needs it"
      else
        uninstall="$uninstall $name"
      fi
    done
    [[ -n "$uninstall" ]] || continue

    if ! brew_is_owner; then
      user_message "Not removed (Homebrew is owned by $(brew_owner 2>/dev/null || echo nobody)):$uninstall"
      continue
    fi
    echo "Uninstalling $manager:$uninstall"
    if [[ "$manager" == "cask" ]]; then
      brew uninstall --cask $uninstall </dev/null || user_message "Could not uninstall cask:$uninstall"
    else
      brew uninstall $uninstall </dev/null || user_message "Could not uninstall:$uninstall (another formula may depend on it)"
    fi
  done
}

# True when any tracker records <name> as installed by ppm
# Usage: _dep_recorded_by_ppm <brew|cask> <name>
_dep_recorded_by_ppm() {
  local manager="$1" name="$2" tracker qualified
  for tracker in "$PPM_INSTALLED_DIR"/*/*.yml; do
    [[ -f "$tracker" ]] || continue
    qualified="${tracker#$PPM_INSTALLED_DIR/}"
    qualified="${qualified%.yml}"
    grep -qxF -- "$name" <<< "$(meta_installed_deps "${qualified%%/*}" "${qualified#*/}" "$manager")" && return 0
  done
  return 1
}

# True when another installed package recorded or declares <name> for <manager>
# Usage: _dep_needed_elsewhere <brew|cask> <name> <repo/pkg to ignore>
_dep_needed_elsewhere() {
  local manager="$1" name="$2" self="$3" tracker qualified repo pkg dir
  for tracker in "$PPM_INSTALLED_DIR"/*/*.yml; do
    [[ -f "$tracker" ]] || continue
    qualified="${tracker#$PPM_INSTALLED_DIR/}"
    qualified="${qualified%.yml}"
    [[ "$qualified" == "$self" ]] && continue
    repo="${qualified%%/*}"
    pkg="${qualified#*/}"

    grep -qxF -- "$name" <<< "$(meta_installed_deps "$repo" "$pkg" "$manager")" && return 0
    dir="$ANFS_SOURCES_HOME/$repo/packages/$pkg"
    [[ -d "$dir" ]] && grep -qxF -- "$name" <<< "$(meta_deps "$dir" "$manager" 2>/dev/null)" && return 0
  done
  return 1
}

# Remove the links a previous install of this layer made that it no longer ships: the tracker's
# files that are not in the new list, when they still point into the package (lib/anfs/link.sh)
# Usage: meta_cleanup_stale <repo_name> <package_name> <package_dir> <new_files>
meta_cleanup_stale() {
  local repo_name="$1" pkg_name="$2" pkg_dir="$3" new_files="$4" old_files
  old_files=$(meta_installed_files "$repo_name" "$pkg_name")
  [[ -n "$old_files" ]] || return 0
  anfs_unlink "$pkg_dir" "$HOME" <(printf '%s\n' "$old_files" | grep -vxF -f <(printf '%s\n' "$new_files") || true)
}

# --- Linking (lib/anfs/link.sh) ---

# Link a package's home/ and $PPM_GROUP_ID subdirs into $HOME
# Files in PPM_SKIP_FILE (a higher-priority layer's, or protected) are skipped
# Sets STOWED_FILES to the newline-separated files this layer links
# (a global, not stdout: stow_subdir must add to PPM_SKIP_FILE in this shell)
stow_package() {
  local pkg_dir="$1" subdir file
  STOWED_FILES=""
  [[ -n "${PPM_SKIP_FILE:-}" ]] || _reset_skip_file

  for subdir in home ${PPM_GROUP_ID:-}; do
    [[ -d "$pkg_dir/$subdir" ]] || continue

    while IFS= read -r file; do
      if [[ -n "$file" ]] && ! grep -qxF -- "$file" "$PPM_SKIP_FILE"; then
        STOWED_FILES="${STOWED_FILES:+${STOWED_FILES}$'\n'}${file}"
      fi
    done < <(package_links "$pkg_dir/$subdir")

    stow_subdir "$pkg_dir" "$subdir"
  done
}

# Unlink a package's home/ and $PPM_GROUP_ID subdirs from $HOME: the tracker's files when there is
# one, else every file the package has. Only links into the package go.
unstow_package() {
  local pkg_dir="$1" subdir files="" repo pkg
  pkg="${pkg_dir##*/}"
  repo="${pkg_dir%/packages/*}"
  repo="${repo##*/}"
  meta_is_installed "$repo" "$pkg" 2>/dev/null && files=$(meta_installed_files "$repo" "$pkg")

  for subdir in home ${PPM_GROUP_ID:-}; do
    [[ -d "$pkg_dir/$subdir" ]] || continue
    if [[ -n "$files" ]]; then
      anfs_unlink "$pkg_dir/$subdir" "$HOME" <(printf '%s\n' "$files")
    else
      anfs_unlink_tree "$pkg_dir/$subdir" "$HOME"
    fi
  done
  return 0
}

# Start PPM_SKIP_FILE again from the user-protected baseline (files `ppm file protect` detached).
# stow_subdir skips what it lists, under -f too, so protected files are never touched. Each layer
# adds its files, so a lower layer of the same name skips what a higher one linked.
_reset_skip_file() {
  if [[ -z "${PPM_SKIP_FILE:-}" ]]; then
    PPM_SKIP_FILE=$(mktemp "${TMPDIR:-/tmp}/ppm-skip.XXXXXX")
  fi
  _protected_list > "$PPM_SKIP_FILE"
}

# Link a package subdirectory into $HOME and add its files to PPM_SKIP_FILE. The plan comes first
# (lib/anfs/link.sh): what is ours is kept or replaced, and with -f what is in the way is cleared
# (a link into the sources deleted, anything else moved to the backup dir). Without -f anything in
# the way stops the install, every file named.
stow_subdir() {
  local pkg_dir="$1" subdir="$2"
  local full_path="$pkg_dir/$subdir" list plan rc=0 class rest rel why bad=""

  [[ -d "$full_path" ]] || return 0
  [[ -n "${PPM_SKIP_FILE:-}" ]] || _reset_skip_file
  debug "Linking $subdir from $pkg_dir"

  list=$(package_links "$full_path")
  plan=$(anfs_link_plan "$full_path" "$HOME" <(printf '%s\n' "$list") "$PPM_SKIP_FILE") || rc=$?
  [[ $rc -ne 2 ]] || return 1

  if [[ $rc -ne 0 ]]; then
    while IFS=$'\t' read -r class rest; do
      rel="${rest%%$'\t'*}" why="${rest#*$'\t'}"
      # what is in the way on the path (a file, a link out of $HOME) is never cleared, -f or not
      case "$why" in *" on the way: "*|*"where a directory goes: "*) class=blocked ;; esac
      case "$class" in
        blocked) bad="$bad  * $why: $rel"$'\n' ;;
        other)
          if ${force:-false}; then rm -f -- "$HOME/$rel"; else bad="$bad  * existing target is stowed to a different package: $rel => $why"$'\n'; fi
          ;;
        conflict)
          if ${force:-false}; then _backup_file "$rel"; else bad="$bad  * existing target is in the way ($why): $rel"$'\n'; fi
          ;;
      esac
    done <<< "$plan"
    if [[ -n "$bad" ]]; then
      printf 'WARNING! stowing %s would cause conflicts:\n%sAll operations aborted. (ppm install -f moves them aside)\n' \
        "${PPM_CURRENT_PACKAGE:-$pkg_dir}" "$bad" >&2
      return 1
    fi
  fi

  anfs_link_apply "$full_path" "$HOME" <(printf '%s\n' "$list") "$PPM_SKIP_FILE" >/dev/null || return 1
  printf '%s\n' "$list" | grep -vxF -f "$PPM_SKIP_FILE" >> "$PPM_SKIP_FILE" || true
}

# The plan stow_subdir would carry out, for `ppm install -n`: one line per file, and what -f would
# do with what is in the way. Adds the files to PPM_SKIP_FILE as an install would. Returns 1 when
# the install would stop on a conflict.
plan_subdir() {
  local pkg_dir="$1" subdir="$2"
  local full_path="$pkg_dir/$subdir" list plan rc=0 class rest rel why

  [[ -d "$full_path" ]] || return 0
  [[ -n "${PPM_SKIP_FILE:-}" ]] || _reset_skip_file
  list=$(package_links "$full_path")
  plan=$(anfs_link_plan "$full_path" "$HOME" <(printf '%s\n' "$list") "$PPM_SKIP_FILE") || rc=$?
  [[ $rc -ne 2 ]] || return 1
  while IFS=$'\t' read -r class rest; do
    [[ -n "$class" ]] || continue
    rel="${rest%%$'\t'*}" why=""
    [[ "$rest" != *$'\t'* ]] || why="${rest#*$'\t'}"
    case "$class:$why" in
      *" on the way: "*|*"where a directory goes: "*) ;;
      other:*) why="$why; -f removes the link" ;;
      conflict:*) why="$why; -f moves it aside" ;;
    esac
    printf '  %-9s %s%s\n' "$class" "~/$rel" "${why:+  ($why)}"
  done <<< "$plan"
  printf '%s\n' "$list" | grep -vxF -f "$PPM_SKIP_FILE" >> "$PPM_SKIP_FILE" || true
  [[ $rc -eq 0 ]] || ${force:-false}
}

# List the files of a package directory, relative to it (.DS_Store is never linked)
package_links() {
  local path="$1"
  (cd "$path" && find . \( -type f -o -type l \) ! -name .DS_Store | sed 's|^\./||')
}

# Move ~/<rel> into $PPM_STATE_HOME/backup/files, recorded in the manifest ("repo/pkg<TAB>rel")
# against the package being installed. Bootstrap set (bash 3.2), like the rest of this file.
_backup_file() {
  local rel="$1" dir="$PPM_STATE_HOME/backup" dest n=1
  dest="$dir/files/$rel"
  # The first backup of a path is the file that was there before ppm, and the one a restore
  # puts back: a later one is kept beside it, never over it
  while [[ -e "$dest" || -L "$dest" ]]; do
    dest="$dir/files/$rel.$n"
    n=$((n + 1))
  done
  mkdir -p "${dest%/*}"
  mv "$HOME/$rel" "$dest"
  [[ "$dest" != "$dir/files/$rel" ]] ||
    printf '%s\t%s\n' "${PPM_CURRENT_PACKAGE:-}" "$rel" >> "$dir/manifest"
  user_message "Moved your existing ~/$rel aside (-f) to ${dest/#$HOME/~}; removing the package puts it back"
}

# Put backed-up files back where they were: those recorded against <repo/pkg>, or all of them
# when it is empty. A path something else occupies keeps its backup for a later run — unless a
# suffix is given (implode, which is about to delete the backup dir): then it lands at
# <path><suffix> instead, so nothing of the user's is ever dropped.
# Usage: _backup_restore [repo/pkg] [suffix]
_backup_restore() {
  local owner="${1:-}" suffix="${2:-}" dir="$PPM_STATE_HOME/backup"
  local manifest="$dir/manifest" kept="" pkg rel src target n
  [[ -f "$manifest" ]] || return 0

  while IFS=$'\t' read -r pkg rel; do
    [[ -n "$rel" ]] || continue
    if [[ -n "$owner" && "$pkg" != "$owner" ]]; then
      kept="$kept$pkg"$'\t'"$rel"$'\n'
      continue
    fi
    src="$dir/files/$rel"
    [[ -e "$src" || -L "$src" ]] || continue
    target="$HOME/$rel"
    if [[ -e "$target" || -L "$target" ]]; then
      if [[ -z "$suffix" ]]; then
        kept="$kept$pkg"$'\t'"$rel"$'\n'
        continue
      fi
      target="$HOME/$rel$suffix" n=1
      while [[ -e "$target" || -L "$target" ]]; do
        target="$HOME/$rel$suffix.$n"
        n=$((n + 1))
      done
    fi
    mkdir -p "${target%/*}"
    mv "$src" "$target"
    user_message "Restored your original ${target/#$HOME/~}"
  done < "$manifest"

  if [[ -n "$kept" ]]; then
    printf '%s' "$kept" > "$manifest"
  else
    rm -f "$manifest"
  fi
}
