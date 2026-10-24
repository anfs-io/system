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

# The mise tomls the current run linked (absolute, newline-separated): _mise_install_declared
# installs what they name, and nothing a layer left unlinked (another platform's, a lower layer's)
PPM_MISE_TOMLS=""

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
  PPM_MISE_TOMLS=""
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
  local idx=0 prev_name="" qualified package_name failed=false
  echo "Plan for ${#RESOLVE_ORDER[@]} package(s); nothing is changed (-n):"
  for qualified in "${RESOLVE_ORDER[@]}"; do
    package_name="${qualified##*/}"
    if [[ "$package_name" != "$prev_name" ]]; then
      _reset_skip_file
      prev_name="$package_name"
    fi
    echo "Install $qualified"
    plan_package "${RESOLVE_DIRS[$idx]}" || failed=true
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
# Hooks are skipped with -c (config only). A package whose package.yml is invalid (links:, files:)
# is not installed, every error said; the run goes on.
# Arguments: repo_name package_name package_dir
install_single_package() {
  local repo_name="$1" pkg_name="$2" pkg_dir="$3"
  local hook="$pkg_dir/install.sh" run_hooks=true
  [[ -f "$hook" ]] && ! ${config:-false} || run_hooks=false

  PPM_CURRENT_PACKAGE="$repo_name/$pkg_name"
  echo "Install $repo_name/$pkg_name"
  debug "Package dir: $pkg_dir"
  # The version installed before, for package.installed's from (read only when it is emitted)
  local ppm_ev_from=""
  ! _ppm_events_on || ppm_ev_from=$(meta_installed_version "$repo_name" "$pkg_name")
  if ! _pkg_manifest "$pkg_dir"; then
    _ppm_emit failed "$repo_name" "$pkg_name" step=manifest "error=invalid package.yml"
    ppm_fail "invalid package.yml, not installed:$(_pkg_manifest_errors)" || true
    return 0
  fi

  if $run_hooks; then
    (
      source "$hook"
      if type pre_install &>/dev/null; then
        pre_install
      fi
    )
  fi

  # something in the way stops the run (stow_package said what): no hook, no tracker
  if ! stow_package "$pkg_dir" read; then
    _ppm_emit failed "$repo_name" "$pkg_name" step=link "error=something is in the way"
    exit 1
  fi
  meta_cleanup_stale "$repo_name" "$pkg_name" "$pkg_dir" "$STOWED_FILES" "$STOWED_SRCS"
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
  meta_mark_installed "$repo_name" "$pkg_name" "$pkg_dir" "$STOWED_FILES" "$new_brew" "$new_cask" "$STOWED_SRCS"
  _ppm_emit_installed "$repo_name" "$pkg_name" "$ppm_ev_from"
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
            _ppm_emit failed "$repo_name" "$pkg_name" step=pre_remove "error=pre_remove refused"
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
        _ppm_emit_removed "$repo_name" "$pkg_name" meta_mark_removed "$repo_name" "$pkg_name"
        _callback_unregister "$repo_name/$pkg_name"
        PPM_REMOVED+=("$repo_name/$pkg_name")
      fi
    done 3<<< "$matches"
  done
}

# --- Events (lib/anfs/events.sh's anfs_emit, when ppm sourced it; install.sh does not) ---
#
# Into the host scope, one per package layer (a tracker), subject <source>/<package>, data
# package and source and:
#   package.installed  version (as the tracker records it), from (the version before; "" when new).
#                      A reinstall (-r) is one, from its own version
#   package.removed    version (the one removed). Only a layer that was installed
#   package.failed     step (manifest, link, pre_remove), error. The run stops after link and
#                      pre_remove; a failing hook stops it with no event
# Nothing for -n. Emitting never fails ppm: anfs_emit only warns.

# True when an event would be recorded: events.sh is loaded and ANFS_EVENTS is not off
_ppm_events_on() {
  declare -F anfs_emit >/dev/null && [[ "${ANFS_EVENTS:-on}" != off ]]
}

