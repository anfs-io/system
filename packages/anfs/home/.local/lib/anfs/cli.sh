#!/usr/bin/env bash
# anfs: the command line every tool shares
#
# A tool declares each command once, and everything a person meets comes from that declaration:
# the usage line, help, the check of what was typed, and tab completion. Nothing is written twice,
# so nothing can disagree.
#
#   CLI_TOOL=pcm  CLI_VERSION=0.3.0
#   cli_cmd remove "Down, then delete everything pcm created for it" \
#     --alias rm \
#     --opt "-y --yes: Do not ask" \
#     --opt "-f --force: Also remove what depends on it" \
#     --arg "service..."
#   cli_group repo "The repos skills come from"
#   cli_cmd "repo remove" "Remove a repo's config" --alias rm --arg "dir"
#   cli_standard                                    completion and help, the same in every tool
#   cli_dispatch "$@"
#
# DECLARING
#   cli_cmd <name> "<summary>" [--alias <name>]... [--opt "<spec>"]... [--arg "<spec>"]... [--passthrough]
#   cli_group <name> "<summary>"       a command that only holds sub-commands
#     [--default <sub>]                options with no sub-command go to <name> <sub>
#                                      (`anfs report --title x` is `anfs report new --title x`)
#   cli_section "<title>"              the top-level commands declared after it are listed under
#                                      <title> in help, after the others (anfs: Tools)
#
#   <name> may be two words; its function is cmd_<name> with the space (and any dash) as _.
#   --opt "-y --yes: Do not ask"       a flag: short form, long form, what help says. Either
#                                      form may be left out.
#   --opt "--to SPEC: The wsm space"   a word after the names: the option takes a value, and the
#                                      word is its kind.
#   --arg "service..."  "[snapshot]"   positional arguments: [..] is optional, ... is one or more.
#                                      The word is its kind.
#   --passthrough                      options the command does not declare are left for it, in
#                                      place among its arguments (pcm ps: flags go on to podman).
#
#   A kind is what completion needs. A tool with a function complete_<kind> is asked for
#   candidates (one per line, optionally <TAB>description); `dir` and `file` complete paths; any
#   other kind completes nothing. For an argument that depends on the ones before it (a machine's
#   snapshots), the function finds those in CLI_COMPLETE_ARGS.
#
# RECEIVING
#   The function gets the positional arguments as "$@" and the options in CLI_OPT, keyed by the
#   long name without its dashes (the short one when there is no long):
#
#     cmd_remove() { ${CLI_OPT[yes]:-false} || anfs_confirm ...; for svc in "$@"; ... }
#
#   A flag that was given is `true`. A value option holds its value; given twice, both, one per
#   line. Options may come anywhere after the command, up to a `--`. Before the function runs the
#   line has been checked: an unknown option, a missing value, too few or too many arguments are
#   refused in the same words by every tool, with exit 64. A command that runs another does it
#   with cli_call <command> <args...>, which gives the other its own options and restores these.
#
# EVERY TOOL ALSO TAKES
#   -d/--debug, --trace      before the command (log.sh)
#   --json                   anywhere on the line up to a `--` (table.sh)
#   -y/--yes                 after any command: anfs_confirm does not ask. A command that asks
#                            declares it too, to say in its help what it skips
#   -i/--interactive         after any command: ask for each positional argument, then each value
#                            option, not given (CLI_OPT[interactive]). Needs a terminal (else 77);
#                            with -y it is a usage error. cli_call does not pass it on by itself
#   --version, -h/--help     and `<command> --help`, `help <command>`
#   __complete <words...>    what tab completion asks; see cmd_completion
#
# A cmd_ function nothing declared still runs: that is how a tool keeps plumbing (`psm path`,
# `pcm __compose`) out of its help; in a group, a sub-command named __<name> (`anfs report
# __sink`: cmd_report___sink). Only cmd_ functions run, so a tool's internals are never
# reachable from its command line by accident.
#
# Summaries may span lines; help indents the rest under the first. A tool may define
# cli_help_epilogue to print more after the command list.
#
# Like everything in lib/anfs/ but bash.sh: functions and variables only, no tool's code, written
# for the bash floor (5.2). The tool sources bash.sh before this.

CLI_TOOL="${CLI_TOOL:-}"
CLI_VERSION="${CLI_VERSION:-}"
# Every command, in the order declared: its name and its summary
CLI_NAMES=() CLI_SUMMARIES=()
# name -> cmd | group
declare -gA CLI_KIND=()
# "alias" or "parent alias" -> the command's full name; and name -> its aliases, space-separated
declare -gA CLI_ALIAS_TO=() CLI_ALIAS_LIST=()
# name -> its options and arguments, one per line (options: short, long, kind, help)
declare -gA CLI_OPTSPEC=() CLI_ARGSPEC=() CLI_PASS=()
# What the running command was given
declare -gA CLI_OPT=()
CLI_POS=()
# Exit status for an unknown command or a misused one: 64, EX_USAGE
CLI_EX_USAGE="${CLI_EX_USAGE:-64}"
# "This needs a person at a terminal": a confirm with no terminal and no -y, sudo that cannot run
# unattended. `anfs rpc` reports it as needs: terminal.
CLI_EX_TERMINAL=77
# The command cli_dispatch is running, for cli_usage_err
CLI_COMMAND=""
# Top-level name -> the help section it is listed under (cli_section); the sections in order
declare -gA CLI_SECTION=()
# group -> the sub-command its options go to when none is named (cli_group --default)
declare -gA CLI_GROUP_DEFAULT=()
CLI_SECTIONS=() _CLI_CUR_SECTION=""
_CLI_US=$'\x1f'

