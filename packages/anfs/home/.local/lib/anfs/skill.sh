#!/usr/bin/env bash
# anfs: agent skills through the third-party skills CLI (npx skills), for psm and wsm.
#
# The engine psm was built on, with a scope: -g (the global one: ~/.agents/skills and each agent's
# home) or a directory (a project: <dir>/.agents/skills, <dir>/<agent dir>/skills, and
# <dir>/skills-lock.json). psm uses -g, wsm a space's directory. What the CLI does in each scope is
# in packages/psm/AGENTS.md ("What the skills CLI actually does").
#
#   anfs_skill_cli        <scope> <args...>     npx skills@$ANFS_SKILLS_CLI_VERSION, stdin closed;
#                                               -g put before the first option, or run in <dir>
#   anfs_skill_require                          npx on PATH (node through mise), or 1 with a message
#   anfs_skill_agents                           the agent ids of the installed ppm packages
#                                               (meta.agent), csv
#   anfs_skill_package_agents <repo/pkg>        one package's ids, one per line
#   anfs_skill_display    <id>                  the CLI's display name for an id, or 1
#   anfs_skill_id         <display name>        the id for a display name, or 1
#   anfs_skill_dir_skills <dir>                 the <name>/SKILL.md directly under <dir>, names
#   anfs_skill_load       <scope>               what is installed there: ANFS_SKILL_INSTALLED rows
#                                               <name>|<agent display names csv>|<source>|<path>
#   anfs_skill_has        <name> <agents csv>   installed for every one of them (after load)
#   anfs_skill_status     <name> <agents csv>   ok, partial, missing (after load)
#   anfs_skill_sync_rows  <scope> <force_local> <detected>   install the rows on stdin,
#                                               <label>|<repo>|<skills csv>|<agents csv>; the counts
#                                               in ANFS_SKILL_SYNCED/_CURRENT/_FAILED/_WAITING
#   anfs_skill_remove     <scope> <name>...     remove for every agent it is installed on, never
#                                               unscoped; then the shared .agents/skills/<name>
#                                               copy and its lock entry (ANFS_SKILL_REMOVED: names)
#   anfs_skill_unlink     <scope> <agent> <name>...   remove for one agent
#   anfs_skill_remove_for <scope> <agents csv> <name>...  remove for those agents only. In a project
#                                               scope a remove without -a sweeps every agent's
#                                               directory, skills/<name> and data/skills/<name>
#                                               among them, and globally ~/agent/skills/<name>
#                                               (packages/psm/AGENTS.md)
#
# Functions only, the bash floor. Messages go through log.sh (the caller's name). The version is
# ANFS_SKILLS_CLI_VERSION (anfs.env; default latest).

# The CLI. </dev/null: it reads stdin, which would otherwise swallow the rows of a loop feeding it.
# With -g the flag goes before the first option: skill names come before -a, which is variadic.
anfs_skill_cli() {
  local scope="$1" i
  shift
  local -a args=("$@")
  if [[ "$scope" == -g ]]; then
    for (( i = 0; i < ${#args[@]}; i++ )); do [[ "${args[i]}" != -* ]] || break; done
    args=("${args[@]:0:i}" -g ${args[@]+"${args[@]:i}"})
    npx --yes "skills@${ANFS_SKILLS_CLI_VERSION:-latest}" "${args[@]}" </dev/null
  else
    # A project scope is an existing absolute directory: `cd ""` would leave the CLI in the cwd
    if [[ "$scope" != /?* || ! -d "$scope" ]]; then
      anfs_warn "not a directory to install skills in: '$scope'"
      return 1
    fi
    ( cd -- "$scope" && exec npx --yes "skills@${ANFS_SKILLS_CLI_VERSION:-latest}" ${args[@]+"${args[@]}"} </dev/null )
  fi
}

# node comes from mise via the `node` dependency
anfs_skill_require() {
  command -v npx &>/dev/null && return 0
  if command -v mise &>/dev/null; then eval "$(mise env -s bash 2>/dev/null)" || true; fi
  command -v npx &>/dev/null && return 0
  anfs_warn "npx not found — install node first: ppm install node"
  return 1
}

# Skills-CLI agent ids a ppm package declares under meta.agent (one or a list), one per line;
# nothing when the package or its package.yml is gone
anfs_skill_package_agents() {
  local meta="$ANFS_SOURCES_HOME/${1%%/*}/packages/${1#*/}/package.yml"
  [[ -f "$meta" ]] || return 0
  yq -r '[.meta.agent] | flatten | .[] | select(. != null)' "$meta" 2>/dev/null || true
}

# The agent ids of every installed ppm package that declares meta.agent, csv. The package is read
# from the tracker's path, so a package a higher-priority source overrides is the installed one.
anfs_skill_agents() {
  local dir="${PPM_STATE_HOME:-$XDG_STATE_HOME/ppm}/installed" tracker repo pkg
  for tracker in "$dir"/*/*.yml; do
    [[ -f "$tracker" ]] || continue
    repo="${tracker%/*}" repo="${repo##*/}" pkg="${tracker##*/}" pkg="${pkg%.yml}"
    anfs_skill_package_agents "$repo/$pkg"
  done | sort -u | paste -sd, -
}

# `skills list --json` names agents by display name, the command line by id. An unknown id is 1,
# so its skills are re-added rather than wrongly taken as there.
anfs_skill_display() {
  case "$1" in
    claude-code)     echo "Claude Code" ;;
    opencode)        echo "OpenCode" ;;
    pi)              echo "Pi" ;;
    hermes-agent)    echo "Hermes Agent" ;;
    antigravity)     echo "Antigravity" ;;
    antigravity-cli) echo "Antigravity CLI" ;;
    *)               return 1 ;;
  esac
}