# Usage: _ppm_emit <verb> <repo> <pkg> [key=value...]
_ppm_emit() {
  _ppm_events_on || return 0
  local verb="$1" repo="$2" pkg="$3"
  shift 3
  anfs_emit --host "package.$verb" "$repo/$pkg" "package=$pkg" "source=$repo" "$@"
}

# package.installed, once the tracker is written
# Usage: _ppm_emit_installed <repo> <pkg> <from>
_ppm_emit_installed() {
  _ppm_events_on || return 0
  _ppm_emit installed "$1" "$2" "version=$(meta_installed_version "$1" "$2")" "from=$3"
}

# Run <cmd...> (what drops the tracker), then package.removed when the layer was installed
# Usage: _ppm_emit_removed <repo> <pkg> <cmd...>
_ppm_emit_removed() {
  local repo="$1" pkg="$2" was=false version=""
  shift 2
  if _ppm_events_on && meta_is_installed "$repo" "$pkg"; then
    was=true version=$(meta_installed_version "$repo" "$pkg")
  fi
  "$@"
  ! $was || _ppm_emit removed "$repo" "$pkg" "version=$version"
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

# Install the mise tools named in the mise config (.config/mise/**/*.toml) the run's layers linked
# (PPM_MISE_TOMLS, stow_package): another platform's toml, or a lower layer's that a higher one
# replaced, is not read. One call from $HOME so a project's config in the current directory doesn't
# interfere.
_mise_install_declared() {
  local file tools=""
  while IFS= read -r file; do
    [[ -n "$file" && -f "$file" ]] || continue
    tools=$(_list_add "$tools" $(yq -p toml -oy -r '.tools // {} | keys | .[]' "$file" 2>/dev/null))
  done <<< "$PPM_MISE_TOMLS"
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
# files that are not in the new list, when they still point into the package, and its links out of
# the tree whose dest is gone, while they still point at their src (lib/anfs/link.sh)
# Usage: meta_cleanup_stale <repo_name> <package_name> <package_dir> <new_files> [new_srcs]
meta_cleanup_stale() {
  local repo_name="$1" pkg_name="$2" pkg_dir="$3" new_files="$4" new_srcs="${5:-}" old_files old_srcs dest src
  old_files=$(meta_installed_files "$repo_name" "$pkg_name")
  if [[ -n "$old_files" ]]; then
    anfs_unlink "$pkg_dir" "$HOME" <(printf '%s\n' "$old_files" | grep -vxF -f <(printf '%s\n' "$new_files") || true)
  fi
  old_srcs=$(meta_installed_links "$repo_name" "$pkg_name")
  new_srcs=$'\n'$(printf '%s' "$new_srcs" | cut -f1)$'\n'
  while IFS=$'\t' read -r dest src; do
    [[ -n "$dest" ]] || continue
    case "$new_srcs" in *$'\n'"$dest"$'\n'*) ;; *) anfs_unlink_src "$HOME/$dest" "$src" ;; esac
  done <<< "$old_srcs"
}

# --- Linking (lib/anfs/link.sh, manifest.sh, files.sh) ---
#
# A package says how its files are placed in package.yml (lib/anfs/manifest.sh): home/ is linked
# file by file unless links: makes a directory one link, limits a path to some platforms or links a
# path outside the tree (src:), and files: are copied when missing (then they are the user's).
# home/ is the only directory linked: a macos/ or linux/ beside it is not.

# The manifest of <package_dir> for this platform (ANFS_MF_*, lib/anfs/manifest.sh). 2 when it is
# invalid: ANFS_MF_ERR lists why.
# Usage: _pkg_manifest <package_dir>
_pkg_manifest() {
  local rows=""
  [[ ! -f "$1/package.yml" ]] || rows=$(anfs_manifest_read "$1/package.yml")
  anfs_manifest_plan "$rows" "$1/home" "$(platform)"
}

# ANFS_MF_ERR as the lines of a message
_pkg_manifest_errors() {
  local e
  while IFS= read -r e; do
    [[ -z "$e" ]] || printf '\n  - %s' "$e"
  done <<< "$ANFS_MF_ERR"
}