# --- Declaring ----------------------------------------------------------------------------

cli_cmd() {
  local name="$1" summary="${2:-}" parent="" a tok left short long kind
  shift
  [[ $# -eq 0 ]] || shift
  [[ "$name" != *" "* ]] || parent="${name% *}"
  CLI_KIND[$name]=cmd CLI_OPTSPEC[$name]="" CLI_ARGSPEC[$name]=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --alias)
        a="${2:?cli_cmd $name: --alias needs a name}"
        CLI_ALIAS_TO[${parent:+$parent }$a]="$name"
        CLI_ALIAS_LIST[$name]="${CLI_ALIAS_LIST[$name]:+${CLI_ALIAS_LIST[$name]} }$a"
        shift 2
        ;;
      --opt)
        left="${2%%: *}" short="" long="" kind=""
        for tok in $left; do
          case "$tok" in --*) long="$tok" ;; -*) short="$tok" ;; *) kind="$tok" ;; esac
        done
        a=""
        [[ "$2" != *": "* ]] || a="${2#*: }"
        CLI_OPTSPEC[$name]+="$short$_CLI_US$long$_CLI_US$kind$_CLI_US$a"$'\n'
        shift 2
        ;;
      --arg) CLI_ARGSPEC[$name]+="$2"$'\n'; shift 2 ;;
      --passthrough) CLI_PASS[$name]=1; shift ;;
      *) echo "$CLI_TOOL: cli_cmd $name: unknown declaration '$1'" >&2; return 1 ;;
    esac
  done
  CLI_NAMES+=("$name") CLI_SUMMARIES+=("$summary")
  [[ -z "$_CLI_CUR_SECTION" || -n "$parent" ]] || CLI_SECTION[$name]="$_CLI_CUR_SECTION"
}

cli_group() {
  CLI_KIND[$1]=group
  [[ "${3:-}" != --default ]] || CLI_GROUP_DEFAULT[$1]="${4:?cli_group $1: --default needs a sub-command}"
  CLI_NAMES+=("$1") CLI_SUMMARIES+=("${2:-}")
  [[ -z "$_CLI_CUR_SECTION" ]] || CLI_SECTION[$1]="$_CLI_CUR_SECTION"
}

cli_section() {
  _CLI_CUR_SECTION="$1"
  CLI_SECTIONS+=("$1")
}

# completion and help: the same two lines in every tool, declared last
cli_standard() {
  cli_cmd completion "Output shell completion code" --arg "[shell]"
  cli_cmd help "Show this help, or a command's" --arg "[command...]"
}

# The command an alias stands for, or the name itself
cli_resolve() {
  printf '%s\n' "${CLI_ALIAS_TO[$1]:-$1}"
}

# --- What a declaration says ---------------------------------------------------------------

# The canonical sub-commands of a group, in REPLY, separated by |
_cli_children() {
  local n out=""
  for n in "${CLI_NAMES[@]}"; do
    [[ "$n" == "$1 "* ]] && out+="${out:+|}${n#"$1 "}"
  done
  REPLY="$out"
}

# What follows a command's name on its usage line, in REPLY: [-y] [--to SPEC] <service>...
_cli_synopsis() {
  local name="$1" out="" short long kind help spec word
  while IFS="$_CLI_US" read -r short long kind help; do
    [[ -n "$short$long" ]] || continue
    out+="${out:+ }[${short:-$long}${kind:+ $kind}]"
  done <<< "${CLI_OPTSPEC[$name]:-}"
  [[ -z "${CLI_PASS[$name]:-}" ]] || out+="${out:+ }[options]"
  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    if [[ "$spec" == "["*"]" ]]; then
      out+="${out:+ }$spec"
    else
      word="${spec%...}"
      out+="${out:+ }<$word>"
      [[ "$spec" != *... ]] || out+="..."
    fi
  done <<< "${CLI_ARGSPEC[$name]:-}"
  REPLY="$out"
}

# The usage line of <command> (default: the one running), without the tool's name
cli_usage_line() {
  local name="${1:-$CLI_COMMAND}"
  case "${CLI_KIND[$name]:-}" in
    cmd)   _cli_synopsis "$name"; printf '%s\n' "$name${REPLY:+ $REPLY}" ;;
    group) _cli_children "$name"; printf '%s\n' "$name <$REPLY>" ;;
    *)     printf '%s\n' "$name" ;;
  esac
}

