#!/usr/bin/env bash
# gitsrc — git source repositories: two source lists, one directory per source, and the
# `src add|remove|list|ssh|update` command. anfs owns the sources (`anfs src`, configured by
# anfs_gitsrc_env at the bottom); every anfs tool reads its own top-level directory of each.
#
# Like everything in lib/anfs/ (what every tool sources), it only defines functions, depends on no
# tool, and is safe under `set -euo pipefail`. It is written for the bash floor (5.2, see bash.sh).
# It is configured with variables:
#
#   GITSRC_TOOL           name used in messages and usage (ppm, pcm)
#   GITSRC_USER_LIST      your list, edited by `src add/remove/ssh`; highest priority
#   GITSRC_SYSTEM_LIST    the shipped list (linked by a package); never edited
#   GITSRC_REPOS_DIR      where git sources are cloned, one directory per alias
#   GITSRC_CACHE_DIR      holds updated/<alias>: epoch of each repo's last clone or pull
#   GITSRC_UPDATE_TTL     seconds before a repo is stale for gitsrc_update_stale (default 86400)
#   GITSRC_QUIET_SKIPPED  true: report repos skipped for local changes only via debug
#   GITSRC_LINK_LOCAL     true: a local-path source is used where it is (gitsrc_dir returns the
#                         path); false: it lives at $GITSRC_REPOS_DIR/<alias> like a clone, and
#                         `src update` links it there when nothing is in the way (anfs)
#   GITSRC_DIRS           top-level directories `src list` reports a source as providing
#
# Optional hooks a tool may define:
#   gitsrc_hook_user_list_file  echo the user list to write (ppm migrates a legacy name here)
#   gitsrc_hook_user_list_read  echo the user list to read, or nothing
#
# Source list format, one per line: <git-url-or-path> [alias]  (alias defaults to the directory git
# clone would make: anfs_repo_name)