# The paths a package links (one per line; a directory link is one), from its manifest; every file
# of home/ when the manifest is invalid
_pkg_links() {
  if _pkg_manifest "$1"; then printf '%s' "$ANFS_MF_LINKS"; else package_links "$1/home"; fi
}

# The whole plan of the current manifest (ANFS_MF_*) of <package_dir>, against PPM_SKIP_FILE: the
# links (anfs_link_plan), the copies (anfs_files_plan) and the links out of the tree
# (anfs_link_src_state), as "<kind><TAB><class><TAB><path>[<TAB><detail>]" lines in _PPM_PLAN, kind
# link, copy or src (a src line's detail is its src). Returns 2 when the link plan refuses.
_pkg_plan() {
  local home="$1/home" out rc=0 dest src st
  _PPM_PLAN=""
  if [[ -n "$ANFS_MF_LINKS" && -d "$home" ]]; then
    out=$(anfs_link_plan "$home" "$HOME" <(printf '%s' "$ANFS_MF_LINKS") "$PPM_SKIP_FILE") || rc=$?
    [[ $rc -ne 2 ]] || return 2
    [[ -z "$out" ]] || _PPM_PLAN+=$(printf '%s\n' "$out" | sed 's/^/link	/')$'\n'
  fi
  if [[ -n "$ANFS_MF_COPIES" ]]; then
    rc=0
    out=$(anfs_files_plan "$home" "$HOME" <(printf '%s' "$ANFS_MF_COPIES") "$PPM_SKIP_FILE") || rc=$?
    [[ $rc -ne 2 ]] || return 2
    [[ -z "$out" ]] || _PPM_PLAN+=$(printf '%s\n' "$out" | sed 's/^/copy	/')$'\n'
  fi
  while IFS=$'\t' read -r dest src; do
    [[ -n "$dest" ]] || continue
    if grep -qxF -- "$dest" "$PPM_SKIP_FILE"; then
      st=skip
    else
      st=$(anfs_link_src_state "$HOME/$dest" "$src")
    fi
    _PPM_PLAN+="src"$'\t'"$st"$'\t'"$dest"$'\t'"$src"$'\n'
  done <<< "$ANFS_MF_SRCS"
  # a src: entry wrong on its own (an unset variable...): invalid, skipped; the rest is placed
  local why
  while IFS=$'\t' read -r dest src why; do
    [[ -z "$dest" ]] || _PPM_PLAN+="src"$'\t'"invalid"$'\t'"$dest"$'\t'"$why (src: $src)"$'\n'
  done <<< "$ANFS_MF_INVALID"
  return 0
}

# Whether a plan line's detail is an obstacle on the way, or another package's links: never
# cleared, -f or not
_pkg_blocked() {
  case "$1" in
    *" on the way: "*|*"where a directory goes: "*|"inside a directory link: "*|*"with links into another package: "*) return 0 ;;
  esac
  return 1
}

