#!/usr/bin/env bash
# gitsrc — git source repositories: two source lists, one directory per source, and the
# `src add|remove|list|ssh|update` command. anfs owns the sources (`anfs src`, configured by
# anfs_gitsrc_env at the bottom); every anfs tool reads its own top-level directory of each.
#
# Like everything in lib/anfs/ (what every tool sources), it only defines functions, depends on no
# tool, and is safe under bash 3.2 with `set -euo pipefail`. It is configured with variables:
#
#   GITSRC_TOOL           name used in messages and usage (ppm, pcm)
#   GITSRC_USER_LIST      your list, edited by `src add/remove/ssh`; highest priority
#   GITSRC_SYSTEM_LIST    the shipped list (stowed by a package); never edited
#   GITSRC_REPOS_DIR      where git sources are cloned, one directory per alias
#   GITSRC_CACHE_DIR      holds updated/<alias>: epoch of each repo's last clone or pull
#   GITSRC_UPDATE_TTL     seconds before a repo is stale for gitsrc_update_stale (default 86400)
#   GITSRC_QUIET_SKIPPED  true: report repos skipped for local changes only via debug
#   GITSRC_LINK_LOCAL     true: a local-path source is used where it is (gitsrc_dir returns the
#                         path); false: it lives at $GITSRC_REPOS_DIR/<alias> like a clone, and
#                         `src update` links it there when nothing is in the way (anfs)
#   GITSRC_DIRS           top-level directories `src list` reports a source as providing
#   GITSRC_SYSTEM_LIST_HINT  appended when `src ssh` finds an https entry only in the system list
#
# Optional hooks a tool may define:
#   gitsrc_hook_user_list_file  echo the user list to write (ppm migrates a legacy name here)
#   gitsrc_hook_user_list_read  echo the user list to read, or nothing
#   gitsrc_hook_system_writable true when the system list may be edited by `src ssh`
#
# Source list format, one per line: <git-url-or-path> [alias]  (alias defaults to the basename)

gitsrc_debug() {
  if declare -F debug >/dev/null; then debug "$@"; fi
  return 0
}

# The user list `src` writes to
gitsrc_user_list_file() {
  if declare -F gitsrc_hook_user_list_file >/dev/null; then
    gitsrc_hook_user_list_file
  else
    echo "$GITSRC_USER_LIST"
  fi
}

# The user list to read from, or nothing when there is none
gitsrc_user_list_read() {
  if declare -F gitsrc_hook_user_list_read >/dev/null; then
    gitsrc_hook_user_list_read
  elif [[ -f "$GITSRC_USER_LIST" ]]; then
    echo "$GITSRC_USER_LIST"
  fi
}