# Every usage error reads the same and exits $CLI_EX_USAGE (64):  <tool>: usage: <tool> <how>
# cli_usage "<tool> <how>"     for a command that words its own
# cli_usage_err [message]      the running command's usage line, after the message
cli_usage() {
  echo "$CLI_TOOL: usage: $*" >&2
  exit "$CLI_EX_USAGE"
}
cli_usage_err() {
  [[ $# -eq 0 ]] || echo "$CLI_TOOL: $*" >&2
  cli_usage "$CLI_TOOL $(cli_usage_line)"
}

# True when <name> is a command: a cmd_ function exists for it
cli_has() {
  [[ "$1" =~ ^[a-z_][a-z0-9_\ -]*$ ]] && declare -F "cmd_${1//[ -]/_}" >/dev/null
}

# --- Reading the line ----------------------------------------------------------------------

# The options every tool takes. Sets ANFS_DEBUG / ANFS_TRACE (exported, so a tool run by this one
# follows) and ANFS_JSON (not exported: a tool run by this one decides for itself), and leaves
# the remaining arguments in CLI_ARGS.
cli_globals() {
  local arg rest=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--debug) export ANFS_DEBUG=true ;;
      --trace)    export ANFS_TRACE=true ;;
      *) break ;;
    esac
    shift
  done
  CLI_ARGS=()
  for arg in "$@"; do
    if $rest; then CLI_ARGS+=("$arg")
    elif [[ "$arg" == -- ]]; then rest=true; CLI_ARGS+=("$arg")
    elif [[ "$arg" == --json ]]; then ANFS_JSON=true
    else CLI_ARGS+=("$arg")
    fi
  done
}

# Find the option <word> (-y or --yes) of <command>: its key, kind and names in _O_*. Returns 1
# when the command has none by that name.
_cli_opt() {
  local short long kind help
  while IFS="$_CLI_US" read -r short long kind help; do
    [[ -n "$short$long" ]] || continue
    if [[ "$2" == "$short" || "$2" == "$long" ]]; then
      _O_KIND="$kind" _O_KEY="${long#--}"
      [[ -n "$_O_KEY" ]] || _O_KEY="${short#-}"
      return 0
    fi
  done <<< "${CLI_OPTSPEC[$1]:-}"
  # Every command takes -y: one with nothing to ask ignores it, so a caller (a script, the
  # toolkit API's yes) never has to know which commands ask. A declaration only says what it skips.
  if [[ "$2" == -y || "$2" == --yes ]]; then
    _O_KIND="" _O_KEY=yes
    return 0
  fi
  # And -i, to be asked for what is not given (_cli_ask_missing)
  if [[ "$2" == -i || "$2" == --interactive ]]; then
    _O_KIND="" _O_KEY=interactive
    return 0
  fi
  return 1
}

_cli_opt_set() {
  if [[ -z "$_O_KIND" ]]; then
    CLI_OPT[$_O_KEY]=true
  else
    CLI_OPT[$_O_KEY]="${CLI_OPT[$_O_KEY]:+${CLI_OPT[$_O_KEY]}$'\n'}$1"
  fi
}