# Link a package into $HOME as its manifest says, after one plan over everything it places:
# home/'s files and directory links, its links out of the tree (links: {src}) and its copies
# (files:). Everything in the way is listed in one block and nothing is touched unless nothing is
# in the way, or -f cleared it: a link into the sources deleted, anything else moved to the backup
# dir (_backup_file). A copy that differs is the user's and never cleared. Files in PPM_SKIP_FILE
# (a higher layer's, or protected) are skipped.
# Sets STOWED_FILES (the links, a directory link as one path) and STOWED_SRCS ("<dest>\t<src>"),
# globals for the tracker (stow_package must add to PPM_SKIP_FILE in this shell), and adds the mise
# tomls it linked to PPM_MISE_TOMLS. Returns 1 when something is in the way, 2 when the manifest is
# invalid (said with ppm_fail). <read>: the manifest is read already (install_single_package).
# Usage: stow_package <package_dir> [read]
stow_package() {
  local pkg_dir="$1" home="$1/home" kind class rel why bad="" made=""
  STOWED_FILES="" STOWED_SRCS=""
  [[ -n "${PPM_SKIP_FILE:-}" ]] || _reset_skip_file
  if [[ "${2:-}" != read ]] && ! _pkg_manifest "$pkg_dir"; then
    ppm_fail "invalid package.yml, not installed:$(_pkg_manifest_errors)" || true
    return 2
  fi
  debug "Linking $pkg_dir"
  _pkg_plan "$pkg_dir" || return 1

  while IFS=$'\t' read -r kind class rel why; do
    [[ -n "$kind" ]] || continue
    case "$kind:$class" in
      link:other)
        if _pkg_blocked "$why"; then bad+="  * $why: $rel"$'\n'
        elif ${force:-false}; then rm -f -- "$HOME/$rel"
        else bad+="  * existing target is stowed to a different package: $rel => $why"$'\n'; fi
        ;;
      link:conflict|"copy:in the way")
        if _pkg_blocked "$why"; then bad+="  * $why: $rel"$'\n'
        elif ${force:-false}; then _backup_file "$rel"
        else bad+="  * existing target is in the way ($why): $rel"$'\n'; fi
        ;;
      src:wrong|"src:in the way")
        if ${force:-false}; then _backup_file "$rel"
        else bad+="  * existing target is in the way ($class; a link to $why goes there): $rel"$'\n'; fi
        ;;
    esac
  done <<< "$_PPM_PLAN"
  if [[ -n "$bad" ]]; then
    printf 'WARNING! stowing %s would cause conflicts:\n%sAll operations aborted. (ppm install -f moves them aside)\n' \
      "${PPM_CURRENT_PACKAGE:-$pkg_dir}" "$bad" >&2
    return 1
  fi

  if [[ -n "$ANFS_MF_LINKS" && -d "$home" ]]; then
    anfs_link_apply "$home" "$HOME" <(printf '%s' "$ANFS_MF_LINKS") "$PPM_SKIP_FILE" >/dev/null || return 1
  fi
  if [[ -n "$ANFS_MF_COPIES" ]]; then
    anfs_files_apply "$home" "$HOME" <(printf '%s' "$ANFS_MF_COPIES") "$PPM_SKIP_FILE" >/dev/null || return 1
  fi
  while IFS=$'\t' read -r kind class rel why; do
    [[ "$kind" == src && "$class" != skip ]] || continue
    if [[ "$class" == invalid ]]; then
      ppm_fail "invalid link ~/$rel, skipped: $why" || true
      continue
    fi
    STOWED_SRCS+="$rel"$'\t'"$why"$'\n'
    case "$class" in
      ok) ;;
      "missing src") echo "  missing src ~/$rel -> $why (not linked)" ;;
      *) anfs_link_one "$why" "$HOME/$rel" || return 1 ;;
    esac
  done <<< "$_PPM_PLAN"

  # What this layer placed, for the tracker and for the layers below it
  STOWED_FILES=$(printf '%s' "$ANFS_MF_LINKS" | grep -vxF -f "$PPM_SKIP_FILE" || true)
  { printf '%s' "$ANFS_MF_LINKS$ANFS_MF_COPIES"; printf '%s' "$ANFS_MF_SRCS" | cut -f1; } |
    grep -vxF -f "$PPM_SKIP_FILE" >> "$PPM_SKIP_FILE" || true
  _collect_mise_tomls "$home" "$STOWED_FILES"
}