# True for a git URL, false for a local path
gitsrc_is_git_url() {
  [[ "$1" == git@* || "$1" == *://* ]]
}

# Parse one list line into GITSRC_LINE_URL and GITSRC_LINE_NAME; false for blanks and comments
gitsrc_parse_line() {
  GITSRC_LINE_URL="" GITSRC_LINE_NAME=""
  [[ -z "$1" || "$1" =~ ^[[:space:]]*# ]] && return 1
  read -r GITSRC_LINE_URL GITSRC_LINE_NAME _ <<< "$1"
  [[ -n "$GITSRC_LINE_URL" ]] || return 1
  [[ -z "$GITSRC_LINE_NAME" ]] && GITSRC_LINE_NAME="$(basename "$GITSRC_LINE_URL" .git)"
  return 0
}

# Read both lists into GITSRC_URLS and GITSRC_NAMES (array order is priority order). User entries
# come first; an alias declared in both lists is taken from the user list.
gitsrc_collect() {
  GITSRC_URLS=()
  GITSRC_NAMES=()

  local seen=" " file line
  for file in "$(gitsrc_user_list_read)" "$GITSRC_SYSTEM_LIST"; do
    [[ -n "$file" && -f "$file" ]] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      gitsrc_parse_line "$line" || continue

      # Dedup by alias; the first occurrence (user list) wins
      [[ "$seen" == *" $GITSRC_LINE_NAME "* ]] && continue
      seen="$seen$GITSRC_LINE_NAME "

      GITSRC_URLS+=("$GITSRC_LINE_URL")
      GITSRC_NAMES+=("$GITSRC_LINE_NAME")
      gitsrc_debug "Source: $GITSRC_LINE_URL -> $GITSRC_LINE_NAME"
    done < "$file"
  done
}

# Position of an alias in the collected sources (lower is higher priority); 9999 if absent
gitsrc_index() {
  local i
  for i in ${GITSRC_NAMES[@]+"${!GITSRC_NAMES[@]}"}; do
    [[ "${GITSRC_NAMES[$i]}" == "$1" ]] && { echo "$i"; return; }
  done
  echo 9999
}

# Directory holding source $1: the clone under GITSRC_REPOS_DIR, or with GITSRC_LINK_LOCAL the
# local path itself. Uses the collected sources; an unknown alias maps to GITSRC_REPOS_DIR.
gitsrc_dir() {
  local i url
  if [[ "${GITSRC_LINK_LOCAL:-false}" == true ]]; then
    i=$(gitsrc_index "$1")
    if [[ "$i" != 9999 ]]; then
      url="${GITSRC_URLS[$i]}"
      if ! gitsrc_is_git_url "$url"; then
        [[ "$url" == "~"* ]] && url="$HOME${url:1}"
        echo "$url"
        return 0
      fi
    fi
  fi
  echo "$GITSRC_REPOS_DIR/$1"
}

# State of a directory: clean, dirty (uncommitted or untracked changes), local (exists, not a git
# repo) or missing
gitsrc_dir_status() {
  local dir="$1"
  if [[ -d "$dir/.git" || -f "$dir/.git" ]]; then
    if [[ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
      echo clean
    else
      echo dirty
    fi
  elif [[ -d "$dir" ]]; then
    echo local
  else
    echo missing
  fi
}

# State of source $1 (collected)
gitsrc_status() {
  gitsrc_dir_status "$(gitsrc_dir "$1")"
}

# --- src list ----------------------------------------------------------------------------------

# The GITSRC_DIRS a source has, space-separated
gitsrc_provides() {
  local dir tld out=""
  dir=$(gitsrc_dir "$1")
  for tld in ${GITSRC_DIRS:-}; do
    [[ -d "$dir/$tld" ]] && out="$out $tld"
  done
  echo "${out# }"
}

# Print each entry of a list file with its status (and what it provides, with GITSRC_DIRS)
gitsrc_list_file() {
  local file="$1" line provides
  [[ -n "$file" && -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    gitsrc_parse_line "$line" || continue
    if [[ -n "${GITSRC_DIRS:-}" ]]; then
      provides=$(gitsrc_provides "$GITSRC_LINE_NAME")
      printf "%s  %s  [%s]\n" "$line" "$(gitsrc_status "$GITSRC_LINE_NAME")" "${provides:-nothing}"
    else
      printf "%s  %s\n" "$line" "$(gitsrc_status "$GITSRC_LINE_NAME")"
    fi
  done < "$file"
}

gitsrc_list() {
  local user_file
  user_file=$(gitsrc_user_list_read)
  if [[ -z "$user_file" && ! -f "$GITSRC_SYSTEM_LIST" ]]; then
    echo "No sources configured"
    return 0
  fi
  gitsrc_collect
  echo "# user ($(basename "${user_file:-$GITSRC_USER_LIST}"))"
  gitsrc_list_file "$user_file"
  echo "# system ($(basename "$GITSRC_SYSTEM_LIST"))"
  gitsrc_list_file "$GITSRC_SYSTEM_LIST"
}

# --- src add / remove --------------------------------------------------------------------------

gitsrc_add() {
  local top=false
  [[ "${1:-}" == "--top" ]] && { top=true; shift; }

  if [[ $# -eq 0 ]]; then
    echo "Error: src add requires a git URL"
    echo "Usage: $GITSRC_TOOL src add [--top] <git-url> [alias]"
    exit 1
  fi

  local url="$1" user_file
  user_file=$(gitsrc_user_list_file)
  mkdir -p "$(dirname "$user_file")"
  touch "$user_file"

  local alias="${2:-$(basename "$url" .git)}"
  local entry="$url  $alias"

  # Already listed (match the first column)
  if awk '{print $1}' "$user_file" 2>/dev/null | grep -qxF "$url"; then
    echo "Source already exists: $url"
    return 0
  fi

  if $top; then
    local tmp
    tmp=$(mktemp)
    echo "$entry" > "$tmp"
    cat "$user_file" >> "$tmp"
    mv "$tmp" "$user_file"
  else
    echo "$entry" >> "$user_file"
  fi
  echo "Added source: $url ($alias)"
}

# Remove an entry from the user list by URL (first column) or alias (last column)
gitsrc_remove() {
  if [[ $# -eq 0 ]]; then
    echo "Error: src remove requires a URL or alias"
    echo "Usage: $GITSRC_TOOL src remove <url-or-alias>"
    exit 1
  fi

  local target="$1" user_file tmp
  user_file=$(gitsrc_user_list_file)

  # awk rather than sed: URLs contain the usual sed delimiters
  if [[ -f "$user_file" ]] &&
     awk -v t="$target" '$1 == t || $NF == t { found=1 } END { exit !found }' "$user_file" 2>/dev/null; then
    tmp=$(awk -v t="$target" '$1 != t && $NF != t' "$user_file")
    if [[ -n "$tmp" ]]; then
      printf '%s\n' "$tmp" > "$user_file"
    else
      : > "$user_file"
    fi
    echo "Removed source: $target"
  else
    echo "Source not found in user list: $target ($(basename "$GITSRC_SYSTEM_LIST") is $GITSRC_TOOL-managed)"
    return 1
  fi
}

# --- src ssh -----------------------------------------------------------------------------------

# Convert https://github.com/user/repo[.git] to git@github.com:user/repo[.git]
gitsrc_github_ssh_url() {
  echo "git@github.com:${1#https://github.com/}"
}

# Rewrite a GitHub HTTPS entry to SSH in one list file; false if the file doesn't list the URL
gitsrc_ssh_rewrite_in_file() {
  local file="$1" url="$2" tmp
  [[ -f "$file" ]] || return 1
  awk -v u="$url" '$1 == u { f=1 } END { exit !f }' "$file" || return 1
  tmp=$(awk -v old="$url" -v new="$(gitsrc_github_ssh_url "$url")" \
    '$1 == old { sub(/^[^[:space:]]+/, new) } { print }' "$file")
  printf '%s\n' "$tmp" > "$file"
}

# Switch GitHub HTTPS entries and the origin remotes of cloned sources to SSH. The user list is
# always writable; the system list only when gitsrc_hook_system_writable says so.
gitsrc_ssh() {
  local filter="${1:-}" user_file
  user_file=$(gitsrc_user_list_file)

  local writable=("$user_file")
  if declare -F gitsrc_hook_system_writable >/dev/null && gitsrc_hook_system_writable; then
    writable+=("$GITSRC_SYSTEM_LIST")
  fi

  gitsrc_collect

  local i name url repo_dir remote changed noted found=false f
  local sys_name hint="${GITSRC_SYSTEM_LIST_HINT:-}"
  sys_name=$(basename "$GITSRC_SYSTEM_LIST")
  for i in ${GITSRC_NAMES[@]+"${!GITSRC_NAMES[@]}"}; do
    name="${GITSRC_NAMES[$i]}"
    [[ -z "$filter" || "$name" == "$filter" ]] || continue
    found=true
    changed=false
    noted=false
    url="${GITSRC_URLS[$i]}"
    repo_dir=$(gitsrc_dir "$name")

    if [[ "$url" == https://github.com/* ]]; then
      # Rewrite the entry in the first writable list that has it
      for f in "${writable[@]}"; do
        if gitsrc_ssh_rewrite_in_file "$f" "$url"; then
          echo "$name: $(basename "$f") -> $(gitsrc_github_ssh_url "$url")"
          changed=true
          break
        fi
      done
      # An https entry that only lives in the (read-only) system list
      if ! $changed && [[ -f "$GITSRC_SYSTEM_LIST" ]] &&
         awk -v u="$url" '$1 == u { f=1 } END { exit !f }' "$GITSRC_SYSTEM_LIST"; then
        echo "$name: https in $sys_name ($GITSRC_TOOL-managed)${hint:+; $hint}"
        noted=true
      fi
    fi

    if remote=$(git -C "$repo_dir" remote get-url origin 2>/dev/null) && [[ "$remote" == https://github.com/* ]]; then
      git -C "$repo_dir" remote set-url origin "$(gitsrc_github_ssh_url "$remote")"
      echo "$name: origin -> $(gitsrc_github_ssh_url "$remote")"
      changed=true
    fi

    { $changed || $noted; } || echo "$name: already SSH"
  done

  $found || { echo "Source not found: $filter"; return 1; }
}

# --- src update --------------------------------------------------------------------------------
# $GITSRC_CACHE_DIR/updated/<alias> holds the epoch of a repo's last clone or pull. Tracking each
# repo separately means one repo skipped for local changes stays stale on its own.

gitsrc_updated_file() {
  echo "$GITSRC_CACHE_DIR/updated/$1"
}

gitsrc_mark_updated() {
  mkdir -p "$GITSRC_CACHE_DIR/updated"
  date +%s > "$(gitsrc_updated_file "$1")"
}

# True when a repo was never updated, or not within GITSRC_UPDATE_TTL seconds
gitsrc_stale() {
  local file last ttl="${GITSRC_UPDATE_TTL:-86400}"
  file=$(gitsrc_updated_file "$1")
  [[ -f "$file" ]] || return 0
  last=$(cat "$file" 2>/dev/null)
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  (( $(date +%s) - last > ttl ))
}

# `src update [--auto] [alias...]`: clone missing and pull existing git sources, all of them or the
# named aliases. Local paths are never cloned or pulled. Sources with uncommitted changes are
# skipped and stay stale. False if any was skipped or failed.
# --auto: skipped sources are reported in one line (via debug with GITSRC_QUIET_SKIPPED=true).
gitsrc_update() {
  local auto=false
  [[ "${1:-}" == "--auto" ]] && { auto=true; shift; }
  local wanted=" $* " all_updated=true i repo_url repo_name dir skipped=()

  gitsrc_collect

  for i in ${GITSRC_URLS[@]+"${!GITSRC_URLS[@]}"}; do
    repo_url="${GITSRC_URLS[$i]}"
    repo_name="${GITSRC_NAMES[$i]}"
    dir="$GITSRC_REPOS_DIR/$repo_name"

    [[ $# -eq 0 || "$wanted" == *" $repo_name "* ]] || continue
    if ! gitsrc_is_git_url "$repo_url"; then
      gitsrc_link_local "$repo_url" "$repo_name" || all_updated=false
      continue
    fi

    if [[ ! -d "$dir" ]]; then
      echo "Cloning: $repo_url"
      mkdir -p "$GITSRC_REPOS_DIR"
      if git clone "$repo_url" "$dir"; then
        gitsrc_mark_updated "$repo_name"
      else
        all_updated=false
      fi
      continue
    fi

    if ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet ||
       [[ -n $(git -C "$dir" status --porcelain) ]]; then
      if $auto; then
        skipped+=("$repo_name")
      else
        echo "Skipping $repo_name: has uncommitted changes. Please commit or stash them first."
      fi
      all_updated=false
      continue
    fi

    echo "Updating: $repo_name"
    if git -C "$dir" pull; then
      gitsrc_mark_updated "$repo_name"
    else
      all_updated=false
    fi
  done

  if [[ ${#skipped[@]} -gt 0 ]]; then
    local list
    printf -v list '%s, ' "${skipped[@]}"
    if [[ "${GITSRC_QUIET_SKIPPED:-false}" == true ]]; then
      gitsrc_debug "Not updated (uncommitted changes): ${list%, }"
    else
      echo "Not updated (uncommitted changes): ${list%, }"
    fi
  fi

  $all_updated
}

# A local-path source lives where it is; without GITSRC_LINK_LOCAL it is linked into the repos
# dir so every reader finds every source at $GITSRC_REPOS_DIR/<alias>. Never pulled.
gitsrc_link_local() {
  local path="$1" name="$2" dir
  [[ "${GITSRC_LINK_LOCAL:-false}" == true ]] && return 0
  [[ "$path" == "~"* ]] && path="$HOME${path:1}"
  dir="$GITSRC_REPOS_DIR/$name"
  # The source may be the directory itself (a repo created in place, e.g. by ppm customize)
  [[ "$path" == "$dir" ]] && return 0
  if [[ -L "$dir" ]]; then
    [[ "$(readlink "$dir")" == "$path" ]] && return 0
    rm -f "$dir"
  elif [[ -e "$dir" ]]; then
    echo "Skipping $name: $dir is in the way of the link to $path"
    return 1
  fi
  [[ -d "$path" ]] || { echo "Skipping $name: $path does not exist"; return 1; }
  mkdir -p "$GITSRC_REPOS_DIR"
  ln -s "$path" "$dir"
  echo "Linked: $path ($name)"
}

# Update only the git sources that are stale; fresh ones aren't touched
gitsrc_update_stale() {
  local stale=() i
  gitsrc_collect
  for i in ${GITSRC_NAMES[@]+"${!GITSRC_NAMES[@]}"}; do
    gitsrc_is_git_url "${GITSRC_URLS[$i]}" || continue
    if gitsrc_stale "${GITSRC_NAMES[$i]}"; then
      stale+=("${GITSRC_NAMES[$i]}")
    fi
  done

  [[ ${#stale[@]} -gt 0 ]] || return 0
  gitsrc_debug "Stale repos: ${stale[*]}"
  gitsrc_update --auto "${stale[@]}" || gitsrc_debug "Some repos were not updated; they stay stale"
}

# --- the src command ---------------------------------------------------------------------------

gitsrc_usage() {
  echo "Usage: $GITSRC_TOOL src <add|remove|list|ssh|update>"
  echo "  add [--top] <git-url|path> [alias]  Add a source repository"
  echo "  remove <url-or-alias>               Remove a source repository"
  echo "  list                                List configured sources"
  echo "  ssh [alias]                         Switch GitHub HTTPS sources and remotes to SSH"
  echo "  update [alias...]                   Clone missing and pull existing sources (local"
  echo "                                      paths are linked, never pulled)"
}

# `<tool> src <subcommand> [args]`
gitsrc_command() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  case "$subcommand" in
    add)    gitsrc_add "$@" ;;
    remove) gitsrc_remove "$@" ;;
    list)   gitsrc_list ;;
    ssh)    gitsrc_ssh "$@" ;;
    update) gitsrc_update "$@" ;;
    *)
      gitsrc_usage
      [[ -z "$subcommand" ]] || exit 1
      ;;
  esac
}

# --- anfs --------------------------------------------------------------------------------------

# Configure gitsrc for anfs's sources (paths.sh sets the ANFS_* paths and loads anfs.conf)
anfs_gitsrc_env() {
  GITSRC_TOOL=anfs
  GITSRC_UPDATE_TTL="${ANFS_UPDATE_CACHE_DURATION:-86400}"
  GITSRC_QUIET_SKIPPED="${ANFS_QUIET_SKIPPED_REPOS:-false}"
  GITSRC_USER_LIST="$ANFS_USER_LIST"
  GITSRC_SYSTEM_LIST="$ANFS_SYSTEM_LIST"
  GITSRC_REPOS_DIR="$ANFS_SOURCES_HOME"
  GITSRC_CACHE_DIR="$ANFS_CACHE_HOME"
  GITSRC_LINK_LOCAL=false
  GITSRC_DIRS="packages containers skills spaces"
  GITSRC_SYSTEM_LIST_HINT="run 'ppm file protect ~/.config/anfs/system.list' to edit it here"
}
