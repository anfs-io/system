#!/usr/bin/env bash
# File ownership — take individual files out of ppm's management
#
# `ppm file claim` copies a stowed file into your own repo/package and stows it from there.
# `ppm file add` is claim for files no package owns yet, with the target named up front.
# `ppm file reset` removes the copy and restores the original package's link.
# `ppm file protect` turns a file into a plain local copy that ppm's stow will never touch
#   again (no repo needed; machine-specific). `ppm file unprotect` hands it back to ppm.
# Claims are recorded in $PPM_INSTALLED_DIR/claims.yml:
#   .config/git/ignore:
#     claimant: user/git
#     owner: stack/git       # empty if the file was not managed by ppm
# Protected paths (relative to $HOME) are recorded in $PPM_INSTALLED_DIR/protected.yml as a
# plain list; the installer seeds them into stow's ignore list so they are left alone.

PPM_CLAIMS_FILE="$PPM_INSTALLED_DIR/claims.yml"
PPM_PROTECTED_FILE="$PPM_INSTALLED_DIR/protected.yml"

_file_usage() {
  echo "Usage: ppm file <add|claim|reset|protect|unprotect> <file...>"
  echo "  add <repo/package> <file...>                    Move files into repo/package and stow them"
  echo "                                                  (the package is created if needed; use dir/* for a directory)"
  echo "  claim <file...> [--repo REPO] [--package NAME]  Move files into REPO/NAME and stow them"
  echo "                                                  (default: \$PPM_DEFAULT_REPO/<owning package>;"
  echo "                                                  --package also accepts repo/package)"
  echo "  reset <file...>                                 Remove claimed files and restore the original links"
  echo "  protect <file...>                               Detach files from ppm; keep a local copy stow won't touch"
  echo "  unprotect <file...>                             Let ppm manage the files again"
}