# The mise tomls (.config/mise/**/*.toml) among the paths a layer linked, a directory link's
# included, into PPM_MISE_TOMLS (absolute, the package's files): what _mise_install_declared reads
# Usage: _collect_mise_tomls <home> <linked paths>
_collect_mise_tomls() {
  local home="$1" f
  while IFS= read -r f; do
    case "$f" in
      .config/mise/*.toml) PPM_MISE_TOMLS+="$home/$f"$'\n' ;;
      .config/mise|.config/mise/*|.config|.)
        [[ -d "$home/$f" && ! -L "$home/$f" ]] || continue
        PPM_MISE_TOMLS+=$(find "$home/$f" -name '*.toml' 2>/dev/null | grep -F "$home/.config/mise/" || true)$'\n'
        ;;
    esac
  done <<< "$2"
}

# Unlink a package from $HOME: the tracker's files (a directory link is one of them) and its links
# out of the tree, each only while it still points into the package or at its src; without a
# tracker, what the manifest links; with neither, every file under home/. Copies (files:) stay:
# they are the user's.
unstow_package() {
  local pkg_dir="$1" files="" srcs="" repo pkg dest src
  pkg="${pkg_dir##*/}"
  repo="${pkg_dir%/packages/*}"
  repo="${repo##*/}"
  if meta_is_installed "$repo" "$pkg" 2>/dev/null; then
    files=$(meta_installed_files "$repo" "$pkg")
    srcs=$(meta_installed_links "$repo" "$pkg")
  elif _pkg_manifest "$pkg_dir"; then
    files="$ANFS_MF_LINKS" srcs="$ANFS_MF_SRCS"
  elif [[ -d "$pkg_dir/home" ]]; then
    anfs_unlink_tree "$pkg_dir/home" "$HOME"
  fi
  if [[ -n "$files" && -d "$pkg_dir/home" ]]; then
    anfs_unlink "$pkg_dir/home" "$HOME" <(printf '%s\n' "$files")
  fi
  while IFS=$'\t' read -r dest src; do
    [[ -z "$dest" ]] || anfs_unlink_src "$HOME/$dest" "$src"
  done <<< "$srcs"
  return 0
}

# Start PPM_SKIP_FILE again from the user-protected baseline (files `ppm file protect` detached).
# stow_package skips what it lists, under -f too, so protected files are never touched. Each layer
# adds what it placed, so a lower layer of the same name skips what a higher one linked.
_reset_skip_file() {
  if [[ -z "${PPM_SKIP_FILE:-}" ]]; then
    PPM_SKIP_FILE=$(mktemp "${TMPDIR:-/tmp}/ppm-skip.XXXXXX")
  fi
  _protected_list > "$PPM_SKIP_FILE"
}

# The plan stow_package would carry out, for `ppm install -n`: one line per path (links, copies,
# links out of the tree, and what this platform leaves out), and what -f would do with what is in
# the way. Adds to PPM_SKIP_FILE as an install would. Returns 1 when the install would stop, or
# the manifest is invalid.
plan_package() {
  local pkg_dir="$1" kind class rel why word stop=false p plats
  [[ -n "${PPM_SKIP_FILE:-}" ]] || _reset_skip_file
  if ! _pkg_manifest "$pkg_dir"; then
    printf '  invalid package.yml: not installed%s\n' "$(_pkg_manifest_errors)"
    return 1
  fi
  _pkg_plan "$pkg_dir" || return 1
  while IFS=$'\t' read -r kind class rel why; do
    [[ -n "$kind" ]] || continue
    word="$class"
    case "$kind:$class" in
      link:other|link:conflict|"copy:in the way")
        if _pkg_blocked "$why"; then stop=true
        else
          [[ "$class" == other ]] && why="$why; -f removes the link" || why="$why; -f moves it aside"
          ${force:-false} || stop=true
        fi
        ;;
      copy:missing) word=copy ;;
      copy:differs) why="yours; left as is" ;;
      src:ok) word=keep why="-> $why" ;;
      src:missing) word=link why="-> $why" ;;
      "src:missing src") why="-> $why; not linked" ;;
      src:wrong|"src:in the way")
        why="a link to $why goes there; -f moves it aside"
        ${force:-false} || stop=true
        ;;
      src:skip) why="" ;;
      src:invalid) why="$why; skipped" ;;
    esac
    printf '  %-9s %s%s\n' "$word" "~/$rel" "${why:+  ($why)}"
  done <<< "$_PPM_PLAN"
  while IFS=$'\t' read -r p plats; do
    [[ -z "$p" ]] || printf '  %-9s %s  (%s)\n' off "~/$p" "$plats"
  done <<< "$ANFS_MF_OFF"
  { printf '%s' "$ANFS_MF_LINKS$ANFS_MF_COPIES"; printf '%s' "$ANFS_MF_SRCS" | cut -f1; } |
    grep -vxF -f "$PPM_SKIP_FILE" >> "$PPM_SKIP_FILE" || true
  ! $stop
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
