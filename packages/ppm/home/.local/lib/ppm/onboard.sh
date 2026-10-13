#!/usr/bin/env bash
# Onboarding steps a package contributes to `anfs onboard` (lib/anfs/onboard.sh is the runner)
#
# A package joins the walk by declaring it in package.yml:
#
#   onboard:
#     offer: "GitHub from the command line, and your git identity"   shown while NOT installed
#     steps:
#       - name: github                     its functions are onboard_github_detect, onboard_github
#         summary: Sign in to GitHub
#         after: [key, pm]                 steps it follows; names no installed package has are
#         before: [repo]                   ignored, so these never require another package
#     options:
#       - "--name NAME: Your name, for git"       the spec cli_cmd --opt takes (lib/anfs/cli.sh)
#
# and defining, in its install.sh, for each step (a dash in the name is an underscore here):
#
#   onboard_<step>_detect   true when there is nothing to do. No side effects: it is all that
#                           `anfs onboard --check` runs. It says what it found (onboard_detail)
#                           and records what later steps need (onboard_set), done or not.
#   onboard_<step>          detect, then do what is missing, asking first. True when done.
#
# The offer is read from a package nobody installed; the steps run only for installed packages,
# so onboarding never runs code from a package you did not choose.
#
# Each call is its own ppm process (`ppm __onboard <repo/pkg> <function>`), so what steps share
# goes through the run's facts file, with the functions below. An option the person gave is
# onboard_opt <name> whichever package declared it.
#
#   onboard_get <key> / onboard_set <key> <value>    facts: name, email, pm, vault, pubkey, gh_login, ...
#   onboard_opt <name>                               the value of --<name>, or nothing
#   onboard_detail <text>, onboard_state <state>     this step's row: state is ok|todo by the
#                                                    return value unless set (optional, n/a, skip)
#   onboard_yes                                      true under -y
#   onboard_propose "<Do this>"                      Y/n; yes under -y; no terminal: refused
#   onboard_confirm "<Do this>"                      y/N; never yes without a person answering
#   onboard_ask <opt> "<question>" [default]         -> REPLY: the option, else asked (anfs_ask)
#   onboard_choose <opt> "<question>" <choice>...    -> REPLY: the option, else asked (anfs_choose)
#   onboard_user_repo, onboard_user_repo_url         your own repo's directory, and how it is listed
#   onboard_commit <dir> "<message>"                 commit everything in a repo, when anything changed

onboard_get() {
  [[ -f "${ANFS_ONBOARD_FACTS:-}" ]] || return 0
  awk -v k="$1" 'index($0, k "\t") == 1 { v = substr($0, length(k) + 2) } END { if (v != "") print v }' \
    "$ANFS_ONBOARD_FACTS"
}

onboard_set() {
  [[ -n "${ANFS_ONBOARD_FACTS:-}" ]] || return 0
  printf '%s\t%s\n' "$1" "${2//$'\n'/ }" >> "$ANFS_ONBOARD_FACTS"
}

onboard_opt()    { onboard_get "opt.$1"; }
onboard_detail() { onboard_set _detail "$*"; }
onboard_state()  { onboard_set _state "$1"; }
onboard_yes()    { [[ "${ANFS_ONBOARD_YES:-false}" == true ]]; }

onboard_propose() {
  local answer
  ! onboard_yes || return 0
  [[ -t 0 ]] || anfs_die "$1: pass -y to go ahead without a terminal"
  read -r -p "$1? [Y/n] " answer
  [[ "$answer" != [nN]* ]]
}

onboard_confirm() {
  local answer
  ! onboard_yes && [[ -t 0 ]] || return 1
  read -r -p "$1? [y/N] " answer
  [[ "$answer" == [yY]* ]]
}

onboard_ask() {
  REPLY=$(onboard_opt "$1")
  [[ -z "$REPLY" ]] || return 0
  anfs_ask "--$1" "$2" "${3:-}"
}

# An option that is not one of the choices is a usage error, as it is from the command line
onboard_choose() {
  local opt="$1" question="$2" choice
  shift 2
  REPLY=$(onboard_opt "$opt")
  if [[ -n "$REPLY" ]]; then
    for choice in "$@"; do
      [[ "${choice%%: *}" != "$REPLY" ]] || return 0
    done
    echo "$CLI_TOOL: --$opt is not '$REPLY' (one of:$(printf ' %s' "${@%%: *}"))" >&2
    exit "$CLI_EX_USAGE"
  fi
  anfs_choose "--$opt" "$question" "$@"
}

onboard_user_repo() {
  local dir="$ANFS_SOURCES_HOME/$PPM_USER_REPO_ALIAS"
  [[ -n "$(onboard_user_repo_url)" && -d "$dir" ]] && printf '%s\n' "$dir"
  return 0
}

onboard_user_repo_url() {
  [[ -f "$ANFS_USER_LIST" ]] || return 0
  awk -v a="$PPM_USER_REPO_ALIAS" '$1 !~ /^#/ && NF >= 2 && $NF == a { print $1; exit }' "$ANFS_USER_LIST"
}

onboard_commit() {
  local dir="$1" msg="$2" user name email
  user=$(id -un)
  name=$(onboard_get name) email=$(onboard_get email)
  git -C "$dir" add -A
  ! git -C "$dir" diff --cached --quiet || return 0
  git -C "$dir" -c user.name="${name:-$user}" -c user.email="${email:-$user@$(hostname -s)}" \
    commit -q -m "$msg"
}

# Plumbing, for the runner: run one step function of an installed package's install.sh, in ppm's
# context (so the hook has user_message, os, ppm_fail, ... like any other). Its exit status is
# the function's: 0 done, 1 not done; anything else stops the walk (64: a question no option
# answered).
cmd___onboard() {
  local qualified="${1:-}" fn="${2:-}" dir rc=0
  [[ "$qualified" == */* && "$fn" == onboard_* ]] || cli_usage "ppm __onboard <repo/package> <onboard_function>"
  dir="$ANFS_SOURCES_HOME/${qualified%%/*}/packages/${qualified#*/}"
  [[ -f "$dir/install.sh" ]] || anfs_die "$qualified declares onboard steps but has no install.sh"

  PPM_CURRENT_PACKAGE="$qualified"
  CLI_OPT[yes]="${ANFS_ONBOARD_YES:-false}"
  (
    # shellcheck source=/dev/null
    source "$dir/install.sh"
    declare -F "$fn" >/dev/null || anfs_fail 70 "$qualified declares a step but does not define $fn"
    "$fn"
  ) || rc=$?
  flush_user_messages
  return $rc
}