# Entry point for `ppm file` (dispatched from main)
cmd_file() {
  PPM_DEFAULT_REPO="${PPM_DEFAULT_REPO:-$PPM_USER_REPO_ALIAS}"

  local repo="" package="" args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:?--repo requires a value}"; shift ;;
      --repo=*) repo="${1#*=}" ;;
      --package) package="${2:?--package requires a value}"; shift ;;
      --package=*) package="${1#*=}" ;;
      -*) echo "Unknown flag: $1"; _file_usage; exit 1 ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  local subcommand="${args[0]:-}"
  local files=(${args[@]+"${args[@]:1}"})

  # add: the first argument is the target, and it must name both repo and package
  if [[ "$subcommand" == "add" ]]; then
    if [[ -n "$repo$package" ]]; then
      echo "Error: add takes its target as <repo/package>, not --repo or --package"
      exit 1
    fi
    package="${files[0]:-}"
    if [[ "$package" != */* ]]; then
      echo "Error: add needs a target of the form <repo/package>"
      _file_usage
      exit 1
    fi
    files=(${files[@]+"${files[@]:1}"})
  fi

  # --package repo/pkg is shorthand for --repo repo --package pkg
  if [[ "$package" == */* ]]; then
    if [[ -n "$repo" ]]; then
      echo "Error: --package $package already names a repo; drop --repo"
      exit 1
    fi
    repo="${package%%/*}"
    package="${package#*/}"
    if [[ -z "$repo" || -z "$package" || "$package" == */* ]]; then
      echo "Error: expected <repo/package>, got '$repo/$package'"
      exit 1
    fi
  fi

  case "$subcommand" in
    add|claim|reset)
      if [[ ${#files[@]} -eq 0 ]]; then
        _file_usage
        exit 1
      fi
      if [[ "$subcommand" == "reset" && -n "$repo$package" ]]; then
        echo "Error: reset does not accept --repo or --package"
        exit 1
      fi

      collect_repos
      local f status=0
      for f in "${files[@]}"; do
        if [[ "$subcommand" != "reset" ]]; then
          _file_claim "$f" "$repo" "$package" || status=1
        else
          _file_reset "$f" || status=1
        fi
      done
      PPM_CURRENT_PACKAGE=""
      flush_user_messages
      return $status
      ;;
    protect|unprotect)
      if [[ ${#files[@]} -eq 0 ]]; then
        _file_usage
        exit 1
      fi
      if [[ -n "$repo$package" ]]; then
        echo "Error: $subcommand does not accept --repo or --package"
        exit 1
      fi

      local f status=0
      for f in "${files[@]}"; do
        if [[ "$subcommand" == "protect" ]]; then
          _file_protect "$f" || status=1
        else
          _file_unprotect "$f" || status=1
        fi
      done
      PPM_CURRENT_PACKAGE=""
      flush_user_messages
      return $status
      ;;
    *)
      _file_usage
      [[ -z "$subcommand" ]] || exit 1
      ;;
  esac
}

# Claim a single file
# Usage: _file_claim <path> <repo_or_empty> <package_or_empty>
_file_claim() {
  local arg="$1" repo="$2" package="$3"
  local rel
  rel=$(_file_rel_path "$arg") || { ppm_fail "Not a path under \$HOME: $arg"; return 1; }
  local src="$HOME/$rel"

  [[ -e "$src" ]] || { ppm_fail "File not found: ~/$rel"; return 1; }
  [[ -d "$src" ]] && { ppm_fail "Directories are not supported: ~/$rel (use ~/$rel/*)"; return 1; }
  # claim's stow does not use the protected ignore list, so it would re-link a protected file
  _protected_has "$rel" && { ppm_fail "~/$rel is protected; run 'ppm file unprotect' first"; return 1; }

  local existing
  existing=$(_claim_get "$rel" claimant)
  [[ -n "$existing" ]] && { ppm_fail "~/$rel is already claimed by $existing"; return 1; }

  # Who owns the file now
  local owner owner_repo="" owner_pkg=""
  owner=$(_file_owner "$rel")
  if [[ -n "$owner" ]]; then
    owner_repo="${owner%%/*}"
    owner_pkg="${owner#*/}"
  fi

  local target_repo="${repo:-$PPM_DEFAULT_REPO}" target_pkg="${package:-$owner_pkg}"
  [[ -n "$target_pkg" ]] || { ppm_fail "~/$rel is not managed by ppm; use --package NAME"; return 1; }
  is_repo_name "$target_repo" || { ppm_fail "Unknown repo '$target_repo'"; return 1; }
  [[ "$target_repo" == "$owner_repo" ]] && { ppm_fail "~/$rel already belongs to $owner"; return 1; }

  local pkg_dir="$ANFS_SOURCES_HOME/$target_repo/packages/$target_pkg"
  local dest="$pkg_dir/home/$rel"
  if [[ -e "$dest" || -L "$dest" ]]; then
    ppm_fail "$dest already exists"
    return 1
  fi

  PPM_CURRENT_PACKAGE="$target_repo/$target_pkg"

  # Warn when the claimant would not take precedence over the owner
  if [[ -n "$owner" && $(_repo_index "$target_repo") -gt $(_repo_index "$owner_repo") ]]; then
    user_message "Warning: $target_repo has lower priority than $owner_repo in the source lists"
  fi

  if [[ ! -d "$pkg_dir" ]]; then
    mkdir -p "$pkg_dir" || { ppm_fail "Cannot create $pkg_dir"; return 1; }
    {
      echo "version: 0.1.0"
      echo "author: ${USER:-unknown}"
      # Same-name packages are layered automatically; a different name needs an explicit dependency
      if [[ -n "$owner" && "$owner_pkg" != "$target_pkg" ]]; then
        echo "depends:"
        echo "  - $owner"
      fi
    } > "$pkg_dir/package.yml"
    echo "Created package $target_repo/$target_pkg"
  fi

  mkdir -p "$(dirname "$dest")" && cp -pL "$src" "$dest" || { ppm_fail "Failed to copy ~/$rel to $dest"; return 1; }

  # Replace the original with a link from the claimant package, rolling back on failure
  local old_link=""
  [[ -L "$src" ]] && old_link=$(readlink "$src")
  rm -f "$src"
  if ! stow --no-folding -d "$pkg_dir" -t "$HOME" home; then
    rm -f "$dest"
    if [[ -n "$old_link" ]]; then
      ln -s "$old_link" "$src"
    else
      cp -p "$dest" "$src" 2>/dev/null || true
    fi
    ppm_fail "Failed to stow $target_repo/$target_pkg; ~/$rel restored"
    return 1
  fi

  _tracker_add_file "$target_repo" "$target_pkg" "$pkg_dir" "$rel"
  [[ -n "$owner" ]] && _tracker_remove_file "$owner_repo" "$owner_pkg" "$rel"
  _claim_set "$rel" "$target_repo/$target_pkg" "$owner"

  echo "Claimed ~/$rel${owner:+ from $owner} -> $target_repo/$target_pkg"
  user_message "Claimed ~/$rel. Remember to commit the changes in $ANFS_SOURCES_HOME/$target_repo"
}