# Check a command's line against its declaration, into CLI_OPT and CLI_POS
_cli_parse() {
  local name="$1" arg rest=false pass="${CLI_PASS[$1]:-}" i c spec min=0 max=0 many=false
  shift
  CLI_OPT=() CLI_POS=()
  while [[ $# -gt 0 ]]; do
    arg="$1"
    shift
    if $rest || [[ "$arg" != -?* ]]; then
      CLI_POS+=("$arg")
      continue
    fi
    case "$arg" in
      --)
        rest=true
        [[ -z "$pass" ]] || CLI_POS+=("$arg")
        ;;
      --*=*)
        if _cli_opt "$name" "${arg%%=*}" && [[ -n "$_O_KIND" ]]; then
          _cli_opt_set "${arg#*=}"
        elif [[ -n "$pass" ]]; then CLI_POS+=("$arg")
        else cli_usage_err "unknown option '${arg%%=*}'"
        fi
        ;;
      --*|-?)
        if _cli_opt "$name" "$arg"; then
          if [[ -n "$_O_KIND" ]]; then
            [[ $# -gt 0 ]] || cli_usage_err "$arg needs a value ($_O_KIND)"
            _cli_opt_set "$1"
            shift
          else
            _cli_opt_set
          fi
        elif [[ "$arg" == -h || "$arg" == --help ]]; then
          cli_help_command "$name"
          exit 0
        elif [[ -n "$pass" ]]; then CLI_POS+=("$arg")
        else cli_usage_err "unknown option '$arg'"
        fi
        ;;
      *)
        # Short flags run together, -cfr; the last may take a value
        if [[ -n "$pass" ]] && ! _cli_opt "$name" "-${arg:1:1}"; then
          CLI_POS+=("$arg")
          continue
        fi
        for (( i = 1; i < ${#arg}; i++ )); do
          c="-${arg:i:1}"
          _cli_opt "$name" "$c" || cli_usage_err "unknown option '$c'"
          if [[ -n "$_O_KIND" ]]; then
            if (( i < ${#arg} - 1 )); then
              _cli_opt_set "${arg:i+1}"
            else
              [[ $# -gt 0 ]] || cli_usage_err "$c needs a value ($_O_KIND)"
              _cli_opt_set "$1"
              shift
            fi
            break
          fi
          _cli_opt_set
        done
        ;;
    esac
  done

  if ${CLI_OPT[interactive]:-false}; then
    ! ${CLI_OPT[yes]:-false} || cli_usage_err "-i and -y: one asks, the other does not"
    if ! _cli_terminal; then
      echo "$CLI_TOOL: -i needs a terminal" >&2
      exit "$CLI_EX_TERMINAL"
    fi
    _cli_ask_missing "$name"
  fi

  while IFS= read -r spec; do
    [[ -n "$spec" ]] || continue
    [[ "$spec" == "["* ]] || min=$((min + 1))
    max=$((max + 1))
    [[ "$spec" != *"..."* ]] || many=true
  done <<< "${CLI_ARGSPEC[$name]:-}"
  [[ -z "$pass" ]] || many=true
  (( ${#CLI_POS[@]} >= min )) || cli_usage_err
  $many || (( ${#CLI_POS[@]} <= max )) || cli_usage_err "too many arguments"
}

# True when stdin is a terminal. ANFS_TEST_TERMINAL=1 makes it one for -i, so a test can pipe
# the answers in.
_cli_terminal() {
  [[ -t 0 || "${ANFS_TEST_TERMINAL:-}" == 1 ]]
}

# One question of -i, on stderr; the answer in REPLY. The kind's candidates are listed first (up
# to 20); a lone one is the default. End of input is "nothing done", exit 1.
_cli_ask_line() {
  local kind="$1" question="$2" line default="" i=0
  local -a cands=()
  while IFS= read -r line; do
    [[ -z "$line" ]] || cands+=("$line")
  done < <(_cli_candidates "$kind" 2>/dev/null)
  [[ "${cands[0]:-}" != :* ]] || cands=()
  for line in ${cands[@]+"${cands[@]}"}; do
    if (( ++i > 20 )); then
      echo "  ..." >&2
      break
    fi
    printf '  %s\n' "${line/$'\t'/  }" >&2
  done
  [[ ${#cands[@]} -ne 1 ]] || default="${cands[0]%%$'\t'*}"
  printf '%s%s: ' "$question" "${default:+ [$default]}" >&2
  if ! IFS= read -r REPLY; then
    printf '\n%s: nothing done\n' "$CLI_TOOL" >&2
    exit 1
  fi
  [[ -n "$REPLY" ]] || REPLY="$default"
}

# -i: ask for each positional argument not given, in order, then each value option not given (a
# flag is not asked), into CLI_POS and CLI_OPT as if typed. Enter leaves an optional one out (and
# so every argument after it); a required argument is asked again. A ... argument is asked once
# and the answer split on spaces.
_cli_ask_missing() {
  local name="$1" spec word q n short long kind help key
  local -a specs=() opts=() words=()
  while IFS= read -r spec; do
    [[ -z "$spec" ]] || specs+=("$spec")
  done <<< "${CLI_ARGSPEC[$name]:-}"
  for (( n = ${#CLI_POS[@]}; n < ${#specs[@]}; n++ )); do
    spec="${specs[$n]}"
    word="${spec#[}" word="${word%]}" word="${word%...}"
    q="$spec"
    [[ "$spec" == "["* ]] || { q="<$word>"; [[ "$spec" != *... ]] || q+="..."; }
    CLI_COMPLETE_ARGS=(${CLI_POS[@]+"${CLI_POS[@]}"})
    while _cli_ask_line "$word" "$q"; [[ -z "$REPLY" && "$spec" != "["* ]]; do :; done
    [[ -n "$REPLY" ]] || break
    if [[ "$spec" == *... ]]; then
      read -ra words <<< "$REPLY"
      CLI_POS+=("${words[@]}")
      break
    fi
    CLI_POS+=("$REPLY")
  done
  while IFS= read -r spec; do
    [[ -z "$spec" ]] || opts+=("$spec")
  done <<< "${CLI_OPTSPEC[$name]:-}"
  for spec in ${opts[@]+"${opts[@]}"}; do
    IFS="$_CLI_US" read -r short long kind help <<< "$spec"
    [[ -n "$kind" ]] || continue
    key="${long#--}"
    [[ -n "$key" ]] || key="${short#-}"
    [[ -z "${CLI_OPT[$key]+set}" ]] || continue
    _cli_ask_line "${kind,,}" "${help:-${long:-$short}} ($kind)"
    [[ -z "$REPLY" ]] || CLI_OPT[$key]="$REPLY"
  done
}

# Run a declared command from inside the tool, as if typed: `cli_call up --fresh "$id"`. The
# line is checked like any other, and the caller's own options and arguments are put back after.
# This is how one command runs another, and how a test runs one.
cli_call() {
  local name="${CLI_ALIAS_TO[$1]:-$1}" saved rc caller="${CLI_COMMAND:-}"
  local -a pos=("${CLI_POS[@]}")
  shift
  saved=$(declare -p CLI_OPT)
  # the running command, while it runs: its own usage line is what cli_usage_err prints
  CLI_COMMAND="$name"
  _cli_parse "$name" "$@"
  "cmd_${name//[ -]/_}" "${CLI_POS[@]}"
  rc=$?
  CLI_COMMAND="$caller"
  eval "${saved/#declare -A/declare -gA}"
  CLI_POS=("${pos[@]}")
  return "$rc"
}

# Find the command the leading words name: its full name in _CLI_NAME, how many words it took
# in _CLI_SHIFT. Returns 1 when the first word is no command, 2 when a group's sub-command is
# missing or unknown (_CLI_NAME is then the group).
_cli_find() {
  local w1="${1:-}" w2="${2:-}"
  _CLI_NAME="" _CLI_SHIFT=0
  [[ -n "$w1" ]] || return 1
  w1="${CLI_ALIAS_TO[$w1]:-$w1}"
  if [[ "${CLI_KIND[$w1]:-}" == group ]]; then
    _CLI_NAME="$w1" _CLI_SHIFT=1
    # an option where the sub-command would be: the group's default takes it (not -h, --help)
    if [[ "$w2" == -?* && "$w2" != -h && "$w2" != --help && -n "${CLI_GROUP_DEFAULT[$w1]:-}" ]]; then
      _CLI_NAME="$w1 ${CLI_GROUP_DEFAULT[$w1]}"
      return 0
    fi
    [[ -n "$w2" && "$w2" != -* ]] || return 2
    w2="${CLI_ALIAS_TO[$w1 $w2]:-$w1 $w2}"
    # a group's plumbing: a cmd_ function nothing declared (anfs report __sink)
    [[ -n "${CLI_KIND[$w2]:-}" ]] || { [[ "${w2#* }" == __* ]] && cli_has "$w2"; } || return 2
    _CLI_NAME="$w2" _CLI_SHIFT=2
    return 0
  fi
  [[ -n "${CLI_KIND[$w1]:-}" ]] || cli_has "$w1" || return 1
  _CLI_NAME="$w1" _CLI_SHIFT=1
}

# Run the command the line names; help when there is none
cli_dispatch() {
  local rc=0
  cli_globals "$@"
  set -- "${CLI_ARGS[@]}"
  if [[ "${1:-}" == __complete ]]; then
    shift
    _cli_complete "$@" 2>/dev/null || true
    return 0
  fi
  if [[ "${1:-}" == --version ]]; then
    [[ -n "$CLI_VERSION" ]] || cli_package_version
    printf '%s %s\n' "$CLI_TOOL" "${CLI_VERSION:-unknown}"
    return 0
  fi
  ! declare -F anfs_log_start >/dev/null || anfs_log_start "$@"
  case "${1:-help}" in
    help|-h|--help)
      [[ $# -eq 0 ]] || shift
      cmd_help "$@"
      return 0
      ;;
  esac

  _cli_find "$@" || rc=$?
  case "$rc" in
    1)
      echo "$CLI_TOOL: unknown command '$1'" >&2
      cli_help >&2
      return "$CLI_EX_USAGE"
      ;;
    2)
      # A group on its own shows what it holds; with a word that is none of them, it is an error
      if [[ $# -lt 2 || "$2" == -h || "$2" == --help ]]; then
        cli_help_command "$_CLI_NAME"
        return 0
      fi
      echo "$CLI_TOOL: unknown command '$1 $2'" >&2
      cli_help_command "$_CLI_NAME" >&2
      return "$CLI_EX_USAGE"
      ;;
  esac
  shift "$_CLI_SHIFT"
  CLI_COMMAND="$_CLI_NAME"
  if [[ "${CLI_KIND[$CLI_COMMAND]:-}" == cmd ]]; then
    _cli_parse "$CLI_COMMAND" "$@"
    # A tool's own step between the line being read and the command running (ppm turns the
    # options into the variables its helpers read)
    ! declare -F cli_before_command >/dev/null || cli_before_command
    "cmd_${CLI_COMMAND//[ -]/_}" "${CLI_POS[@]}"
  else
    "cmd_${CLI_COMMAND//[ -]/_}" "$@"
  fi
}

# Ask before something that cannot be undone, the same way in every tool. True at once with
# -y/--yes (CLI_OPT[yes]). Without a terminal there is nobody to ask: it says what would have
# happened and to pass -y, and exits 77 (CLI_EX_TERMINAL). Anything but a y exits 1, with
# "nothing done".
# Usage: anfs_confirm "<what this does>" "<the question>"
anfs_confirm() {
  local answer
  ! ${CLI_OPT[yes]:-false} || return 0
  if [[ ! -t 0 ]]; then
    echo "$CLI_TOOL: $1; pass -y to confirm without a terminal" >&2
    exit "$CLI_EX_TERMINAL"
  fi
  read -r -p "$2 [y/N] " answer
  [[ "$answer" == [yY]* ]] && return 0
  echo "$CLI_TOOL: nothing done" >&2
  exit 1
}

# Ask for a line of text; the answer is left in REPLY. Enter takes the default, and with
# -y/--yes a default is taken unasked. Without a terminal there is nobody to ask: that is
# refused as a usage error naming <what>, the option that gives the answer.
# Usage: anfs_ask "<what>" "<the question>" [default]
anfs_ask() {
  local what="$1" question="$2" default="${3:-}"
  REPLY="$default"
  if ${CLI_OPT[yes]:-false} && [[ -n "$default" ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    echo "$CLI_TOOL: $question needs an answer; pass $what" >&2
    exit "$CLI_EX_USAGE"
  fi
  read -r -p "$question${default:+ [$default]}: " REPLY
  [[ -n "$REPLY" ]] || REPLY="$default"
  [[ -n "$REPLY" ]] && return 0
  echo "$CLI_TOOL: nothing done" >&2
  exit 1
}

# Ask for one of several; the choice (its first word, before any ": description") is left in
# REPLY. The first option is the default: Enter takes it, and so does -y/--yes. Without a
# terminal and without -y it is refused as a usage error naming <what>, like anfs_ask.
# Usage: anfs_choose "<what>" "<the question>" "<option>[: <description>]"...
anfs_choose() {
  local what="$1" question="$2" answer i
  shift 2
  REPLY="${1%%: *}"
  ! ${CLI_OPT[yes]:-false} || return 0
  if [[ ! -t 0 ]]; then
    echo "$CLI_TOOL: $question needs an answer; pass $what" >&2
    exit "$CLI_EX_USAGE"
  fi
  echo "$question" >&2
  for ((i = 1; i <= $#; i++)); do
    printf '  %d) %s\n' "$i" "${!i}" >&2
  done
  read -r -p "Choice [1]: " answer
  [[ -n "$answer" ]] || answer=1
  if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= $# )); then
    REPLY="${!answer%%: *}"
    return 0
  fi
  echo "$CLI_TOOL: '$answer' is not one of 1-$#; nothing done" >&2
  exit 1
}

# The tool's version, into CLI_VERSION, when the tool did not set one: its package's, from the
# package.yml three directories above the script (<package>/home/.local/bin/<tool>). That file is
# what the commit hook bumps, so there is no second number to keep in step.
cli_package_version() {
  local path="${BASH_SOURCE[-1]}" dir line
  while [[ -L "$path" ]]; do
    dir=$(cd -P -- "$(dirname -- "$path")" && pwd)
    path=$(readlink -- "$path")
    [[ "$path" == /* ]] || path="$dir/$path"
  done
  dir=$(cd -P -- "$(dirname -- "$path")/../../.." 2>/dev/null && pwd) || return 0
  [[ -f "$dir/package.yml" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == version:* ]] || continue
    line="${line#version:}"
    CLI_VERSION="${line//[ \"\']/}"
    return 0
  done < "$dir/package.yml"
}

# --- Help ----------------------------------------------------------------------------------

# One row of a command list: its usage in a column, then its summary, wrapped lines under it
_cli_help_row() {
  local usage="$1" summary="$2" width="$3" first rest line
  first="${summary%%$'\n'*}"
  if (( ${#usage} > width )); then
    printf '  %s\n  %-*s  %s\n' "$usage" "$width" "" "$first"
  else
    printf '  %-*s  %s\n' "$width" "$usage" "$first"
  fi
  if [[ "$summary" == *$'\n'* ]]; then
    rest="${summary#*$'\n'}"
    while IFS= read -r line; do
      printf '  %-*s  %s\n' "$width" "" "$line"
    done <<< "$rest"
  fi
}

# How a command reads in a list: its name, its aliases, what it takes. <prefix> is the group's
# name and a space when the list is a group's.
_cli_help_usage() {
  local name="$1" prefix="${2:-}" leaf aliases
  leaf="${name#"$prefix"}"
  aliases="${CLI_ALIAS_LIST[$name]:-}"
  case "${CLI_KIND[$name]:-}" in
    cmd)   _cli_synopsis "$name"; REPLY="$leaf${aliases:+, ${aliases// /, }}${REPLY:+ $REPLY}" ;;
    group) _cli_children "$name"; REPLY="$leaf <$REPLY>" ;;
    *)     REPLY="" ;;
  esac
}

# The commands under <prefix> ("" for the top level): usage lines in one column, then summaries.
# At the top level, those of <section> only ("": the ones in none).
cli_help_commands() {
  local prefix="${1:+$1 }" section="${2:-}" i name width=0
  local -a usages=() summaries=()
  for i in "${!CLI_NAMES[@]}"; do
    name="${CLI_NAMES[$i]}"
    if [[ -n "$prefix" ]]; then
      [[ "$name" == "$prefix"* ]] || continue
    else
      [[ "$name" != *" "* && "${CLI_SECTION[$name]:-}" == "$section" ]] || continue
    fi
    _cli_help_usage "$name" "$prefix"
    usages+=("$REPLY") summaries+=("${CLI_SUMMARIES[$i]}")
    (( ${#REPLY} <= width )) || width=${#REPLY}
  done
  (( width <= 34 )) || width=34
  for i in "${!usages[@]}"; do
    _cli_help_row "${usages[$i]}" "${summaries[$i]}" "$width"
  done
}

cli_help() {
  echo "Usage: $CLI_TOOL <command> [args]"
  echo ""
  echo "Commands:"
  cli_help_commands
  local s out
  for s in ${CLI_SECTIONS[@]+"${CLI_SECTIONS[@]}"}; do
    out=$(cli_help_commands "" "$s")
    [[ -z "$out" ]] || printf '\n%s:\n%s\n' "$s" "$out"
  done
  echo ""
  echo "Options, before the command:"
  echo "  -d, --debug        Show debug output (always written to the log: anfs log)"
  echo "  --trace            Trace every command the tool runs"
  echo "  --json             Lists as JSON (anywhere on the line)"
  echo "  -y, --yes          Do not ask (after any command)"
  echo "  -i, --interactive  Ask for what is not given (after any command)"
  echo "  --version          Print the version"
  echo "  -h, --help         This help; after a command, that command's"
  if declare -F cli_help_epilogue >/dev/null; then
    echo ""
    cli_help_epilogue
  fi
}

# One command's help, or a group's: how it is used, what it does, its options or sub-commands
cli_help_command() {
  local name="$1" i short long kind help width=0 label
  local -a labels=() helps=()
  echo "Usage: $CLI_TOOL $(cli_usage_line "$name")"
  for i in "${!CLI_NAMES[@]}"; do
    [[ "${CLI_NAMES[$i]}" == "$name" ]] || continue
    [[ -z "${CLI_SUMMARIES[$i]}" ]] || printf '\n%s\n' "${CLI_SUMMARIES[$i]}"
  done
  [[ -z "${CLI_ALIAS_LIST[$name]:-}" ]] || printf '\nAlias: %s\n' "${CLI_ALIAS_LIST[$name]// /, }"
  if [[ "${CLI_KIND[$name]:-}" == group ]]; then
    printf '\nCommands:\n'
    cli_help_commands "$name"
    [[ -z "${CLI_GROUP_DEFAULT[$name]:-}" ]] ||
      printf '\nOptions with no command go to %s %s.\n' "$name" "${CLI_GROUP_DEFAULT[$name]}"
    return 0
  fi
  while IFS="$_CLI_US" read -r short long kind help; do
    [[ -n "$short$long" ]] || continue
    label="${short}${short:+${long:+, }}${long}${kind:+ $kind}"
    labels+=("$label") helps+=("$help")
    (( ${#label} <= width )) || width=${#label}
  done <<< "${CLI_OPTSPEC[$name]:-}"
  [[ ${#labels[@]} -eq 0 ]] || printf '\nOptions:\n'
  for i in "${!labels[@]}"; do
    printf '  %-*s  %s\n' "$width" "${labels[$i]}" "${helps[$i]}"
  done
}

cmd_help() {
  local rc=0
  if [[ $# -eq 0 ]]; then
    cli_help
    return 0
  fi
  _cli_find "$@" || rc=$?
  if [[ -z "$_CLI_NAME" || ( $rc -eq 2 && $# -ge 2 ) ]]; then
    echo "$CLI_TOOL: unknown command '$*'" >&2
    return "$CLI_EX_USAGE"
  fi
  cli_help_command "$_CLI_NAME"
}

# --- Completion ----------------------------------------------------------------------------
#
# Nothing about a tool's commands is written into a completion script, so none can go stale: the
# shell asks the tool on every tab press, `<tool> __complete <words...>`, the last word being the
# one typed so far. The answer is candidates, one per line, `value<TAB>description`; or the one
# line `:files` or `:dirs` to hand over to path completion.

# The candidates for one kind
_cli_candidates() {
  case "$1" in
    "") ;;
    dir)  echo ":dirs" ;;
    file|path) echo ":files" ;;
    *) ! declare -F "complete_${1//-/_}" >/dev/null || "complete_${1//-/_}" ;;
  esac
}

# The names to offer under <prefix> for the word <cur>: every command once, its aliases in its
# description. An alias is offered itself only when what is typed can be nothing else.
_cli_complete_names() {
  local prefix="${1:+$1 }" cur="$2" i name leaf summary aliases a any=false
  for i in "${!CLI_NAMES[@]}"; do
    name="${CLI_NAMES[$i]}"
    if [[ -n "$prefix" ]]; then
      [[ "$name" == "$prefix"* ]] || continue
    else
      [[ "$name" != *" "* ]] || continue
    fi
    leaf="${name#"$prefix"}"
    summary="${CLI_SUMMARIES[$i]%%$'\n'*}"
    aliases="${CLI_ALIAS_LIST[$name]:-}"
    [[ "$leaf" != "$cur"* ]] || any=true
    printf '%s\t%s%s\n' "$leaf" "$summary" "${aliases:+ (alias: ${aliases// /, })}"
  done
  $any && return 0
  for a in "${!CLI_ALIAS_TO[@]}"; do
    if [[ -n "$prefix" ]]; then
      [[ "$a" == "$prefix"* ]] || continue
    else
      [[ "$a" != *" "* ]] || continue
    fi
    leaf="${a#"$prefix"}"
    [[ -n "$cur" && "$leaf" == "$cur"* ]] || continue
    printf '%s\talias of %s\n' "$leaf" "${CLI_ALIAS_TO[$a]#"$prefix"}"
  done
}

_cli_complete() {
  local cur="" rc=0 name short long kind help spec n=0 i want=""
  local -a words=() specs=()
  CLI_COMPLETE_ARGS=()
  [[ $# -eq 0 ]] || { cur="${*: -1}"; words=("${@:1:$#-1}"); }
  # The options before the command are not the command's
  while [[ ${#words[@]} -gt 0 ]]; do
    case "${words[0]}" in -d|--debug|--trace|--json) words=("${words[@]:1}") ;; *) break ;; esac
  done

  if [[ ${#words[@]} -eq 0 ]]; then
    if [[ "$cur" == -* ]]; then
      printf '%s\t%s\n' -d "Show debug output" --debug "Show debug output" --trace "Trace every command" \
        --json "Lists as JSON" --help "Show help"
      printf '%s\t%s\n' --version "Print the version"
    else
      _cli_complete_names "" "$cur"
    fi
    return 0
  fi

  _cli_find "${words[@]}" || rc=$?
  [[ $rc -ne 1 ]] || return 0
  name="$_CLI_NAME"
  words=("${words[@]:$_CLI_SHIFT}")
  if [[ "${CLI_KIND[$name]:-}" == group ]]; then
    # an option typed where the sub-command goes: the default's (cli_group --default)
    if [[ ${#words[@]} -eq 0 && "$cur" == -* && -n "${CLI_GROUP_DEFAULT[$name]:-}" ]]; then
      name="$name ${CLI_GROUP_DEFAULT[$name]}"
    else
      [[ ${#words[@]} -gt 0 ]] || _cli_complete_names "$name" "$cur"
      return 0
    fi
  fi
  if [[ "$name" == help ]]; then
    _cli_complete_names "${words[*]}" "$cur"
    return 0
  fi
  [[ "${CLI_KIND[$name]:-}" == cmd ]] || return 0

  # An option's name, only once a - is typed
  if [[ "$cur" == -* ]]; then
    while IFS="$_CLI_US" read -r short long kind help; do
      [[ -z "$long" ]] || printf '%s\t%s\n' "$long" "$help"
      [[ -z "$short" ]] || printf '%s\t%s\n' "$short" "$help"
    done <<< "${CLI_OPTSPEC[$name]:-}"
    return 0
  fi
  # An option's value
  if [[ ${#words[@]} -gt 0 ]] && _cli_opt "$name" "${words[-1]}" && [[ -n "$_O_KIND" ]]; then
    _cli_candidates "${_O_KIND,,}"
    return 0
  fi
  # An argument: which one, counting the words that are neither options nor their values
  for (( i = 0; i < ${#words[@]}; i++ )); do
    if [[ "${words[$i]}" == -?* ]]; then
      ! { _cli_opt "$name" "${words[$i]}" && [[ -n "$_O_KIND" ]]; } || i=$((i + 1))
      continue
    fi
    n=$((n + 1))
    CLI_COMPLETE_ARGS+=("${words[$i]}")
  done
  while IFS= read -r spec; do
    [[ -z "$spec" ]] || specs+=("$spec")
  done <<< "${CLI_ARGSPEC[$name]:-}"
  [[ ${#specs[@]} -gt 0 ]] || return 0
  if (( n < ${#specs[@]} )); then want="${specs[$n]}"
  elif [[ "${specs[-1]}" == *"..."* ]]; then want="${specs[-1]}"
  fi
  want="${want#[}" want="${want%]}" want="${want%...}"
  _cli_candidates "$want"
}

# `<tool> completion [zsh|bash]`: a few lines that ask the tool. They hold nothing about its
# commands, so a copy cached by the shell (zcomp) does not go out of date.
cmd_completion() {
  case "${1:-zsh}" in
    zsh)
      cat <<COMPLETION
#compdef $CLI_TOOL

# $CLI_TOOL answers for itself on every tab press ($CLI_TOOL __complete, lib/anfs/cli.sh)
_$CLI_TOOL() {
  local -a lines vals descs
  local line
  lines=("\${(@f)\$(command $CLI_TOOL __complete "\${(@)words[2,CURRENT]}" 2>/dev/null)}")
  case "\${lines[1]:-}" in
    :files) _files; return ;;
    :dirs)  _files -/; return ;;
  esac
  for line in "\${lines[@]}"; do
    [[ -n "\$line" ]] || continue
    vals+=("\${line%%\$'\\t'*}")
    if [[ "\$line" == *\$'\\t'* ]]; then
      descs+=("\${line%%\$'\\t'*}  -- \${line#*\$'\\t'}")
    else
      descs+=("\${line%%\$'\\t'*}")
    fi
  done
  (( \${#vals} )) || return 1
  if [[ "\${(j::)descs}" == *" -- "* ]]; then
    compadd -l -d descs -a vals
  else
    compadd -a vals
  fi
}

if [[ "\$funcstack[1]" == _$CLI_TOOL ]]; then
  _$CLI_TOOL "\$@"
else
  compdef _$CLI_TOOL $CLI_TOOL
fi
COMPLETION
      ;;
    bash)
      cat <<COMPLETION
# $CLI_TOOL answers for itself on every tab press ($CLI_TOOL __complete, lib/anfs/cli.sh)
_${CLI_TOOL}_complete() {
  local cur="\${COMP_WORDS[COMP_CWORD]}" out
  out=\$(command $CLI_TOOL __complete "\${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)
  case "\$out" in
    :files*) COMPREPLY=(\$(compgen -f -- "\$cur")); return ;;
    :dirs*)  COMPREPLY=(\$(compgen -d -- "\$cur")); return ;;
  esac
  local IFS=\$'\\n'
  COMPREPLY=(\$(compgen -W "\$(printf '%s\\n' "\$out" | cut -f1)" -- "\$cur"))
}
complete -F _${CLI_TOOL}_complete $CLI_TOOL
COMPLETION
      ;;
    *) cli_usage "$CLI_TOOL completion <zsh|bash>" ;;
  esac
}
