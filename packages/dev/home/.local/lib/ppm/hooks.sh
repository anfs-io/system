#!/usr/bin/env bash
# anfs/dev — adds `ppm hooks`: wire ppm's git hooks into the package repos
# Stowed to ~/.local/lib/ppm/ and sourced by ppm, so cmd_hooks() is the command `ppm hooks`
#
# Each repo gets core.hooksPath pointed at the stowed hook directory, set per repo. It is never
# set globally: a global core.hooksPath applies to every repo on the machine AND suppresses each
# repo's own .git/hooks, which would silently disable husky/lefthook/overcommit everywhere else.
# Pointing at the stowed path (rather than into the package) means edits to a hook take effect
# everywhere at once, and a higher-priority layer can override a single hook file through stow.

PPM_HOOKS_DIR="$XDG_CONFIG_HOME/git/ppm-hooks"

cli_cmd hooks "hooks [install|uninstall] [--all] [repo...]" "Wire the package-versioning git hooks into the source repos"

cmd_hooks() {
  local subcommand="${1:-status}"
  shift 2>/dev/null || true

  local all=false repos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=true ;;
      -*) echo "Unknown flag: $1"; return 1 ;;
      *) repos+=("$1") ;;
    esac
    shift
  done

  case "$subcommand" in
    install)   _hooks_apply set "$all" ${repos[@]+"${repos[@]}"} ;;
    uninstall) _hooks_apply unset "$all" ${repos[@]+"${repos[@]}"} ;;
    status)    _hooks_status "$all" ${repos[@]+"${repos[@]}"} ;;
    *)
      echo "Usage: ppm hooks <command> [--all] [repo...]"
      echo "  install [--all] [repo...]    Point each repo's core.hooksPath at $PPM_HOOKS_DIR"
      echo "  uninstall [--all] [repo...]  Unset it again (only where ppm set it)"
      echo "  status [--all] [repo...]     Show which repos are wired up (default)"
      echo ""
      echo "Without repo names: the repos in system.list. --all adds your user.list repos."
      echo "Hooks are not carried by git clone, so this is re-run after 'ppm src add'."
      [[ "$subcommand" == "help" ]] || return 1
      ;;
  esac
}

# Repo aliases listed in one source-list file (the format collect_repos reads)
_hooks_aliases_in() {
  local file="$1" line url name
  [[ -n "$file" && -f "$file" ]] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    read -r url name <<< "$line"
    [[ -z "$name" ]] && name="$(basename "$url" .git)"
    echo "$name"
  done < "$file"
}

# The repos to act on: explicit names, else system.list (plus user.list with --all)
_hooks_target_repos() {
  local all="$1"; shift
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@"
    return 0
  fi
  {
    _hooks_aliases_in "$ANFS_SYSTEM_LIST"
    $all && _hooks_aliases_in "$(_user_sources_read)"
  } | awk '!seen[$0]++'
}

# Current core.hooksPath for a repo, empty if unset
_hooks_current() {
  git -C "$1" config --local --get core.hooksPath 2>/dev/null || true
}

# set|unset core.hooksPath across the target repos
_hooks_apply() {
  local action="$1" all="$2"; shift 2
  local alias dir current changed=0

  if [[ "$action" == set && ! -d "$PPM_HOOKS_DIR" ]]; then
    echo "Error: $PPM_HOOKS_DIR does not exist (is anfs/dev installed?)"
    return 1
  fi

  while IFS= read -r alias; do
    [[ -n "$alias" ]] || continue
    dir="$ANFS_SOURCES_HOME/$alias"
    if [[ ! -d "$dir/.git" ]]; then
      debug "hooks: $alias is not a git repo, skipping"
      continue
    fi
    current=$(_hooks_current "$dir")

    if [[ "$action" == set ]]; then
      if [[ "$current" == "$PPM_HOOKS_DIR" ]]; then
        debug "hooks: $alias already wired up"
        continue
      fi
      if [[ -n "$current" ]]; then
        echo "  $alias: leaving its own core.hooksPath alone ($current)"
        continue
      fi
      _hooks_warn_shadowed "$alias" "$dir"
      # Never fatal: a repo can be read-only (containers mount the host's repos that way) and a
      # failure to wire a hook must not abort `ppm install dev` or skip its tracker
      if ! git -C "$dir" config --local core.hooksPath "$PPM_HOOKS_DIR" 2>/dev/null; then
        echo "  $alias: could not write .git/config (read-only?), skipped"
        continue
      fi
      echo "  $alias: hooks installed"
    else
      # Only ever remove what ppm set, never a hooksPath the user chose
      [[ "$current" == "$PPM_HOOKS_DIR" ]] || continue
      if ! git -C "$dir" config --local --unset core.hooksPath 2>/dev/null; then
        echo "  $alias: could not write .git/config (read-only?), skipped"
        continue
      fi
      echo "  $alias: hooks removed"
    fi
    changed=$((changed + 1))
  done < <(_hooks_target_repos "$all" "$@")

  [[ $changed -gt 0 ]] || echo "  no changes"
}

# core.hooksPath replaces .git/hooks wholesale, so say so if the repo has real hooks there.
# Printed rather than queued with user_message: `ppm hooks` is its own command and never reaches
# the end-of-install flush, so a queued message would be swallowed.
_hooks_warn_shadowed() {
  local alias="$1" dir="$2" found
  found=$(find "$dir/.git/hooks" -maxdepth 1 -type f ! -name '*.sample' 2>/dev/null | wc -l | tr -d ' ')
  [[ "$found" -gt 0 ]] || return 0
  echo "  $alias: note — this now takes precedence over $found existing .git/hooks file(s)"
}

_hooks_status() {
  local all="$1"; shift
  local alias dir current state
  echo "Hook directory: $PPM_HOOKS_DIR$([[ -d "$PPM_HOOKS_DIR" ]] || echo ' (missing)')"
  while IFS= read -r alias; do
    [[ -n "$alias" ]] || continue
    dir="$ANFS_SOURCES_HOME/$alias"
    if [[ ! -d "$dir/.git" ]]; then
      state="not a git repo"
    else
      current=$(_hooks_current "$dir")
      if [[ "$current" == "$PPM_HOOKS_DIR" ]]; then
        state="installed"
      elif [[ -n "$current" ]]; then
        state="its own: $current"
      else
        state="not installed"
      fi
    fi
    printf '  %-12s %s\n' "$alias" "$state"
  done < <(_hooks_target_repos "$all" "$@")
}
