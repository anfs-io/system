#!/usr/bin/env bash
# anfs: the command line every tool shares
#
# A command is a function named cmd_<name> (a dash in <name> is an underscore in the function).
# A tool registers each public one with a usage line and a summary, in the order its help lists
# them; help and the zsh completion of the command names are generated from that registry, so
# neither can drift from what exists. A cmd_ function left unregistered still runs: that is how a
# tool keeps plumbing (`psm path`, `pcm __compose`) out of its help. Only cmd_ functions run, so a
# tool's internals are never reachable from its command line by accident.
#
#   CLI_TOOL=pcm                                    name in messages and help
#   cli_cmd up "up [options] <service>..." "Start services"
#   cli_alias ls list                               ls runs cmd_list
#   cli_dispatch "$@"                               run the named command
#
# Summaries may span lines (embedded newlines); help indents the rest under the first.
# A tool may define cli_help_epilogue to print more after the command list.
#
# Like everything in lib/anfs/: functions and variables only, no tool's code, bash 3.2-safe.

CLI_TOOL="${CLI_TOOL:-}"
CLI_NAMES=() CLI_USAGES=() CLI_SUMMARIES=()
CLI_ALIASES=""
# Exit status for an unknown command (wsm uses 64, EX_USAGE)
CLI_EX_USAGE="${CLI_EX_USAGE:-1}"

# Usage: cli_cmd <name> <usage line> <summary>
cli_cmd() {
  CLI_NAMES+=("$1") CLI_USAGES+=("$2") CLI_SUMMARIES+=("$3")
}

# Usage: cli_alias <alias> <command>
cli_alias() {
  CLI_ALIASES="$CLI_ALIASES $1=$2"
}

# The command an alias stands for, or the name itself
cli_resolve() {
  local a
  for a in $CLI_ALIASES; do
    [[ "${a%%=*}" == "$1" ]] && { echo "${a#*=}"; return 0; }
  done
  echo "$1"
}

# True when <name> is a command: a cmd_ function exists for it
cli_has() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]] && declare -F "cmd_${1//-/_}" >/dev/null
}

# Run the command named by $1 with the rest of the arguments; help when there is none
cli_dispatch() {
  local name
  name=$(cli_resolve "${1:-help}")
  shift || true
  case "$name" in -h|--help) name=help ;; esac
  if cli_has "$name"; then
    "cmd_${name//-/_}" "$@"
  else
    echo "$CLI_TOOL: unknown command '$name'" >&2
    cli_help >&2
    return "$CLI_EX_USAGE"
  fi
}

# The registered commands: usage lines padded to one column, then the summary
cli_help_commands() {
  local i width=0 line first rest
  for i in ${CLI_NAMES[@]+"${!CLI_NAMES[@]}"}; do
    (( ${#CLI_USAGES[$i]} > width )) && width=${#CLI_USAGES[$i]}
  done
  (( width > 34 )) && width=34
  for i in ${CLI_NAMES[@]+"${!CLI_NAMES[@]}"}; do
    first="${CLI_SUMMARIES[$i]%%$'\n'*}"
    if (( ${#CLI_USAGES[$i]} > width )); then
      printf '  %s\n  %-*s  %s\n' "${CLI_USAGES[$i]}" "$width" "" "$first"
    else
      printf '  %-*s  %s\n' "$width" "${CLI_USAGES[$i]}" "$first"
    fi
    if [[ "${CLI_SUMMARIES[$i]}" == *$'\n'* ]]; then
      rest="${CLI_SUMMARIES[$i]#*$'\n'}"
      while IFS= read -r line; do
        printf '  %-*s  %s\n' "$width" "" "$line"
      done <<< "$rest"
    fi
  done
}

cli_help() {
  echo "Usage: $CLI_TOOL <command> [args]"
  echo ""
  echo "Commands:"
  cli_help_commands
  if declare -F cli_help_epilogue >/dev/null; then
    echo ""
    cli_help_epilogue
  fi
}

cmd_help() { cli_help; }

# For a zsh completion: one 'name:summary' word per registered command and alias, quoted for
# _describe. Print it inside the tool's completion function:  subcmds=( $(...) )
cli_zsh_commands() {
  local i a summary
  for i in ${CLI_NAMES[@]+"${!CLI_NAMES[@]}"}; do
    summary="${CLI_SUMMARIES[$i]%%$'\n'*}"
    summary="${summary//\'/}"
    summary="${summary//:/ -}"
    printf "    '%s:%s'\n" "${CLI_NAMES[$i]}" "$summary"
  done
  for a in $CLI_ALIASES; do
    printf "    '%s:alias for %s'\n" "${a%%=*}" "${a#*=}"
  done
}

cli_warn() { echo "$CLI_TOOL: $*" >&2; }
cli_die()  { cli_warn "$@"; exit 1; }
