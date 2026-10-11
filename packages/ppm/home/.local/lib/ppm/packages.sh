#!/usr/bin/env bash
# Packages: discovery, dependency resolution, package.yml metadata, install trackers,
# and the list/show/path/deps commands
# Compatible with bash 3.2 (no associative arrays)

# --- Discovery ---

# Collect "repo/pkg" names into PACKAGES, optionally filtered to specific repos
# Usage: collect_packages [repo1 repo2 ...]
collect_packages() {
  local filter_repos
  filter_repos=("$@")
  PACKAGES=()

  # If no filter provided, get all repo names from sources
  if [[ ${#filter_repos[@]} -eq 0 ]]; then
    collect_repos
    filter_repos=(${REPO_NAMES[@]+"${REPO_NAMES[@]}"})
  fi

  for repo_name in ${filter_repos[@]+"${filter_repos[@]}"}; do
    local repo_path="$ANFS_SOURCES_HOME/$repo_name/packages"
    [[ -d "$repo_path" ]] || continue

    while IFS= read -r dir; do
      PACKAGES+=("$repo_name/$(basename "$dir")")
    done < <(ls -d "$repo_path"/*/ 2>/dev/null)
  done
}

# --- Categories ---
#
# A package joins categories through `categories: [ai, ...]` in its package.yml. A category is
# only metadata: names, layering and depends: never see it. A name is in a category when any of
# its layers says so, so a user repo can add its own packages to a category.

# package.yml of every package in the loaded sources, one path per line, in source order
_package_metas() {
  collect_packages
  local p meta
  for p in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
    meta="$ANFS_SOURCES_HOME/${p%%/*}/packages/${p#*/}/package.yml"
    [[ -f "$meta" ]] && echo "$meta"
  done
}

# Evaluate a yq expression over many package.yml files in one call. One malformed file stops yq,
# so on failure fall back to a call per file, skipping and naming the ones yq can't read.
# Usage: _yq_metas <expression> <file>...
_yq_metas() {
  local expr="$1" out meta
  shift
  [[ $# -gt 0 ]] || return 0
  if out=$(yq -N -r "$expr" "$@" 2>/dev/null); then
    [[ -z "$out" ]] || printf '%s\n' "$out"
    return 0
  fi
  for meta in "$@"; do
    yq -N -r "$expr" "$meta" 2>/dev/null || echo "Warning: skipping unreadable $meta" >&2
  done
}

# Every layer ("repo/pkg") that declares a category, in source order
# Usage: category_members <category>
category_members() {
  local metas=() meta
  while IFS= read -r meta; do metas+=("$meta"); done < <(_package_metas)
  # flatten also accepts `categories: ai`
  C="$1" _yq_metas 'select([.categories // []] | flatten | any_c(. == strenv(C))) | filename' \
    ${metas[@]+"${metas[@]}"} | sed "s|^$ANFS_SOURCES_HOME/||; s|/packages/|/|; s|/package.yml\$||"
}

# Every category declared in the loaded sources, with the number of packages in it
categories_list() {
  local metas=() meta
  while IFS= read -r meta; do metas+=("$meta"); done < <(_package_metas)
  # One count per name, however many layers declare it
  _yq_metas 'filename as $f | [.categories // []] | flatten | .[] | . + " " + ($f | sub(".*/packages/", "") | sub("/package.yml$", ""))' \
    ${metas[@]+"${metas[@]}"} | sort -u | awk '{ n[$1]++ } END { for (c in n) printf "%s  %d\n", c, n[c] }' | sort
}

# --- Expansion ---

# Expand "repo/" (every package in a source) and "@category" (every name in a category) into
# packages, skipping those this platform doesn't support. Other arguments pass through.
# Sets EXPANDED_PACKAGES array in caller's scope
expand_packages() {
  local verb="$1"; shift
  EXPANDED_PACKAGES=()
  local arg label p dir supported
  for arg in "$@"; do
    if [[ "$arg" == */ ]] && is_repo_name "${arg%/}"; then
      label="repo '${arg%/}'"
      collect_packages "${arg%/}"
    elif [[ "$arg" == @?* ]]; then
      label="category '${arg#@}'"
      collect_repos
      PACKAGES=()
      while IFS= read -r p; do
        [[ -n "$p" ]] && PACKAGES+=("$p")
      done < <(category_members "${arg#@}" | sed 's|.*/||' | awk '!seen[$0]++')
    else
      EXPANDED_PACKAGES+=("$arg")
      continue
    fi
    [[ ${#PACKAGES[@]} -eq 0 ]] && { echo "Error: No packages found in $label"; exit 1; }

    supported=()
    for p in "${PACKAGES[@]}"; do
      # A category's bare name is judged by its highest-priority layer
      if [[ "$p" == */* ]]; then
        dir="$ANFS_SOURCES_HOME/${p%%/*}/packages/${p#*/}"
      else
        dir=$(find_package_dir "$p") && dir="${dir##*$'\t'}"
      fi
      if meta_supported "$dir"; then
        supported+=("$p")
      else
        echo "Skipping $p: not supported on $(platform)"
      fi
    done
    [[ ${#supported[@]} -gt 0 ]] || { echo "Error: No packages in $label support $(platform)"; exit 1; }
    PACKAGES=("${supported[@]}")

    if ! $force && ! ${yes:-false}; then
      echo "About to $verb all packages (${#PACKAGES[@]}) from $label:"
      printf '  %s\n' "${PACKAGES[@]}"
      read -p "Continue? [y/N] " confirm
      [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi
    EXPANDED_PACKAGES+=("${PACKAGES[@]}")
  done
}

# Find all package directories for a given package specifier
# "repo/pkg" matches only that repo; "pkg" matches every repo containing it, in source order.
# Multiple matches are layers: higher-priority layers stow first and lower layers skip their files.
# Outputs one "repo_index<TAB>repo_name<TAB>pkg_dir" line per match; returns 1 if none
# Optional second arg restricts search to repos at index >= min_index
# (enforces layered dependency rule: repos can only depend on same or lower-priority repos)
# The lookup is anfs's (lib/anfs/resolve.sh), over the sources collect_repos loaded.
# Usage: find_package_dirs <package_spec> [min_index]
find_package_dirs() {
  anfs_find packages "$@"
}

# Find the first (highest-priority) package directory for a given package specifier
# Outputs "repo_index<TAB>repo_name<TAB>pkg_dir" on success
# Usage: find_package_dir <package_spec> [min_index]
find_package_dir() {
  local matches
  matches=$(find_package_dirs "$@") || return 1
  echo "${matches%%$'\n'*}"
}

# --- Dependency graph ---

# Resolve the full dependency tree for a list of packages into, deps first:
#   RESOLVE_ORDER  — "repo/pkg" in install order
#   RESOLVE_DIRS   — parallel array of package directories
# Layers of one name land next to each other, highest priority first, so install() stows them
# against one shared ignore list. The algorithm is anfs's (anfs_resolve in lib/anfs/resolve.sh),
# which wsm uses for spaces too.
# Usage: resolve_deps pkg1 [pkg2 ...]
resolve_deps() {
  anfs_resolve packages meta_depends "$@"
  RESOLVE_ORDER=(${ANFS_ORDER[@]+"${ANFS_ORDER[@]}"})
  RESOLVE_DIRS=(${ANFS_ORDER_DIRS[@]+"${ANFS_ORDER_DIRS[@]}"})
}

# --- package.yml ---

# Read the depends list from package.yml
# Returns one dependency per line (suitable for while-read loops)
# Usage: meta_depends <package_dir>
meta_depends() {
  local meta="$1/package.yml"
  [[ -f "$meta" ]] || return 0
  yq -r '.depends[]? // ""' "$meta" 2>/dev/null
}

# Read the version from package.yml
# Usage: meta_version <package_dir>
meta_version() {
  local meta="$1/package.yml"
  [[ -f "$meta" ]] || return 0
  yq -r '.version // ""' "$meta" 2>/dev/null
}

# Categories a package declares, one per line
# Usage: meta_categories <package_dir>
meta_categories() {
  local meta="$1/package.yml"
  [[ -f "$meta" ]] || return 0
  yq -r '.categories[]? // ""' "$meta" 2>/dev/null
}

# Platforms a package supports (macos, linux, debian, fedora); nothing means every platform
# Usage: meta_platforms <package_dir>
meta_platforms() {
  local meta="$1/package.yml"
  [[ -f "$meta" ]] || return 0
  yq -r '.platforms[]? // ""' "$meta" 2>/dev/null
}

# True when the package supports this machine; "linux" covers every Linux distro
# Usage: meta_supported <package_dir>
meta_supported() {
  local platforms current p
  platforms=$(meta_platforms "$1")
  [[ -z "$platforms" ]] && return 0
  current=$(platform)
  for p in $platforms; do
    [[ "$p" == "$current" ]] && return 0
    [[ "$p" == "linux" && "$current" != "macos" ]] && return 0
  done
  return 1
}

# Dependencies a package declares for one manager (brew, cask or system), resolved for this platform.
# A list applies on every platform. A map is keyed by platform: the exact platform first, then
# "linux" on any Linux distro. Returns 1 for a system map that names other Linux distros but
# neither this one nor "linux", so callers can fail instead of skipping silently.
# Usage: meta_deps <package_dir> <brew|cask|system>
meta_deps() {
  local meta="$1/package.yml" key="$2" type current
  [[ -f "$meta" ]] || return 0

  type=$(K="$key" yq -r '.[strenv(K)] | type' "$meta" 2>/dev/null)
  case "$type" in
    '!!seq')
      K="$key" yq -r '.[strenv(K)][]' "$meta" 2>/dev/null
      ;;
    '!!map')
      current=$(platform)
      if K="$key" P="$current" yq -e '.[strenv(K)] | has(strenv(P))' "$meta" >/dev/null 2>&1; then
        K="$key" P="$current" yq -r '.[strenv(K)][strenv(P)][]?' "$meta" 2>/dev/null
      elif [[ "$current" != "macos" ]] && K="$key" yq -e '.[strenv(K)] | has("linux")' "$meta" >/dev/null 2>&1; then
        K="$key" yq -r '.[strenv(K)].linux[]?' "$meta" 2>/dev/null
      elif [[ "$key" == "system" && "$current" != "macos" ]] &&
           K="$key" yq -e '.[strenv(K)] | keys | map(select(. != "macos")) | length > 0' "$meta" >/dev/null 2>&1; then
        return 1
      fi
      ;;
  esac
  return 0
}

# --- Declared resources ---
#
# Top-level package.yml keys ppm itself owns. Any other key is a declared resource: the installer
# hands it to ppm_resource_<key>, a function another package contributes through PPM_LIB_DIR.
# A key with no handler is not an error, so an unhandled key is a debug line rather than a warning.
# `meta:` is ppm's but ppm never reads it: a free-form map for other packages to read, such as the
# `meta.agent` ids core/psm syncs skills to. Put package metadata there, not in a top-level key.
PPM_CORE_KEYS="version author depends platforms categories brew cask system meta"

# Top-level keys of a package.yml that ppm core does not own, one per line
# Usage: meta_extra_keys <package_dir>
meta_extra_keys() {
  local meta="$1/package.yml" key
  [[ -f "$meta" ]] || return 0
  for key in $(yq -r 'keys | .[]' "$meta" 2>/dev/null); do
    [[ " $PPM_CORE_KEYS " == *" $key "* ]] || echo "$key"
  done
}

# Add items to a newline-separated list, skipping empty items and duplicates (keeps first-seen order)
# Usage: list=$(_list_add "$list" item...)
_list_add() {
  local list="$1" item
  shift
  for item in "$@"; do
    [[ -n "$item" ]] || continue
    grep -qxF -- "$item" <<< "$list" || list="${list:+$list$'\n'}$item"
  done
  printf '%s' "$list"
}

# --- Install trackers ($PPM_INSTALLED_DIR/<repo>/<pkg>.yml) ---

# Path to a package's tracker file
_tracker_path() {
  echo "$PPM_INSTALLED_DIR/$1/$2.yml"
}

# Record a package as installed with its stowed files and the brew formulas and casks ppm
# installed for it. Dependencies recorded by an earlier install are kept, so a later install that
# finds them already present doesn't lose track of who installed them.
# Usage: meta_mark_installed <repo_name> <package_name> <package_dir> <files> [brew_names] [cask_names]
# files are newline-separated; brew/cask names are whitespace-separated
meta_mark_installed() {
  local repo_name="$1" pkg_name="$2" pkg_dir="$3" stowed_files="$4" new_brew="${5:-}" new_cask="${6:-}"
  local tracker
  tracker=$(_tracker_path "$repo_name" "$pkg_name")
  local version
  version=$(meta_version "$pkg_dir")
  [[ -z "$version" ]] && version="unknown"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Read before the tracker is rewritten
  local brew cask resources=""
  brew=$(_list_add "$(meta_installed_deps "$repo_name" "$pkg_name" brew)" $new_brew)
  cask=$(_list_add "$(meta_installed_deps "$repo_name" "$pkg_name" cask)" $new_cask)
  # Resource handlers run before this write, so their record has to survive it
  [[ -f "$tracker" ]] && resources=$(yq -r 'select(.resources != null) | {"resources": .resources}' "$tracker" 2>/dev/null)

  mkdir -p "$(dirname "$tracker")"

  {
    echo "version: $version"
    echo "installed_at: \"$timestamp\""
    if [[ -n "$stowed_files" ]]; then
      echo "files:"
      echo "$stowed_files" | while IFS= read -r f; do
        [[ -n "$f" ]] && echo "  - $f"
      done
    fi
    if [[ -n "$brew$cask" ]]; then
      echo "installed_deps:"
      [[ -z "$brew" ]] || { echo "  brew:"; printf '    - %s\n' $brew; }
      [[ -z "$cask" ]] || { echo "  cask:"; printf '    - %s\n' $cask; }
    fi
    [[ -z "$resources" ]] || printf '%s\n' "$resources"
  } > "$tracker"
}

# Record a path a resource handler created, so remove can find it without re-reading package.yml
# (the package directory may be gone by then). Seeds the tracker when the handler runs before
# meta_mark_installed has written one, which is the normal order on a first install.
# Usage: meta_add_resource <repo_name> <package_name> <key> <path>
meta_add_resource() {
  local tracker
  tracker=$(_tracker_path "$1" "$2")
  mkdir -p "$(dirname "$tracker")"
  [[ -s "$tracker" ]] || echo '{}' > "$tracker"
  K="$3" P="$4" yq -i '.resources[strenv(K)] = ((.resources[strenv(K)] // []) + [strenv(P)] | unique)' "$tracker"
}

# Paths a resource handler recorded for a package, one per line
# Usage: meta_resources <repo_name> <package_name> <key>
meta_resources() {
  local tracker
  tracker=$(_tracker_path "$1" "$2")
  [[ -f "$tracker" ]] || return 0
  K="$3" yq -r '.resources[strenv(K)][]?' "$tracker" 2>/dev/null
}

# Resource keys recorded for a package, one per line
# Usage: meta_resource_keys <repo_name> <package_name>
meta_resource_keys() {
  local tracker
  tracker=$(_tracker_path "$1" "$2")
  [[ -f "$tracker" ]] || return 0
  yq -r '.resources // {} | keys | .[]' "$tracker" 2>/dev/null
}

# Remove the tracker file for a package
# Usage: meta_mark_removed <repo_name> <package_name>
meta_mark_removed() {
  local tracker
  tracker=$(_tracker_path "$1" "$2")
  rm -f "$tracker"
  # Clean up empty repo directory
  local repo_dir="$PPM_INSTALLED_DIR/$1"
  [[ -d "$repo_dir" ]] && rmdir "$repo_dir" 2>/dev/null || true
}

# Check if a package is installed (tracker exists)
# Usage: meta_is_installed <repo_name> <package_name>
meta_is_installed() {
  local tracker
  tracker=$(_tracker_path "$1" "$2")
  [[ -f "$tracker" ]]
}

# Get installed version of a package
# Usage: meta_installed_version <repo_name> <package_name>
meta_installed_version() {
  local tracker
  tracker=$(_tracker_path "$1" "$2")
  [[ -f "$tracker" ]] || return 0
  yq -r '.version // ""' "$tracker" 2>/dev/null
}

# Read previously stowed files from tracker
# Usage: meta_installed_files <repo_name> <package_name>
meta_installed_files() {
  local tracker
  tracker=$(_tracker_path "$1" "$2")
  [[ -f "$tracker" ]] || return 0
  yq -r '.files[]? // ""' "$tracker" 2>/dev/null
}

# Brew formulas or casks that ppm installed for a package, one per line
# Usage: meta_installed_deps <repo_name> <package_name> <brew|cask>
meta_installed_deps() {
  local tracker
  tracker=$(_tracker_path "$1" "$2")
  [[ -f "$tracker" ]] || return 0
  M="$3" yq -r '.installed_deps[strenv(M)][]?' "$tracker" 2>/dev/null
}

# Add a file to a package's install tracker (creating the tracker if needed)
_tracker_add_file() {
  local repo="$1" pkg="$2" pkg_dir="$3" rel="$4"
  local tracker
  tracker=$(_tracker_path "$repo" "$pkg")
  if [[ -f "$tracker" ]]; then
    F="$rel" yq -i '.files = ((.files // []) + [strenv(F)] | unique)' "$tracker"
  else
    meta_mark_installed "$repo" "$pkg" "$pkg_dir" "$(package_links "$pkg_dir/home")"
  fi
}

# Remove a file from a package's install tracker
_tracker_remove_file() {
  local tracker
  tracker=$(_tracker_path "$1" "$2")
  [[ -f "$tracker" ]] || return 0
  F="$3" yq -i 'del(.files[] | select(. == strenv(F)))' "$tracker"
}

# --- Commands ---

# List the packages found in the cached repositories
# Optionally filter by a substring pattern; "@category" lists that category, a bare "@" the categories
cmd_list() {
  local filter="${1:-}" installed_only=false

  case "$filter" in
    @) collect_repos; categories_list; return ;;
    @*) collect_repos; category_members "${filter#@}"; return ;;
  esac

  if [[ "$filter" == "--installed" ]]; then
    installed_only=true
    filter="${2:-}"
  fi

  if $installed_only; then
    if [[ ! -d "$PPM_INSTALLED_DIR" ]]; then
      echo "No packages installed (or tracking not yet enabled)"
      return
    fi
    for tracker in "$PPM_INSTALLED_DIR"/*/*.yml; do
      [[ -f "$tracker" ]] || continue
      local pkg_name="${tracker%.yml}"
      pkg_name="${pkg_name#$PPM_INSTALLED_DIR/}"
      local version
      version=$(yq -r '.version // "?"' "$tracker" 2>/dev/null)
      local line="$pkg_name  $version"
      if [[ -z "$filter" ]] || [[ "$line" == *"$filter"* ]]; then
        echo "$line"
      fi
    done
    return
  fi

  collect_packages
  for pkg in ${PACKAGES[@]+"${PACKAGES[@]}"}; do
    if [[ -z "$filter" ]] || [[ "$pkg" == *"$filter"* ]]; then
      echo "$pkg"
    fi
  done
}

# Show package information: version, dependencies, install status and home/ tree
cmd_show() {
  if [[ $# -eq 0 ]]; then
    echo "Error: show requires a package name"
    echo "Usage: ppm show [repo/]package"
    exit 1
  fi

  collect_repos

  local pkg="$1" matches repo_index repo_name package_dir
  local package_name="${pkg##*/}"
  matches=$(find_package_dirs "$pkg") || { echo "Error: package '$pkg' not found"; exit 1; }

  while IFS=$'\t' read -r -u 3 repo_index repo_name package_dir; do
    echo "package: $repo_name/$package_name"
    echo ""

    local version
    version=$(meta_version "$package_dir")
    if [[ -n "$version" ]]; then
      echo "Version: $version"
    fi

    local categories
    categories=$(meta_categories "$package_dir")
    [[ -z "$categories" ]] || echo "Categories: $(echo $categories)"

    local deps
    deps=$(meta_depends "$package_dir")
    if [[ -n "$deps" ]]; then
      echo "Dependencies:"
      for dep in $deps; do
        echo "  - $dep"
      done
      echo ""
    fi

    local platforms_list manager names label shown=false
    platforms_list=$(meta_platforms "$package_dir")
    if [[ -n "$platforms_list" ]]; then
      echo "Platforms: $(echo $platforms_list)"
      shown=true
    fi
    for manager in brew cask system; do
      case "$manager" in
        brew) label="Brew" ;;
        cask) label="Cask" ;;
        system) label="System ($(platform))" ;;
      esac
      names=$(meta_deps "$package_dir" "$manager") || names="none declared for $(platform)"
      if [[ -n "$names" ]]; then
        echo "$label: $(echo $names)"
        shown=true
      fi
    done
    ! $shown || echo ""

    if meta_is_installed "$repo_name" "$package_name"; then
      local inst_version
      inst_version=$(meta_installed_version "$repo_name" "$package_name")
      echo "Status: installed (v${inst_version})"

      for manager in brew cask; do
        names=$(meta_installed_deps "$repo_name" "$package_name" "$manager")
        [[ -z "$names" ]] || echo "Installed by ppm ($manager): $(echo $names)"
      done

      local key
      while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        names=$(meta_resources "$repo_name" "$package_name" "$key")
        [[ -z "$names" ]] || echo "Resources ($key): $(echo $names)"
      done < <(meta_resource_keys "$repo_name" "$package_name")

      local inst_files
      inst_files=$(meta_installed_files "$repo_name" "$package_name")
      if [[ -n "$inst_files" ]]; then
        echo ""
        echo "Stowed files:"
        echo "$inst_files" | while IFS= read -r f; do
          [[ -n "$f" ]] && echo "  ~/$f"
        done
      fi
    else
      echo "Status: not installed"
    fi
    echo ""

    if [[ -d "$package_dir/home" ]]; then
      echo "home/"
      if command -v tree &>/dev/null; then
        tree -a --noreport "$package_dir/home" | tail -n +2
      else
        find "$package_dir/home" -type f | sed "s|$package_dir/home/|  |"
      fi
      echo ""
    fi
  done 3<<< "$matches"
}

# Output the path to a package directory (the highest-priority layer)
cmd_path() {
  local verbose=false
  [[ "${1:-}" == "-v" ]] && { verbose=true; shift; }

  if [[ $# -eq 0 ]]; then
    echo "Error: path requires a package name"
    echo "Usage: ppm path [-v] [repo/]package"
    exit 1
  fi

  collect_repos

  local pkg="$1" matches repo_index repo_name package_dir
  matches=$(find_package_dirs "$pkg") || { echo "Error: package '$pkg' not found" >&2; exit 1; }

  if $verbose && [[ "$matches" == *$'\n'* ]]; then
    echo "Warning: package '$pkg' found in multiple repos, using first match:" >&2
    while IFS=$'\t' read -r repo_index repo_name package_dir; do
      echo "  $repo_name/${pkg##*/}" >&2
    done <<< "$matches"
  fi

  matches="${matches%%$'\n'*}"
  echo "${matches##*$'\t'}"
}

# Show resolved dependency tree without installing
cmd_deps() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: ppm deps <package> [package...]"
    exit 1
  fi

  collect_repos
  resolve_deps "$@"

  echo "Install order (${#RESOLVE_ORDER[@]} packages):"
  for pkg in "${RESOLVE_ORDER[@]}"; do
    echo "  $pkg"
  done
}
