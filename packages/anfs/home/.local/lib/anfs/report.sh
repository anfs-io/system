#!/usr/bin/env bash
# anfs: `anfs report`, a bug in an anfs tool as an issue in markdown, filed where the machine says
#
#   anfs report [new] --title T [--package PKG] [--expected TEXT] [--actual TEXT] [--steps TEXT]
#                     [--body-file F|-] [-n] [-y]      build it, file it, print its id
#   anfs report diag                                    the diagnostics block only
#   anfs report check                                   can this machine file one: CHECK STATUS DETAIL
#   anfs report status <id>                             open, fixed or available (exit 0, 1, 1; 2 unknown)
#   anfs report close <id> --commit SHA [--source S]    the fix: recorded on the report, closed
#   anfs report wait <id> [--timeout S]                 until available (0) or the timeout (1), on events
#
# WHERE IT GOES is ANFS_REPORT_TO (anfs.env; a machine's in anfs.local.env), never the caller's
# choice: `github` (the default) or a file (a leading ~/ is $HOME; it must then be absolute).
#   github  the owner source's origin names the repo (core unless --package names another source);
#           duplicates are searched (gh issue list) and shown, then gh issue create after a yes
#           (-y). The id is <owner>/<repo>#<number>. A non-GitHub origin is an error that says to
#           set ANFS_REPORT_TO to a file.
#   a file  appended, never rewritten: `## r-<YYYYMMDD>-<n> <title>`, `Status: open`, the body.
#           <n> counts that day's reports in the file. `close` rewrites that one Status line only.
#
# EVENTS (lib/anfs/events.sh): `new` emits report.filed (data: package, title, to, and repo for
# GitHub) and `close` report.closed (data: commit, source), into the file's space, or the host
# scope for GitHub; -n emits nothing. `wait` waits on events: it reads the state once, then
# follows the report's scope and the host scope and reads it again only on this report's
# report.closed or a source.updated (anfs src update emits one per source whose HEAD moved): one
# git merge-base per event, none per tick. The bare form of waiting for the close:
#   wsm events ls -f --once --type report.closed --subject <id>
#
# THE FIX. `close` records the commit: a file's Status line becomes `Status: fixed in <source>
# <sha> (<date>)`; on GitHub a comment `Fixed in <source> <sha>` and gh issue close. `status` is
#   open       not closed
#   fixed      closed, and the commit is not (yet) in this host's checkout of the source
#   available  the commit is an ancestor of HEAD in the source's live checkout
#              ($ANFS_SOURCES_HOME/<alias>), or with ANFS_WORK in the job's worktree of it
#
# Another tool's state is read as files: ppm's trackers ($PPM_STATE_HOME/installed/<src>/<pkg>.yml),
# as onboard.sh does; running ppm would fail when ppm is what is broken.
#
# Functions only, the bash floor. Needs paths.sh, log.sh, cli.sh, table.sh, sources.sh and
# config.sh (check's FROM), which anfs sources; platform.sh (diag) and skill.sh (check's skill row)
# are sourced here when a command needs them, so a tab press does not pay for them.

ANFS_REPORT_SKILL=anfs-bug-report

# Source a sibling library for the one command that needs it
_anfs_report_need() {
  declare -F "$1" >/dev/null && return 0
  # shellcheck source=/dev/null
  source "$ANFS_LIB_DIR/$2"
}

anfs_report_cli() {
  cli_group report "Report a bug in an anfs tool, where ANFS_REPORT_TO says (github or a file),
and follow it until the fix is here" --default new
  cli_cmd "report new" "Build the report (title, expected, actual, steps, and the diagnostics),
file it, and print its id. No sub-command: these options go here" \
    --opt "--package PACKAGE: The package it is about (source/name, or an installed name); its source owns it (default core)" \
    --opt "--title TEXT: One line" \
    --opt "--expected TEXT: What was expected" \
    --opt "--actual TEXT: What happened" \
    --opt "--steps TEXT: The steps to reproduce" \
    --opt "--body-file FILE: More text, placed first (- reads stdin)" \
    --opt "-n --dry-run: Print the report and where it would go; file nothing (no gh call)" \
    --opt "-y --yes: Do not ask before filing on GitHub"
  cli_cmd "report diag" "Print the diagnostics block only: versions, sources, packages, the log's failures"
  cli_cmd "report check" "Can this machine file a report: one ok or fail row per item; exit 1
when one fails"
  cli_cmd "report status" "open, fixed (not yet in this host's checkout) or available; exit 0
when available, 1 otherwise, 2 for an unknown id" --arg "id"
  cli_cmd "report close" "Record the commit that fixes a report and close it" \
    --opt "--commit SHA: The fix" \
    --opt "--source SOURCE: The source the commit is in (default: the report's repo's, or core)" \
    --arg "id"
  cli_cmd "report wait" "Wait until the fix is available here (exit 0), or the timeout (1); 2 for
an unknown id. Waits on events: the state is read again on the report's
report.closed and on each source.updated (anfs src update), never on a
timer. A GitHub issue closed by hand is seen at the next source.updated.
The bare form: wsm events ls -f --once --type report.closed --subject <id>" \
    --opt "--timeout SECS: Give up after this long (default 3600)" \
    --arg "id"
}