anfs_skill_id() {
  case "$1" in
    "Claude Code")     echo claude-code ;;
    OpenCode)          echo opencode ;;
    Pi)                echo pi ;;
    "Hermes Agent")    echo hermes-agent ;;
    Antigravity)       echo antigravity ;;
    "Antigravity CLI") echo antigravity-cli ;;
    *)                 return 1 ;;
  esac
}

# Skill names in a directory, one per line: every <name>/SKILL.md directly under it. Not -type f:
# ppm and wsm link SKILL.md.
anfs_skill_dir_skills() {
  local file
  find "$1" -mindepth 2 -maxdepth 2 -name SKILL.md 2>/dev/null | sort \
    | while IFS= read -r file; do file="${file%/*}"; printf '%s\n' "${file##*/}"; done
}

# A path for the CLI: ~ expanded
anfs_skill_expand() {
  case "$1" in
    "~")   printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# Whether a repo is a local path (copied by the CLI) rather than owner/repo or a URL
anfs_skill_is_local() {
  [[ "$1" == /* || "$1" == ./* || "$1" == ../* ]]
}

# What is installed in <scope>, one CLI run: ANFS_SKILL_INSTALLED, <name>|<agents>|<source> rows.
# A failed lookup gives nothing, so nothing is skipped.
ANFS_SKILL_INSTALLED=""
anfs_skill_load() {
  ANFS_SKILL_INSTALLED=$(anfs_skill_cli "$1" list --json 2>/dev/null \
    | yq -p json -r '.[] | [.name, ((.agents // []) | join(",")), (.source // ""), (.path // "")] | join("|")' 2>/dev/null) || true
}

# The agent display names <name> is installed for (after load); 1 when it is not installed
anfs_skill_installed_agents() {
  awk -F'|' -v n="$1" '$1 == n { print $2; found = 1; exit } END { exit !found }' <<< "$ANFS_SKILL_INSTALLED"
}

# Universal agents read the shared copy in .agents/skills themselves; the CLI's project-scope list
# leaves Pi out of a skill's agents (checked 2026-10-21, skills 1.7.4), so one counts as installed
# when the copy is there
anfs_skill_universal() { [[ "$1" == opencode || "$1" == pi ]]; }

# The path the CLI lists for <name> (after load)
anfs_skill_path() {
  awk -F'|' -v n="$1" '$1 == n { print $4; exit }' <<< "$ANFS_SKILL_INSTALLED"
}

anfs_skill_has() {
  local have agent display path=""
  have=$(anfs_skill_installed_agents "$1") || return 1
  for agent in ${2//,/ }; do
    display=$(anfs_skill_display "$agent") || return 1
    [[ ",$have," != *",$display,"* ]] || continue
    anfs_skill_universal "$agent" || return 1
    [[ -n "$path" ]] || path=$(anfs_skill_path "$1")
    [[ "$path" == */.agents/skills/"$1" ]] || return 1
  done
}

anfs_skill_status() {
  if anfs_skill_has "$1" "$2"; then echo ok
  elif anfs_skill_installed_agents "$1" >/dev/null; then echo partial
  else echo missing
  fi
}