# Reset a single claimed file
# Usage: _file_reset <path>
_file_reset() {
  local arg="$1"
  local rel
  rel=$(_file_rel_path "$arg") || { ppm_fail "Not a path under \$HOME: $arg"; return 1; }

  local claimant owner
  claimant=$(_claim_get "$rel" claimant)
  [[ -n "$claimant" ]] || { ppm_fail "~/$rel is not claimed"; return 1; }
  owner=$(_claim_get "$rel" owner)

  local c_repo="${claimant%%/*}" c_pkg="${claimant#*/}"
  local c_dir="$ANFS_SOURCES_HOME/$c_repo/packages/$c_pkg"
  local repo_file="$c_dir/home/$rel" link="$HOME/$rel"
  PPM_CURRENT_PACKAGE="$claimant"

  [[ -f "$repo_file" ]] || { ppm_fail "Claimed file is missing: $repo_file"; return 1; }

  # Only remove the link if it is ours
  if [[ -e "$link" || -L "$link" ]]; then
    if [[ "$(_file_owner "$rel")" != "$claimant" ]]; then
      ppm_fail "~/$rel is not linked to $claimant; leaving it alone"
      return 1
    fi
    rm -f "$link"
  fi

  local o_repo="${owner%%/*}" o_pkg="${owner#*/}"
  local o_dir="$ANFS_SOURCES_HOME/$o_repo/packages/$o_pkg"
  if [[ -n "$owner" && -f "$o_dir/home/$rel" ]]; then
    # Restow only this file from the owner; everything else in the package is left as-is
    PPM_IGNORE_ARGS=()
    local other
    while IFS= read -r other; do
      if [[ -n "$other" && "$other" != "$rel" ]]; then
        PPM_IGNORE_ARGS+=("$(_stow_ignore_arg "$other")")
      fi
    done < <(package_links "$o_dir/home")

    if ! stow --no-folding ${PPM_IGNORE_ARGS[@]+"${PPM_IGNORE_ARGS[@]}"} -d "$o_dir" -t "$HOME" home; then
      stow --no-folding -d "$c_dir" -t "$HOME" home 2>/dev/null || true
      ppm_fail "Failed to restore ~/$rel from $owner"
      return 1
    fi
    meta_is_installed "$o_repo" "$o_pkg" && _tracker_add_file "$o_repo" "$o_pkg" "$o_dir" "$rel"
  else
    [[ -n "$owner" ]] && user_message "Warning: $owner no longer provides ~/$rel; restored as a regular file"
    cp -p "$repo_file" "$link" || { ppm_fail "Failed to restore ~/$rel"; return 1; }
  fi

  # Remove the claimed copy and prune empty parent directories
  rm -f "$repo_file"
  local dir
  dir=$(dirname "$repo_file")
  while [[ "$dir" != "$c_dir/home" && "$dir" == "$c_dir/home/"* ]] && rmdir "$dir" 2>/dev/null; do
    dir=$(dirname "$dir")
  done

  _tracker_remove_file "$c_repo" "$c_pkg" "$rel"
  _claim_del "$rel"
  echo "Reset ~/$rel${owner:+ -> $owner}"

  # Delete the claimant package if nothing is left in it
  if [[ -z "$(find "$c_dir/home" -type f 2>/dev/null)" ]] && \
     [[ -z "$(ls -A "$c_dir" | grep -vxF -e home -e "package.yml")" ]]; then
    rm -rf "$c_dir"
    meta_mark_removed "$c_repo" "$c_pkg"
    echo "Removed empty package $claimant"
  fi

  user_message "Reset ~/$rel. Remember to commit the changes in $ANFS_SOURCES_HOME/$c_repo"
}

# Protect a single file: detach it from ppm and keep a plain local copy stow won't touch
# Usage: _file_protect <path>
_file_protect() {
  local arg="$1" rel
  rel=$(_file_rel_path "$arg") || { ppm_fail "Not a path under \$HOME: $arg"; return 1; }
  local src="$HOME/$rel"
  PPM_CURRENT_PACKAGE=""

  [[ -e "$src" || -L "$src" ]] || { ppm_fail "File not found: ~/$rel"; return 1; }
  [[ -d "$src" ]] && { ppm_fail "Directories are not supported: ~/$rel"; return 1; }

  if _protected_has "$rel"; then
    echo "Already protected: ~/$rel"
    return 0
  fi

  # Find the current ppm owner (claim first, then a plain package link) before we detach
  local owner claimant
  claimant=$(_claim_get "$rel" claimant)
  owner=$(_file_owner "$rel")

  # Turn a package symlink into a real local file so the current content is preserved
  if [[ -L "$src" ]]; then
    local tmp
    tmp=$(mktemp) || { ppm_fail "Cannot create temp file for ~/$rel"; return 1; }
    if ! cp -pL "$src" "$tmp"; then
      rm -f "$tmp"; ppm_fail "Failed to read ~/$rel"; return 1
    fi
    rm -f "$src" && mv "$tmp" "$src" || { ppm_fail "Failed to detach ~/$rel"; return 1; }
  fi

  _protected_add "$rel"

  # Drop it from any tracker/claim so remove/reinstall won't try to manage it
  if [[ -n "$claimant" ]]; then
    _tracker_remove_file "${claimant%%/*}" "${claimant#*/}" "$rel"
    _claim_del "$rel"
  elif [[ -n "$owner" ]]; then
    _tracker_remove_file "${owner%%/*}" "${owner#*/}" "$rel"
  fi

  echo "Protected ~/$rel${owner:+ (was $owner)}${claimant:+ (was $claimant)}"
}

