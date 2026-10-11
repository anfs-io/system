#!/usr/bin/env bash
# anfs: lists — one table for every tool, and its --json form
#
# A tool emits rows and names the columns; this decides how they are printed:
#
#   on a terminal   headers, then the rows, columns aligned
#   piped           the rows, tab-separated, no header
#   --json          a JSON array of objects, one per row
#
#   {
#     anfs_row "$id" "$dir" "$note"
#     ...
#   } | anfs_table "ID DIR NOTE" "id dir note"
#
#   anfs_row    <field>...                 one row, to stdout
#   anfs_table  "<HEADERS>" "<json keys>"  rows on stdin; both lists space-separated, one per field
#   anfs_result <key> <value>...           with --json, one object (what a command did); else nothing
#   anfs_json_on                           true when --json was given (cli.sh sets ANFS_JSON)
#
# A row is its fields joined by $ANFS_US (0x1f): unlike a tab, bash's `read` does not fold empty
# fields away around it, so any field may be empty.
#
# Cells read the same on a terminal and piped: an empty field is `-`, a path at or under $HOME
# starts with `~`. JSON has the raw values: the whole path, null for an empty field, and a string
# for everything else. A key ending in [] is a list: its field holds the items separated by
# spaces, shown as they are and given as an array in JSON ("provides[]" -> "provides": ["a","b"]).
#
# THE RULE: a tool that reads another tool's list reads it with --json. Keys may be added to a
# list; renaming or removing one breaks its readers. The piped form is for a person's own pipes,
# and no tool depends on it.
#
# ANFS_TABLE=aligned|tsv|json forces a form (tests).
#
# Like everything in lib/anfs/ but bash.sh: functions only, no tool's code, the bash floor (5.2).

ANFS_US=$'\x1f'

anfs_json_on() {
  case "${ANFS_JSON:-}" in ""|0|false|no|off) return 1 ;; *) return 0 ;; esac
}

anfs_row() {
  local IFS="$ANFS_US"
  printf '%s\n' "$*"
}

# A JSON string for <text>, quotes included
_anfs_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# A cell as a person reads it
_anfs_cell() {
  case "$1" in
    "") REPLY=- ;;
    "$HOME") REPLY="~" ;;
    "$HOME"/*) REPLY="~/${1#"$HOME"/}" ;;
    *) REPLY="$1" ;;
  esac
}

anfs_table() {
  local -a heads keys rows f widths items
  local form="${ANFS_TABLE:-}" i j k row line n
  read -ra heads <<< "$1"
  read -ra keys <<< "$2"
  mapfile -t rows
  n=${#heads[@]}
  if [[ -z "$form" ]]; then
    if anfs_json_on; then form=json
    elif [[ -t 1 ]]; then form=aligned
    else form=tsv
    fi
  fi

  if [[ "$form" == json ]]; then
    printf '['
    for i in "${!rows[@]}"; do
      IFS="$ANFS_US" read -ra f <<< "${rows[$i]}" || true
      (( i == 0 )) || printf ','
      printf '{'
      for j in "${!keys[@]}"; do
        (( j == 0 )) || printf ','
        _anfs_json_str "${keys[$j]%\[\]}"
        printf ':'
        if [[ "${keys[$j]}" == *"[]" ]]; then
          read -ra items <<< "${f[$j]:-}"
          printf '['
          for k in "${!items[@]}"; do
            (( k == 0 )) || printf ','
            _anfs_json_str "${items[$k]}"
          done
          printf ']'
        elif [[ -n "${f[$j]:-}" ]]; then _anfs_json_str "${f[$j]}"
        else printf 'null'
        fi
      done
      printf '}'
    done
    printf ']\n'
    return 0
  fi
  [[ ${#rows[@]} -gt 0 ]] || return 0

  if [[ "$form" == tsv ]]; then
    for row in "${rows[@]}"; do
      IFS="$ANFS_US" read -ra f <<< "$row" || true
      line=""
      for (( j = 0; j < n; j++ )); do
        _anfs_cell "${f[$j]:-}"
        line+="${line:+$'\t'}$REPLY"
      done
      printf '%s\n' "$line"
    done
    return 0
  fi

  # Aligned: the widest cell of each column, headers included; the last column is not padded
  local -a cells=()
  for (( j = 0; j < n; j++ )); do widths[j]=${#heads[$j]}; done
  for row in "${rows[@]}"; do
    IFS="$ANFS_US" read -ra f <<< "$row" || true
    for (( j = 0; j < n; j++ )); do
      _anfs_cell "${f[$j]:-}"
      cells+=("$REPLY")
      (( ${#REPLY} <= widths[j] )) || widths[j]=${#REPLY}
    done
  done
  for (( i = -1; i < ${#rows[@]}; i++ )); do
    line=""
    for (( j = 0; j < n; j++ )); do
      if (( i < 0 )); then REPLY="${heads[$j]}"; else REPLY="${cells[$(( i * n + j ))]}"; fi
      if (( j < n - 1 )); then
        printf -v REPLY '%-*s  ' "${widths[$j]}" "$REPLY"
      fi
      line+="$REPLY"
    done
    printf '%s\n' "$line"
  done
}

anfs_result() {
  anfs_json_on || return 0
  local first=true
  printf '{'
  while [[ $# -ge 2 ]]; do
    $first || printf ','
    first=false
    _anfs_json_str "$1"
    printf ':'
    _anfs_json_str "$2"
    shift 2
  done
  printf '}\n'
}