# Install the rows read from stdin into <scope>, each for its agents or the detected ones. A skill
# is added when it is missing for an agent; "*" always (it cannot be enumerated ahead), and a local
# path's every time with <force_local> (a copy goes stale on edit). No agent yet is waiting, not a
# failure: installing an agent package syncs again. Returns 1 when an add failed.
ANFS_SKILL_SYNCED=0 ANFS_SKILL_CURRENT=0 ANFS_SKILL_FAILED=0 ANFS_SKILL_WAITING=0
anfs_skill_sync_rows() {
  local scope="$1" force_local="$2" detected="$3" label repo skills agents item n
  local -a list args
  ANFS_SKILL_SYNCED=0 ANFS_SKILL_CURRENT=0 ANFS_SKILL_FAILED=0 ANFS_SKILL_WAITING=0
  while IFS='|' read -r label repo skills agents; do
    [[ -n "$repo" ]] || continue
    repo=$(anfs_skill_expand "$repo")
    [[ -n "$agents" ]] || agents=$detected
    if [[ -z "$agents" ]]; then
      ANFS_SKILL_WAITING=$((ANFS_SKILL_WAITING + 1))
      continue
    fi
    args=(add "$repo" -y)
    n=${#args[@]}
    IFS=',' read -r -a list <<< "$skills"
    for item in ${list[@]+"${list[@]}"}; do
      if [[ "$item" == '*' ]] || { $force_local && anfs_skill_is_local "$repo"; } || ! anfs_skill_has "$item" "$agents"; then
        args+=(-s "$item")
      fi
    done
    if [[ ${#args[@]} -eq $n ]]; then
      echo "ok     $repo"
      ANFS_SKILL_CURRENT=$((ANFS_SKILL_CURRENT + 1))
      continue
    fi
    for item in ${agents//,/ }; do args+=(-a "$item"); done
    echo "sync   $repo"
    if anfs_skill_cli "$scope" "${args[@]}"; then
      ANFS_SKILL_SYNCED=$((ANFS_SKILL_SYNCED + 1))
    else
      anfs_warn "skills add $repo failed"
      ANFS_SKILL_FAILED=$((ANFS_SKILL_FAILED + 1))
    fi
  done
  [[ $ANFS_SKILL_FAILED -eq 0 ]]
}

# A remove is never unscoped: without -a the CLI sweeps every agent's directory, which in a project
# includes skills/<name> and data/skills/<name>, and globally ~/agent/skills/<name>: the user's own
# files. So each name is removed for the agents `list` says it is on (the ids known), in one call,
# and what that keeps for universal agents goes after: the copy in <base>/.agents/skills/<name> (a
# real directory) and its lock entry (<dir>/skills-lock.json; globally ~/.agents/.skill-lock.json). A name not installed is skipped; one on
# agents with no known id is said. Returns 1 when the CLI failed.
ANFS_SKILL_REMOVED=()
anfs_skill_remove() {
  local scope="$1" base n have d a ids="," lock=""
  shift
  ANFS_SKILL_REMOVED=()
  [[ $# -gt 0 ]] || return 0
  if [[ "$scope" == -g ]]; then base="$HOME" lock="$HOME/.agents/.skill-lock.json"
  else
    [[ "$scope" == /?* && -d "$scope" ]] || { anfs_warn "not a directory to remove skills from: '$scope'"; return 1; }
    base="$scope" lock="$scope/skills-lock.json"
  fi
  [[ -n "$base" && "$base" == /?* ]] || return 1
  anfs_skill_load "$scope"
  for n in "$@"; do
    [[ -n "$n" && "$n" != */* && "$n" != . && "$n" != .. ]] || continue
    have=$(anfs_skill_installed_agents "$n") || continue
    local known=false
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      if a=$(anfs_skill_id "$d"); then
        known=true
        [[ "$ids" == *",$a,"* ]] || ids+="$a,"
      else
        anfs_warn "$n stays for $d: no known agent id for it"
      fi
    done < <(tr ',' '\n' <<< "$have")
    # Only on agents with no known id: left as it is, copy included
    ! $known || ANFS_SKILL_REMOVED+=("$n")
  done
  [[ ${#ANFS_SKILL_REMOVED[@]} -gt 0 ]] || return 0
  ids="${ids#,}" ids="${ids%,}"
  if [[ -n "$ids" ]]; then
    anfs_skill_remove_for "$scope" "$ids" "${ANFS_SKILL_REMOVED[@]}" || return 1
  fi
  for n in "${ANFS_SKILL_REMOVED[@]}"; do
    d="$base/.agents/skills/$n"
    if [[ -d "$d" && ! -L "$d" ]]; then rm -rf -- "$d"; fi
    if [[ -n "$lock" && -f "$lock" ]]; then
      ANFS_SKILL_N="$n" yq -i -p json -o json 'del(.skills[strenv(ANFS_SKILL_N)])' "$lock" 2>/dev/null ||
        anfs_warn "cannot update $lock"
    fi
  done
}

# Names before -a: the CLI's -a takes every argument after it as an agent
anfs_skill_unlink() {
  local scope="$1" agent="$2"
  shift 2
  [[ $# -gt 0 ]] || return 0
  anfs_skill_cli "$scope" remove "$@" -y -a "$agent"
}

anfs_skill_remove_for() {
  local scope="$1" agents="$2" a
  shift 2
  [[ $# -gt 0 && -n "$agents" ]] || return 0
  local -a args=(remove "$@" -y -a)
  for a in ${agents//,/ }; do args+=("$a"); done
  anfs_skill_cli "$scope" "${args[@]}"
}