# Unprotect a single file: let ppm manage it again on the next install
# Usage: _file_unprotect <path>
_file_unprotect() {
  local arg="$1" rel
  rel=$(_file_rel_path "$arg") || { ppm_fail "Not a path under \$HOME: $arg"; return 1; }
  PPM_CURRENT_PACKAGE=""

  _protected_has "$rel" || { ppm_fail "~/$rel is not protected"; return 1; }
  _protected_del "$rel"
  echo "Unprotected ~/$rel"
  user_message "~/$rel is still a local file. Run 'ppm install -f <package>' to let a package re-link it."
}

# --- Helpers ---

# Normalize a path to be relative to $HOME (without resolving the file itself)
_file_rel_path() {
  local path="$1" dir
  [[ "$path" != /* ]] && path="$PWD/$path"
  dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd) || return 1
  path="$dir/$(basename "$path")"
  [[ "$path" == "$HOME/"* ]] || return 1
  echo "${path#$HOME/}"
}

# Print "repo/pkg" if $HOME/<rel> is a symlink into a ppm package, nothing otherwise
_file_owner() {
  local link="$HOME/$1" target data_real rest repo
  [[ -L "$link" ]] || return 0

  target=$(readlink "$link")
  [[ "$target" != /* ]] && target="$(dirname "$link")/$target"
  target=$(cd "$(dirname "$target")" 2>/dev/null && pwd -P) || return 0
  data_real=$(cd "$ANFS_SOURCES_HOME" 2>/dev/null && pwd -P) || return 0

  # target dir is <data>/<repo>/<asset_dir>/<pkg>/<subdir>/...
  rest="${target#$data_real/}"
  [[ "$rest" == "$target" ]] && return 0
  repo="${rest%%/*}"
  rest="${rest#*/}"
  [[ "${rest%%/*}" == "packages" ]] || return 0
  rest="${rest#*/}"
  [[ "$rest" == */* ]] || return 0
  echo "$repo/${rest%%/*}"
}

# Read a field (claimant|owner) of a claim
_claim_get() {
  [[ -f "$PPM_CLAIMS_FILE" ]] || return 0
  K="$1" yq -r ".[strenv(K)].$2 // \"\"" "$PPM_CLAIMS_FILE" 2>/dev/null
}

_claim_set() {
  mkdir -p "$(dirname "$PPM_CLAIMS_FILE")"
  [[ -s "$PPM_CLAIMS_FILE" ]] || echo '{}' > "$PPM_CLAIMS_FILE"
  K="$1" C="$2" O="$3" yq -i '.[strenv(K)] = {"claimant": strenv(C), "owner": strenv(O)}' "$PPM_CLAIMS_FILE"
}

_claim_del() {
  [[ -f "$PPM_CLAIMS_FILE" ]] || return 0
  K="$1" yq -i 'del(.[strenv(K)])' "$PPM_CLAIMS_FILE"
}

# --- Protected files ($PPM_PROTECTED_FILE: a plain list of $HOME-relative paths) ---

# Print each protected path, one per line
_protected_list() {
  [[ -s "$PPM_PROTECTED_FILE" ]] || return 0
  yq -r '.[]' "$PPM_PROTECTED_FILE" 2>/dev/null
}

# True when a path is protected
_protected_has() {
  local rel="$1" p
  while IFS= read -r p; do
    [[ "$p" == "$rel" ]] && return 0
  done < <(_protected_list)
  return 1
}

_protected_add() {
  mkdir -p "$(dirname "$PPM_PROTECTED_FILE")"
  [[ -s "$PPM_PROTECTED_FILE" ]] || echo '[]' > "$PPM_PROTECTED_FILE"
  F="$1" yq -i '. = ((. // []) + [strenv(F)] | unique)' "$PPM_PROTECTED_FILE"
}

_protected_del() {
  [[ -f "$PPM_PROTECTED_FILE" ]] || return 0
  F="$1" yq -i 'del(.[] | select(. == strenv(F)))' "$PPM_PROTECTED_FILE"
}