# One clone at one path (repo.sh), from the directory this file really lives in: its link resolved,
# so a pull that brings repo.sh works before core/anfs is installed again
_gitsrc_self="${BASH_SOURCE[0]}"
[[ "$_gitsrc_self" == */* ]] || _gitsrc_self="./$_gitsrc_self"
while [[ -L "$_gitsrc_self" ]]; do
  _gitsrc_link=$(readlink "$_gitsrc_self")
  [[ "$_gitsrc_link" == /* ]] || _gitsrc_link="${_gitsrc_self%/*}/$_gitsrc_link"
  _gitsrc_self="$_gitsrc_link"
done
# shellcheck source=/dev/null
source "${_gitsrc_self%/*}/repo.sh"
unset _gitsrc_self _gitsrc_link

# anfs_debug (log.sh) when the tool loaded it; else the tool's own debug, if it has one
gitsrc_debug() {
  if declare -F anfs_debug >/dev/null; then anfs_debug "$@"
  elif declare -F debug >/dev/null; then debug "$@"
  fi
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
  if [[ -z "$GITSRC_LINE_NAME" ]]; then
    anfs_repo_name_reply "$GITSRC_LINE_URL"
    GITSRC_LINE_NAME="$REPLY"
  fi
  # A URL that names no directory (and no alias given) is no source
  [[ -n "$GITSRC_LINE_NAME" ]]
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
  for i in "${!GITSRC_NAMES[@]}"; do
    [[ "${GITSRC_NAMES[$i]}" == "$1" ]] && { echo "$i"; return; }
  done
  echo 9999
}

# Directory holding source $1: the clone under GITSRC_REPOS_DIR, or with GITSRC_LINK_LOCAL the
# local path itself. Uses the collected sources; an unknown alias maps to GITSRC_REPOS_DIR.
gitsrc_dir() {
  gitsrc_dir_reply "$1"
  echo "$REPLY"
}

# gitsrc_dir into REPLY, in this shell (a loop over every source forks nothing)
gitsrc_dir_reply() {
  local i url
  REPLY="$GITSRC_REPOS_DIR/$1"
  [[ "${GITSRC_LINK_LOCAL:-false}" == true ]] || return 0
  for i in "${!GITSRC_NAMES[@]}"; do
    [[ "${GITSRC_NAMES[$i]}" == "$1" ]] || continue
    url="${GITSRC_URLS[$i]}"
    gitsrc_is_git_url "$url" && return 0
    [[ "$url" != "~"* ]] || url="$HOME${url:1}"
    REPLY="$url"
    return 0
  done
  return 0
}

# State of source $1 (collected)
gitsrc_status() {
  gitsrc_dir_reply "$1"
  anfs_repo_status "$REPLY"
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

# One row per entry of a list file: alias, status, url, which list, what it provides. The url is
# the clone's origin when the source is cloned (what it really pulls from: `src ssh` switches it,
# and the list's URL is only used for the first clone), else the list's.
gitsrc_list_file() {
  local file="$1" list="$2" line url
  [[ -n "$file" && -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    gitsrc_parse_line "$line" || continue
    url="$GITSRC_LINE_URL"
    gitsrc_dir_reply "$GITSRC_LINE_NAME"
    if [[ -e "$REPLY/.git" ]]; then
      url=$(git -C "$REPLY" remote get-url origin 2>/dev/null) || url="$GITSRC_LINE_URL"
    fi
    anfs_row "$GITSRC_LINE_NAME" "$(gitsrc_status "$GITSRC_LINE_NAME")" "$url" "$list" \
      "$(gitsrc_provides "$GITSRC_LINE_NAME")" "$(gitsrc_dir_reply "$GITSRC_LINE_NAME"; anfs_repo_ahead "$REPLY")"
  done < "$file"
}

# `src list`: the sources in priority order, yours first (lib/anfs/table.sh; --json has provides
# as a list)
gitsrc_list() {
  local user_file
  user_file=$(gitsrc_user_list_read)
  if [[ -z "$user_file" && ! -f "$GITSRC_SYSTEM_LIST" ]]; then
    if anfs_json_on; then echo '[]'; else echo "No sources configured"; fi
    return 0
  fi
  gitsrc_collect
  {
    gitsrc_list_file "$user_file" user
    gitsrc_list_file "$GITSRC_SYSTEM_LIST" system
  } | anfs_table "SOURCE STATUS URL LIST PROVIDES" "source status url list provides[] ahead"
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

  local alias="${2:-$(anfs_repo_name "$url")}"
  if [[ -z "$alias" ]]; then
    echo "Error: $url names no directory: give the source an alias" >&2
    exit 64
  fi
  local entry="$url  $alias"
  # local is every tool's own config directory, the implicit source (pcm, pmm, psm)
  if [[ "$alias" == local ]]; then
    echo "Error: 'local' is reserved (each tool's own config directory): give the source another alias" >&2
    exit 64
  fi

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

# Rewrite a GitHub HTTPS entry to SSH in one list file; false if the file doesn't list the URL
gitsrc_ssh_rewrite_in_file() {
  local file="$1" url="$2" tmp
  [[ -f "$file" ]] || return 1
  awk -v u="$url" '$1 == u { f=1 } END { exit !f }' "$file" || return 1
  tmp=$(awk -v old="$url" -v new="$(anfs_repo_ssh_url "$url")" \
    '$1 == old { sub(/^[^[:space:]]+/, new) } { print }' "$file")
  printf '%s\n' "$tmp" > "$file"
}

# Switch GitHub HTTPS entries of the user list and the origin remotes of cloned sources to SSH.
# The system list is never edited: its URL is only used for a source's first clone, and a clone's
# origin is what it pulls from (src list shows it).
gitsrc_ssh() {
  local filter="${1:-}" user_file
  user_file=$(gitsrc_user_list_file)

  local writable=("$user_file")

  gitsrc_collect

  local i name url repo_dir remote changed noted found=false f sys
  local sys_name
  sys_name=$(basename "$GITSRC_SYSTEM_LIST")
  for i in "${!GITSRC_NAMES[@]}"; do
    name="${GITSRC_NAMES[$i]}"
    [[ -z "$filter" || "$name" == "$filter" ]] || continue
    found=true
    changed=false
    noted=false
    sys=false
    url="${GITSRC_URLS[$i]}"
    repo_dir=$(gitsrc_dir "$name")

    if [[ "$url" == https://github.com/* ]]; then
      # Rewrite the entry in the first writable list that has it
      for f in "${writable[@]}"; do
        if gitsrc_ssh_rewrite_in_file "$f" "$url"; then
          echo "$name: $(basename "$f") -> $(anfs_repo_ssh_url "$url")"
          changed=true
          break
        fi
      done
      # An https entry that only lives in the system list, which is not edited
      if ! $changed && [[ -f "$GITSRC_SYSTEM_LIST" ]] &&
         awk -v u="$url" '$1 == u { f=1 } END { exit !f }' "$GITSRC_SYSTEM_LIST"; then
        sys=true
      fi
    fi

    if remote=$(anfs_repo_ssh "$repo_dir"); then
      echo "$name: origin -> $remote$($sys && echo "; $sys_name's https URL is only used for the first clone")"
      changed=true
    elif $sys; then
      echo "$name: https in $sys_name, only used for the first clone"
      noted=true
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
  rm -f "$(gitsrc_updated_file "$1").failed"
}

# A failed clone or pull is recorded too, so an unreachable source is retried once per
# GITSRC_UPDATE_TTL by the automatic updates instead of by every command. `src update` always tries.
gitsrc_mark_failed() {
  mkdir -p "$GITSRC_CACHE_DIR/updated"
  date +%s > "$(gitsrc_updated_file "$1").failed"
}

# True when <file> holds a timestamp older than GITSRC_UPDATE_TTL seconds, or is missing
_gitsrc_older_than_ttl() {
  local last
  [[ -f "$1" ]] || return 0
  last=$(cat "$1" 2>/dev/null)
  [[ "$last" =~ ^[0-9]+$ ]] || return 0
  (( $(date +%s) - last > ${GITSRC_UPDATE_TTL:-86400} ))
}

# True when a repo was neither updated nor attempted-and-failed within GITSRC_UPDATE_TTL seconds
gitsrc_stale() {
  local file
  file=$(gitsrc_updated_file "$1")
  _gitsrc_older_than_ttl "$file" && _gitsrc_older_than_ttl "$file.failed"
}

# `src update [--auto] [alias...]`: clone missing and pull existing git sources, all of them or the
# named aliases. Local paths are never cloned or pulled. Sources with uncommitted changes are
# skipped and stay stale. False if any was skipped or failed.
# --auto: skipped sources are reported in one line (via debug with GITSRC_QUIET_SKIPPED=true).
gitsrc_update() {
  local auto=false
  [[ "${1:-}" == "--auto" ]] && { auto=true; shift; }
  local wanted=" $* " all_updated=true i repo_url repo_name dir skipped=() failed=()

  gitsrc_collect

  for i in "${!GITSRC_URLS[@]}"; do
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
      if anfs_repo_clone "$repo_url" "$dir"; then
        gitsrc_mark_updated "$repo_name"
      else
        gitsrc_mark_failed "$repo_name"
        failed+=("$repo_name")
        all_updated=false
      fi
      continue
    fi

    if anfs_repo_dirty "$dir"; then
      if $auto; then
        skipped+=("$repo_name")
      else
        echo "Skipping $repo_name: has uncommitted changes. Please commit or stash them first."
      fi
      all_updated=false
      continue
    fi

    echo "Updating: $repo_name"
    if anfs_repo_update "$dir"; then
      gitsrc_mark_updated "$repo_name"
    else
      gitsrc_mark_failed "$repo_name"
      failed+=("$repo_name")
      all_updated=false
    fi
  done

  if $auto && [[ ${#failed[@]} -gt 0 ]]; then
    local flist
    printf -v flist '%s, ' "${failed[@]}"
    echo "Not updated (unreachable): ${flist%, } — retried automatically after ${GITSRC_UPDATE_TTL:-86400}s, or now with: $GITSRC_TOOL src update"
  fi

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
  # The source may be the directory itself (a repo created in place, e.g. by anfs onboard)
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
  for i in "${!GITSRC_NAMES[@]}"; do
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
  local t
  GITSRC_DIRS=""
  for t in $ANFS_TOOLS; do GITSRC_DIRS="$GITSRC_DIRS $(anfs_tool_dir "$t")"; done
  # stacks/ is anfs's own (lib/anfs/stacks.sh), no tool's
  GITSRC_DIRS="${GITSRC_DIRS# } stacks"
}