# The installed packages' names, for --package (file names only)
complete_package() {
  local t
  for t in "${PPM_STATE_HOME:-$XDG_STATE_HOME/ppm}"/installed/*/*.yml; do
    [[ -f "$t" ]] || continue
    t="${t%.yml}"
    printf '%s\n' "${t#*/installed/}"
  done
}

# --- Where it goes --------------------------------------------------------------------------

# ANFS_REPORT_TO into _R_TO (github, file) and _R_FILE; 1 with _R_WHY when the value is neither
_anfs_report_dest_try() {
  local v="${ANFS_REPORT_TO:-github}"
  _R_TO="" _R_FILE="" _R_WHY=""
  if [[ "$v" == github ]]; then _R_TO=github; return 0; fi
  anfs_conf_expand "$v"
  if [[ "$REPLY" != /* ]]; then
    _R_WHY="ANFS_REPORT_TO is '$v': github or an absolute path (anfs config set ANFS_REPORT_TO=~/bugs.md)"
    return 1
  fi
  _R_TO=file _R_FILE="$REPLY"
}

_anfs_report_dest() { _anfs_report_dest_try || anfs_die "$_R_WHY"; }

# owner/repo of a GitHub URL into REPLY; 1 for any other
anfs_report_gh_repo() {
  local r
  case "$1" in
    git@github.com:*)                  r="${1#git@github.com:}" ;;
    ssh://git@github.com/*)            r="${1#ssh://git@github.com/}" ;;
    https://github.com/*|http://github.com/*) r="${1#*://github.com/}" ;;
    *) return 1 ;;
  esac
  r="${r%/}" r="${r%.git}"
  [[ "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  REPLY="$r"
}

# A source's GitHub repo into REPLY; 1 with _R_WHY when it has none (after gitsrc_collect)
_anfs_report_source_repo() {
  local alias="$1" url dir
  _R_WHY=""
  gitsrc_dir_reply "$alias"; dir="$REPLY"
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || url=""
  if [[ -z "$url" ]]; then
    _R_WHY="$alias has no origin ($(anfs_display "$dir") is not a clone): set ANFS_REPORT_TO to a file (anfs config set ANFS_REPORT_TO=~/bugs.md)"
    return 1
  fi
  anfs_report_gh_repo "$url" && return 0
  _R_WHY="$alias's origin ($url) is not on GitHub: set ANFS_REPORT_TO to a file (anfs config set ANFS_REPORT_TO=~/bugs.md)"
  return 1
}

_anfs_report_is_source() {
  local n
  for n in ${GITSRC_NAMES[@]+"${GITSRC_NAMES[@]}"}; do [[ "$n" != "$1" ]] || return 0; done
  return 1
}

# --package into _R_SOURCE (the owner) and _R_PKG (source/name; empty for none)
_anfs_report_owner() {
  local p="$1" s dir="${PPM_STATE_HOME:-$XDG_STATE_HOME/ppm}/installed"
  _R_SOURCE=core _R_PKG=""
  [[ -n "$p" ]] || return 0
  if [[ "$p" == */* ]]; then
    _anfs_report_is_source "${p%%/*}" || anfs_die "--package $p: no source ${p%%/*} (anfs src list)"
    _R_SOURCE="${p%%/*}" _R_PKG="$p"
    return 0
  fi
  for s in ${GITSRC_NAMES[@]+"${GITSRC_NAMES[@]}"}; do
    [[ -f "$dir/$s/$p.yml" ]] || continue
    _R_SOURCE="$s" _R_PKG="$s/$p"
    return 0
  done
  for s in ${GITSRC_NAMES[@]+"${GITSRC_NAMES[@]}"}; do
    gitsrc_dir_reply "$s"
    [[ -d "$REPLY/packages/$p" ]] || continue
    _R_SOURCE="$s" _R_PKG="$s/$p"
    return 0
  done
  anfs_die "--package $p: not installed and in no source (ppm list)"
}

# --- The diagnostics ------------------------------------------------------------------------

_anfs_report_os_version() {
  if [[ "$OSTYPE" == darwin* ]]; then
    command -v sw_vers >/dev/null && printf 'macOS %s' "$(sw_vers -productVersion 2>/dev/null)"
  else
    local f="${PPM_OS_RELEASE:-/etc/os-release}"
    [[ -r "$f" ]] && (. "$f" && printf '%s' "${PRETTY_NAME:-}")
  fi
  return 0
}

# The log's recent failures: the last 10 of an error line, or a failed run's start and end lines
_anfs_report_log_failures() {
  anfs_log_file || return 0
  [[ -f "$ANFS_LOG_FILE" ]] || return 0
  awk '
    $3 == "start:" { start[$4] = $0; next }
    $3 == "error:" { e[n++] = $0; next }
    $3 == "end:" && $5 != "0" { e[n++] = (($4 in start) ? start[$4] "\n" : "") $0 }
    END { for (i = (n > 10 ? n - 10 : 0); i < n; i++) print e[i] }
  ' "$ANFS_LOG_FILE" 2>/dev/null || true
}

anfs_report_diag() {
  local v s dir commit t name failures
  _anfs_report_need platform platform.sh
  [[ -n "${CLI_VERSION:-}" ]] || cli_package_version
  echo "### Diagnostics"
  echo
  echo "- anfs: ${CLI_VERSION:-unknown}"
  [[ -z "${ANFS_WORK:-}" ]] || echo "- ANFS_WORK: $ANFS_WORK (a job's code)"
  v=$(_anfs_report_os_version)
  echo "- platform: $(platform) ($(uname -sr), $(uname -m)${v:+; $v})"
  echo "- bash: $BASH_VERSION"
  ! command -v git >/dev/null || { v=$(git --version 2>/dev/null) && echo "- git: ${v#git version }"; } || true
  ! command -v podman >/dev/null || { v=$(podman --version 2>/dev/null) && echo "- podman: ${v#podman version }"; } || true
  gitsrc_collect
  if (( ${#GITSRC_NAMES[@]} )); then
    printf '\nSources:\n\n| Source | Commit | Status |\n| --- | --- | --- |\n'
    for s in "${GITSRC_NAMES[@]}"; do
      gitsrc_dir_reply "$s"; dir="$REPLY"
      commit=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null) || commit="-"
      printf '| %s | %s | %s |\n' "$s" "$commit" "$(anfs_repo_status "$dir")"
    done
  fi
  local -a rows=()
  for t in "${PPM_STATE_HOME:-$XDG_STATE_HOME/ppm}"/installed/*/*.yml; do
    [[ -f "$t" ]] || continue
    name="${t%.yml}" name="${name#*/installed/}" v="-"
    while IFS= read -r s; do
      [[ "$s" == version:* ]] || continue
      v="${s#version:}" v="${v//[ \"\']/}"
      break
    done < "$t"
    rows+=("| $name | $v |")
  done
  if (( ${#rows[@]} )); then
    printf '\nInstalled packages:\n\n| Package | Version |\n| --- | --- |\n'
    printf '%s\n' "${rows[@]}"
  fi
  failures=$(_anfs_report_log_failures)
  if [[ -n "$failures" ]]; then
    printf '\nRecent failures in the log (%s):\n\n```\n%s\n```\n' "$(anfs_display "$ANFS_LOG_FILE")" "$failures"
  fi
}

cmd_report_diag() {
  local out
  out=$(anfs_report_diag)
  if anfs_json_on; then anfs_result diagnostics "$out"; else printf '%s\n' "$out"; fi
}

# --- new ------------------------------------------------------------------------------------

# The body: the package, the body file's text, the sections given, the diagnostics
_anfs_report_body() {
  local text="$1" o h
  [[ -z "$_R_PKG" ]] || printf 'Package: `%s`\n\n' "$_R_PKG"
  [[ -z "$text" ]] || printf '%s\n\n' "$text"
  for o in expected actual steps; do
    [[ -n "${CLI_OPT[$o]:-}" ]] || continue
    case "$o" in
      expected) h="What was expected" ;;
      actual)   h="What happened" ;;
      steps)    h="Steps to reproduce" ;;
    esac
    printf '### %s\n\n%s\n\n' "$h" "${CLI_OPT[$o]}"
  done
  anfs_report_diag
}

# The next file id for today into REPLY: r-<YYYYMMDD>-<n>, n one past the highest of the day
_anfs_report_next_id() {
  local day n=0 line
  printf -v day '%(%Y%m%d)T' -1
  if [[ -f "$1" ]]; then
    while IFS= read -r line; do
      [[ "$line" =~ ^##\ r-$day-([0-9]+)( |$) ]] || continue
      (( 10#${BASH_REMATCH[1]} <= n )) || n=$(( 10#${BASH_REMATCH[1]} ))
    done < "$1"
  fi
  REPLY="r-$day-$(( n + 1 ))"
}

# A JSON string, or null for an empty one
_anfs_report_q() { if [[ -n "$1" ]]; then _anfs_json_str "$1"; else printf null; fi; }

# --json's answer of new: one object (duplicates: tab-separated number, state, title, url rows)
_anfs_report_json() {
  local id="$1" repo="$2" file="$3" url="$4" filed="$5" dups="$6" report="$7" title="$8" first=true n st ti u
  printf '{"id":'; _anfs_report_q "$id"
  printf ',"to":'; _anfs_report_q "$_R_TO"
  printf ',"repo":'; _anfs_report_q "$repo"
  printf ',"file":'; _anfs_report_q "$file"
  printf ',"url":'; _anfs_report_q "$url"
  printf ',"title":'; _anfs_report_q "$title"
  printf ',"filed":%s,"duplicates":[' "$filed"
  while IFS=$'\t' read -r n st ti u; do
    [[ -n "$n" ]] || continue
    $first || printf ','
    first=false
    printf '{"number":'; _anfs_json_str "$n"
    printf ',"state":'; _anfs_json_str "$st"
    printf ',"title":'; _anfs_json_str "$ti"
    printf ',"url":'; _anfs_json_str "$u"
    printf '}'
  done <<< "$dups"
  printf '],"report":'; _anfs_json_str "$report"
  printf '}\n'
}

cmd_report_new() {
  local title="${CLI_OPT[title]:-}" bodyfile="${CLI_OPT[body-file]:-}" dry="${CLI_OPT[dry-run]:-false}"
  local text="" report id repo dups="" tmp url
  [[ -n "$title" ]] || cli_usage_err "--title is required"
  [[ "$title" != *$'\n'* ]] || cli_usage_err "--title is one line"
  [[ -n "${CLI_OPT[expected]:-}${CLI_OPT[actual]:-}${CLI_OPT[steps]:-}$bodyfile" ]] ||
    cli_usage_err "say what happened: --actual, --expected, --steps or --body-file"
  if [[ "$bodyfile" == - ]]; then
    text=$(cat)
  elif [[ -n "$bodyfile" ]]; then
    [[ -f "$bodyfile" ]] || anfs_die "--body-file: no file $bodyfile"
    text=$(< "$bodyfile")
  fi
  gitsrc_collect
  _anfs_report_owner "${CLI_OPT[package]:-}"
  _anfs_report_dest
  report=$(_anfs_report_body "$text")

  if [[ "$_R_TO" == file ]]; then
    _anfs_report_next_id "$_R_FILE"; id="$REPLY"
    if $dry; then
      if anfs_json_on; then _anfs_report_json "$id" "" "$_R_FILE" "" false "" "$report" "$title"; return 0; fi
      printf '%s\n\n' "$report"
      anfs_info "would be $id, appended to $(anfs_display "$_R_FILE")"
      return 0
    fi
    mkdir -p "${_R_FILE%/*}" || anfs_die "cannot make $(anfs_display "${_R_FILE%/*}")"
    {
      if [[ -s "$_R_FILE" ]]; then
        [[ -z "$(tail -c 1 "$_R_FILE")" ]] || echo
        echo
      fi
      printf '## %s %s\n\nStatus: open\n\n%s\n' "$id" "$title" "$report"
    } >> "$_R_FILE" || anfs_die "could not append to $(anfs_display "$_R_FILE")"
    _anfs_report_emit --at "${_R_FILE%/*}" report.filed "$id" ${_R_PKG:+"package=$_R_PKG"} "title=$title" to=file
    if anfs_json_on; then _anfs_report_json "$id" "" "$_R_FILE" "" true "" "$report" "$title"
    else anfs_info "$id: appended to $(anfs_display "$_R_FILE")"
    fi
    return 0
  fi

  _anfs_report_source_repo "$_R_SOURCE" || anfs_die "$_R_WHY"
  repo="$REPLY"
  if $dry; then
    if anfs_json_on; then _anfs_report_json "" "$repo" "" "" false "" "$report" "$title"; return 0; fi
    printf '%s\n\n' "$report"
    anfs_info "would go to: github $repo (an issue; duplicates are searched when it is filed)"
    return 0
  fi
  anfs_require gh "brew install gh"
  dups=$(gh issue list --repo "$repo" --state all --search "$title in:title" --limit 10 \
    --json number,state,title,url --jq '.[] | [(.number|tostring), .state, .title, .url] | @tsv') ||
    anfs_die "gh issue list on $repo failed (anfs report check)"
  if [[ -n "$dups" ]]; then
    {
      echo "possible duplicates on $repo:"
      while IFS=$'\t' read -r n st ti u; do printf '  #%s %s %s %s\n' "$n" "$st" "$ti" "$u"; done <<< "$dups"
    } >&"$(anfs_json_on && echo 2 || echo 1)"
  fi
  anfs_confirm "report files an issue on $repo: $title" "File it on $repo?"
  tmp=$(mktemp "${TMPDIR:-/tmp}/anfs-report.XXXXXX")
  printf '%s\n' "$report" > "$tmp"
  if ! url=$(gh issue create --repo "$repo" --title "$title" --body-file "$tmp"); then
    rm -f "$tmp"
    anfs_die "gh issue create on $repo failed"
  fi
  rm -f "$tmp"
  url=$(printf '%s\n' "$url" | grep -E '^https?://' | tail -n 1) || true
  [[ "$url" =~ /issues/([0-9]+)$ ]] || anfs_die "gh issue create gave no issue URL: $url"
  id="$repo#${BASH_REMATCH[1]}"
  _anfs_report_emit --host report.filed "$id" ${_R_PKG:+"package=$_R_PKG"} "title=$title" to=github "repo=$repo"
  if anfs_json_on; then _anfs_report_json "$id" "$repo" "" "$url" true "$dups" "$report" "$title"
  else anfs_info "$id: $url"
  fi
}

# --- events (lib/anfs/events.sh) ---------------------------------------------------------------

# report.filed and report.closed, into the scope the report is filed in: a file's space (the
# nearest space.yml above it), or the host scope for GitHub. Never fails the command.
_anfs_report_emit() {
  declare -F anfs_emit >/dev/null || return 0
  anfs_emit "$@"
}

# --- status, close, wait --------------------------------------------------------------------

# An id's kind into _R_KIND (file, github); for github also _R_REPO and _R_NUM. 1 when it is none
_anfs_report_parse_id() {
  _R_KIND="" _R_REPO="" _R_NUM=""
  if [[ "$1" =~ ^r-[0-9]{8}-[0-9]+$ ]]; then _R_KIND=file; return 0; fi
  if [[ "$1" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
    _R_KIND=github _R_REPO="${BASH_REMATCH[1]}" _R_NUM="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# A file report's Status value into REPLY; 1 when the file has no such report
_anfs_report_file_status() {
  local file="$1" id="$2" out
  [[ -f "$file" ]] || return 1
  out=$(awk -v id="$id" '
    $0 == "## " id || index($0, "## " id " ") == 1 { in_s = 1; found = 1; next }
    in_s && /^## / { exit }
    in_s && /^Status: / { sub(/^Status: /, ""); print; exit }
    END { if (!found) exit 3 }
  ' "$file") || return 1
  REPLY="${out:-open}"
}

# The checkouts a commit counts in for <alias>: the live one, and with ANFS_WORK the job's
_anfs_report_checkouts() {
  gitsrc_dir_reply "$1"
  printf '%s\n' "$REPLY"
  [[ -n "${ANFS_WORK:-}" ]] || return 0
  if ! declare -F anfs_work_job >/dev/null && [[ -f "$ANFS_LIB_DIR/work.sh" ]]; then
    # shellcheck source=/dev/null
    _ANFS_WORK_LOAD_ONLY=1 source "$ANFS_LIB_DIR/work.sh"
  fi
  declare -F anfs_work_job >/dev/null || return 0
  anfs_work_job || return 0
  [[ ! -d "$REPLY/$1" ]] || printf '%s\n' "$REPLY/$1"
}

# True when <sha> is an ancestor of HEAD in a checkout of <alias>
_anfs_report_in_checkout() {
  local d
  while IFS= read -r d; do
    git -C "$d" merge-base --is-ancestor "$2" HEAD 2>/dev/null && return 0
  done < <(_anfs_report_checkouts "$1")
  return 1
}

# An id's state: _R_STATUS (open, fixed, available), _R_FIX_SOURCE, _R_FIX_COMMIT, _R_DETAIL.
# Returns 0 available, 1 open or fixed, 2 unknown id, 3 gh could not be asked (_R_DETAIL says)
_anfs_report_state() {
  local id="$1" out state line
  _R_STATUS="" _R_FIX_SOURCE="" _R_FIX_COMMIT="" _R_DETAIL=""
  if ! _anfs_report_parse_id "$id"; then
    _R_DETAIL="'$id' is no report id (r-<date>-<n>, or owner/repo#<n>)"
    return 2
  fi
  gitsrc_collect
  if [[ "$_R_KIND" == file ]]; then
    _anfs_report_dest_try || { _R_DETAIL="$_R_WHY"; return 2; }
    if [[ "$_R_TO" != file ]]; then
      _R_DETAIL="$id is a file's report, and ANFS_REPORT_TO is github"
      return 2
    fi
    if ! _anfs_report_file_status "$_R_FILE" "$id"; then
      _R_DETAIL="no report $id in $(anfs_display "$_R_FILE")"
      return 2
    fi
    if [[ "$REPLY" =~ ^fixed\ in\ ([^ ]+)\ ([0-9a-fA-F]+) ]]; then
      state=closed _R_FIX_SOURCE="${BASH_REMATCH[1]}" _R_FIX_COMMIT="${BASH_REMATCH[2]}"
    elif [[ "$REPLY" == open ]]; then
      state=open
    else
      state=closed
    fi
  else
    if ! command -v gh >/dev/null; then _R_DETAIL="gh is not on PATH (brew install gh)"; return 3; fi
    if ! out=$(gh issue view "$_R_NUM" --repo "$_R_REPO" --json state,comments \
        --jq '.state, (.comments[] | .body | split("\n")[0])' 2>&1); then
      _R_DETAIL="gh issue view $_R_NUM --repo $_R_REPO: ${out%%$'\n'*}"
      return 3
    fi
    state="${out%%$'\n'*}" state="${state,,}"
    while IFS= read -r line; do
      [[ "$line" =~ ^Fixed\ in\ ([A-Za-z0-9_.-]+)\ ([0-9a-fA-F]{7,40}) ]] || continue
      _R_FIX_SOURCE="${BASH_REMATCH[1]}" _R_FIX_COMMIT="${BASH_REMATCH[2]}"
    done <<< "$out"
  fi
  if [[ "$state" == open ]]; then
    _R_STATUS=open _R_DETAIL="not fixed yet"
    return 1
  fi
  _R_STATUS=fixed
  if [[ -z "$_R_FIX_COMMIT" ]]; then
    _R_DETAIL="closed with no commit named"
    return 1
  fi
  if _anfs_report_in_checkout "$_R_FIX_SOURCE" "$_R_FIX_COMMIT"; then
    _R_STATUS=available _R_DETAIL="$_R_FIX_SOURCE $_R_FIX_COMMIT is in this host's checkout"
    return 0
  fi
  _R_DETAIL="$_R_FIX_SOURCE $_R_FIX_COMMIT is not in this host's checkout yet (anfs src update $_R_FIX_SOURCE)"
  return 1
}

_anfs_report_say_state() {
  if anfs_json_on; then
    anfs_result id "$1" status "$_R_STATUS" source "$_R_FIX_SOURCE" commit "$_R_FIX_COMMIT" detail "$_R_DETAIL"
  else
    anfs_info "$1: $_R_STATUS ($_R_DETAIL)"
  fi
}

cmd_report_status() {
  local rc=0
  _anfs_report_state "$1" || rc=$?
  case "$rc" in
    2|3) anfs_fail 2 "$_R_DETAIL" ;;
  esac
  _anfs_report_say_state "$1"
  return "$rc"
}

# The scopes a report's events go to, and source.updated's (the host scope), into ANFS_EVENTS_DIRS
_anfs_report_scopes() {
  local sid=""
  if [[ "$_R_KIND" == file ]] && _anfs_report_dest_try && [[ "$_R_TO" == file ]] &&
     anfs_events_space_at "${_R_FILE%/*}"; then
    sid="$ANFS_EV_SID"
  fi
  ANFS_EVENTS_DIRS=("$ANFS_EVENTS_HOME/host") ANFS_EVENTS_EVERY=false
  [[ -z "$sid" ]] || ANFS_EVENTS_DIRS+=("$ANFS_EVENTS_HOME/$sid")
}

# A followed event, for wait: the state read again on a report.closed of this id or a
# source.updated, and nothing else; 0 (stop) once it is available, or the id is unknown
_anfs_report_wait_event() {
  _anfs_ev_parse "$1" || return 1
  [[ "$EV_TYPE" == source.updated || ( "$EV_TYPE" == report.closed && "$EV_SUBJECT" == "$_R_WAIT_ID" ) ]] || return 1
  _R_WAIT_RC=0
  _anfs_report_state "$_R_WAIT_ID" || _R_WAIT_RC=$?
  case "$_R_WAIT_RC" in
    0|2) return 0 ;;
    3) anfs_warn "$_R_DETAIL; waiting for the next event" ;;
  esac
  return 1
}

# The state once; then the report's scope and the host scope followed (events.sh), the state read
# again only on a report.closed of this id or a source.updated: one git merge-base per event, none
# per tick. A GitHub issue closed by hand emits nothing: wait sees it at the next source.updated.
cmd_report_wait() {
  local id="$1" timeout="${CLI_OPT[timeout]:-3600}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || cli_usage_err "--timeout is seconds"
  _anfs_report_need anfs_events_follow events.sh
  _anfs_report_parse_id "$id" || anfs_fail 2 "'$id' is no report id (r-<date>-<n>, or owner/repo#<n>)"
  _anfs_report_scopes
  anfs_events_follow_init
  _R_WAIT_ID="$id" _R_WAIT_RC=0
  _anfs_report_state "$id" || _R_WAIT_RC=$?
  case "$_R_WAIT_RC" in
    0) _anfs_report_say_state "$id"; return 0 ;;
    2) anfs_fail 2 "$_R_DETAIL" ;;
    3) anfs_warn "$_R_DETAIL; waiting for an event" ;;
  esac
  if anfs_events_follow _anfs_report_wait_event $(( EPOCHSECONDS + timeout )); then
    [[ "$_R_WAIT_RC" != 2 ]] || anfs_fail 2 "$_R_DETAIL"
    _anfs_report_say_state "$id"
    return 0
  fi
  [[ "$_R_WAIT_RC" != 3 ]] || _R_STATUS=unknown
  anfs_json_on || anfs_warn "timed out after ${timeout}s"
  _anfs_report_say_state "$id"
  return 1
}

cmd_report_close() {
  local id="$1" commit="${CLI_OPT[commit]:-}" src="${CLI_OPT[source]:-}" day line tmp s
  [[ -n "$commit" ]] || cli_usage_err "--commit is required"
  [[ "$commit" =~ ^[0-9a-fA-F]{7,40}$ ]] || cli_usage_err "--commit is a commit's sha (7 to 40 hex digits)"
  _anfs_report_parse_id "$id" || anfs_fail 2 "'$id' is no report id (r-<date>-<n>, or owner/repo#<n>)"
  gitsrc_collect
  [[ -z "$src" ]] || _anfs_report_is_source "$src" || anfs_die "--source $src: no such source (anfs src list)"
  printf -v day '%(%Y-%m-%d)T' -1
  if [[ "$_R_KIND" == file ]]; then
    src="${src:-core}"
    _anfs_report_dest
    [[ "$_R_TO" == file ]] || anfs_fail 2 "$id is a file's report, and ANFS_REPORT_TO is github"
    _anfs_report_file_status "$_R_FILE" "$id" || anfs_fail 2 "no report $id in $(anfs_display "$_R_FILE")"
    # that section's Status line only; everything else byte for byte (a temp file beside it, mv)
    tmp=$(mktemp "${_R_FILE%/*}/.${_R_FILE##*/}.XXXXXX") || anfs_die "cannot write beside $(anfs_display "$_R_FILE")"
    cp -p -- "$_R_FILE" "$tmp"
    if ! awk -v id="$id" -v st="Status: fixed in $src $commit ($day)" '
        !done && ($0 == "## " id || index($0, "## " id " ") == 1) { in_s = 1; print; next }
        in_s && /^## / { in_s = 0 }
        in_s && /^Status: / { print st; in_s = 0; done = 1; next }
        { print }
      ' "$_R_FILE" > "$tmp" || ! mv -f -- "$tmp" "$_R_FILE"; then
      rm -f -- "$tmp"
      anfs_die "could not write $(anfs_display "$_R_FILE")"
    fi
    _anfs_report_emit --at "${_R_FILE%/*}" report.closed "$id" "commit=$commit" "source=$src"
    if anfs_json_on; then anfs_result id "$id" status fixed source "$src" commit "$commit" file "$_R_FILE"
    else anfs_info "$id: fixed in $src $commit ($(anfs_display "$_R_FILE"))"
    fi
    return 0
  fi
  if [[ -z "$src" ]]; then
    for s in ${GITSRC_NAMES[@]+"${GITSRC_NAMES[@]}"}; do
      _anfs_report_source_repo "$s" && [[ "$REPLY" == "$_R_REPO" ]] && { src="$s"; break; }
    done
    [[ -n "$src" ]] || anfs_die "no source has $_R_REPO as its origin: name it with --source"
  fi
  anfs_require gh "brew install gh"
  gh issue comment "$_R_NUM" --repo "$_R_REPO" --body "Fixed in $src $commit (anfs report close, $day)" >/dev/null ||
    anfs_die "gh issue comment on $id failed"
  gh issue close "$_R_NUM" --repo "$_R_REPO" >/dev/null || anfs_die "gh issue close on $id failed"
  _anfs_report_emit --host report.closed "$id" "commit=$commit" "source=$src"
  if anfs_json_on; then anfs_result id "$id" status fixed source "$src" commit "$commit"
  else anfs_info "$id: fixed in $src $commit, closed"
  fi
}

# --- check ----------------------------------------------------------------------------------

# One check row into the rows; a fail marks the run
_anfs_report_row() {
  _R_ROWS+=("$1$ANFS_US$2$ANFS_US$3")
  [[ "$2" == ok ]] || _R_FAILED=1
}

# Where ANFS_REPORT_TO's value is from, into REPLY: config.sh's FROM and its file
_anfs_report_to_from() {
  local i
  REPLY="built in"
  if declare -F _anfs_config_collect >/dev/null; then
    _anfs_config_collect anfs
    for i in "${!_CF_NAMES[@]}"; do
      [[ "${_CF_NAMES[$i]}" == ANFS_REPORT_TO ]] || continue
      REPLY="${_CF_FROM[$i]}${_CF_FILES[$i]:+, $(anfs_display "${_CF_FILES[$i]}")}"
      return 0
    done
  fi
  [[ -z "${ANFS_REPORT_TO:-}" ]] || REPLY=env
}

_anfs_report_check_file() {
  local f="$1" d
  if [[ -e "$f" ]]; then
    if [[ -f "$f" && -w "$f" ]]; then _anfs_report_row file ok "$(anfs_display "$f"): writable"
    else _anfs_report_row file fail "$(anfs_display "$f"): not a writable file"
    fi
    return 0
  fi
  d="${f%/*}"
  while [[ -n "$d" && ! -e "$d" ]]; do d="${d%/*}"; done
  [[ -n "$d" ]] || d=/
  if [[ -d "$d" && -w "$d" ]]; then _anfs_report_row file ok "$(anfs_display "$f"): will be created"
  else _anfs_report_row file fail "$(anfs_display "$f"): cannot be created ($(anfs_display "$d") is not writable)"
  fi
}

_anfs_report_check_skill() {
  local agents have status
  _anfs_report_need anfs_skill_load skill.sh
  if ! anfs_skill_require 2>/dev/null; then
    _anfs_report_row skill fail "npx not found, so the skills CLI cannot say (ppm install node)"
    return 0
  fi
  anfs_skill_load -g
  agents=$(anfs_skill_agents 2>/dev/null) || agents=""
  have=$(anfs_skill_installed_agents "$ANFS_REPORT_SKILL") || have=""
  status=$(anfs_skill_status "$ANFS_REPORT_SKILL" "$agents")
  case "$status" in
    ok)      _anfs_report_row skill ok "$ANFS_REPORT_SKILL: installed for ${have:-every agent}" ;;
    partial) _anfs_report_row skill fail "$ANFS_REPORT_SKILL: installed for ${have:-none}, not every agent (psm sync core)" ;;
    *)       _anfs_report_row skill fail "$ANFS_REPORT_SKILL: not installed (psm install core/$ANFS_REPORT_SKILL)" ;;
  esac
}

cmd_report_check() {
  local out s from
  _R_ROWS=() _R_FAILED=""
  gitsrc_collect
  _anfs_report_to_from; from="$REPLY"
  if _anfs_report_dest_try; then
    _anfs_report_row report-to ok "${ANFS_REPORT_TO:-github} ($from)"
  else
    _anfs_report_row report-to fail "$_R_WHY ($from)"
  fi
  if [[ "$_R_TO" == file ]]; then
    _anfs_report_check_file "$_R_FILE"
  elif [[ "$_R_TO" == github ]]; then
    if command -v gh >/dev/null; then
      _anfs_report_row gh ok "$(anfs_display "$(command -v gh)")"
      if out=$(gh auth status 2>&1); then
        _anfs_report_row gh-auth ok "logged in"
      else
        _anfs_report_row gh-auth fail "gh auth status: ${out%%$'\n'*} (gh auth login)"
      fi
    else
      _anfs_report_row gh fail "not on PATH (brew install gh)"
      _anfs_report_row gh-auth fail "gh is not on PATH"
    fi
    for s in core stack; do
      if ! _anfs_report_is_source "$s"; then
        _anfs_report_row "origin $s" fail "$s is not a source (anfs src list)"
      elif _anfs_report_source_repo "$s"; then
        _anfs_report_row "origin $s" ok "$REPLY"
      else
        _anfs_report_row "origin $s" fail "$_R_WHY"
      fi
    done
  fi
  _anfs_report_check_skill
  printf '%s\n' "${_R_ROWS[@]}" | anfs_table "CHECK STATUS DETAIL" "check status detail"
  [[ -z "$_R_FAILED" ]]
}
