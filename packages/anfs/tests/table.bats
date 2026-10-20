#!/usr/bin/env bats
# lib/anfs/table.sh: one list, three forms (a terminal, a pipe, --json); and --json as an option
# cli.sh gives every tool.
# Run: bats packages/anfs/tests/

setup() {
  LIB="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset ANFS_JSON ANFS_TABLE ANFS_COLOR NO_COLOR
  export ANFS_LOG=off
  # shellcheck source=/dev/null
  source "$LIB/table.sh"
  # A tool the way the real ones are built
  TOOL="$BATS_TEST_TMPDIR/demo"
  cat > "$TOOL" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$LIB/log.sh"
source "$LIB/cli.sh"
source "$LIB/table.sh"
CLI_TOOL=demo
cli_cmd ls "List" --arg "[state]"
cmd_ls() {
  { anfs_row one "\$HOME/a" ok; anfs_row two "" "\${1:-}"; } | anfs_table "NAME DIR STATE" "name dir state"
}
cli_cmd args "Print the arguments" --passthrough --arg "[word...]"
cmd_args() { printf '<%s>' "\$@"; echo; anfs_json_on && echo json || echo plain; }
cli_cmd did "Do something"
cmd_did() { anfs_json_on || echo "done it"; anfs_result what it count 2; }
cli_dispatch "\$@"
SH
  chmod +x "$TOOL"
}

rows() {
  anfs_row alpha "$HOME/spaces/a" ""
  anfs_row "a longer name" "" 'say "hi"'
  anfs_row c /etc "tab	in it"
}

@test "on a terminal: headers, then rows, columns aligned, the last one unpadded" {
  ANFS_TABLE=aligned run anfs_table "NAME DIR NOTE" "name dir note" < <(rows)
  [ "${lines[0]}" = "NAME           DIR         NOTE" ]
  [ "${lines[1]}" = "alpha          ~/spaces/a  -" ]
  [ "${lines[2]}" = 'a longer name  -           say "hi"' ]
  [ "${#lines[@]}" -eq 4 ]
}

@test "color: a STATUS cell needing attention, on a terminal only, the columns still aligned" {
  status_rows() { anfs_row a dirty x; anfs_row "a longer" unpushed y; anfs_row b "no upstream" z; anfs_row c clean w; }
  local red=$'\033[31m' yellow=$'\033[33m' off=$'\033[0m'
  ANFS_COLOR=1 ANFS_TABLE=aligned run anfs_table "NAME STATUS NOTE" "name status note" < <(status_rows)
  [ "${lines[0]}" = "NAME      STATUS       NOTE" ]
  [ "${lines[1]}" = "a         ${red}dirty${off}        x" ]
  [ "${lines[2]}" = "a longer  ${yellow}unpushed${off}     y" ]
  [ "${lines[3]}" = "b         ${yellow}no upstream${off}  z" ]
  [ "${lines[4]}" = "c         clean        w" ]
  ANFS_COLOR=1 ANFS_TABLE=aligned run anfs_table "NAME STATUS" "name status" < <(anfs_row a "dirty, unpushed")
  [ "${lines[1]}" = "a     ${red}dirty, unpushed${off}" ]
  NO_COLOR=1 ANFS_COLOR=1 ANFS_TABLE=aligned run anfs_table "NAME STATUS" "name status" < <(status_rows)
  [[ "$output" != *$'\033'* ]]
  ANFS_COLOR=1 run anfs_table "NAME STATUS" "name status" < <(status_rows)
  [[ "$output" != *$'\033'* ]]
  ANFS_COLOR=1 ANFS_JSON=true run anfs_table "NAME STATUS" "name status" < <(status_rows)
  [[ "$output" != *$'\033'* ]]
  ANFS_COLOR=1 ANFS_TABLE=aligned run anfs_table "NAME STATE" "name state" < <(status_rows)
  [[ "$output" != *$'\033'* ]]
}

@test "piped: the same cells, tab-separated, no header" {
  run anfs_table "NAME DIR NOTE" "name dir note" < <(rows)
  [ "${lines[0]}" = "alpha"$'\t'"~/spaces/a"$'\t'"-" ]
  [ "${lines[1]}" = "a longer name"$'\t'"-"$'\t'"say \"hi\"" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "json: raw values, null for an empty field, strings escaped" {
  ANFS_JSON=true run anfs_table "NAME DIR NOTE" "name dir note" < <(rows)
  [ "${#lines[@]}" -eq 1 ]
  local json="$output"
  run yq -p json -r '.[0] | .name + "|" + .dir + "|" + (.note | tag)' <<< "$json"
  [ "$output" = "alpha|$HOME/spaces/a|!!null" ]
  run yq -p json -r '.[1] | (.dir | tag) + "|" + .note' <<< "$json"
  [ "$output" = '!!null|say "hi"' ]
  run yq -p json -r '.[2].note' <<< "$json"
  [ "$output" = "tab	in it" ]
}

@test "an empty field keeps its place wherever it is" {
  run anfs_table "A B C D" "a b c d" < <(anfs_row "" x "" ""; anfs_row "" "" "" y)
  [ "${lines[0]}" = "-"$'\t'"x"$'\t'"-"$'\t'"-" ]
  [ "${lines[1]}" = "-"$'\t'"-"$'\t'"-"$'\t'"y" ]
}

@test "home itself is ~, and a path that only starts like home is left alone" {
  run anfs_table "P" "p" < <(anfs_row "$HOME"; anfs_row "${HOME}x/y")
  [ "${lines[0]}" = "~" ]
  [ "${lines[1]}" = "${HOME}x/y" ]
}

@test "no rows: nothing as a table, [] as json" {
  run anfs_table "A" "a" < /dev/null
  [ -z "$output" ]
  ANFS_TABLE=aligned run anfs_table "A" "a" < /dev/null
  [ -z "$output" ]
  ANFS_JSON=true run anfs_table "A" "a" < /dev/null
  [ "$output" = "[]" ]
}

@test "a value that looks like a number or a boolean is still a string" {
  ANFS_JSON=1 run anfs_table "A B C" "a b c" < <(anfs_row 2345672345 true null)
  [ "$output" = '[{"a":"2345672345","b":"true","c":"null"}]' ]
}

@test "anfs_result: an object with --json, nothing without" {
  run anfs_result id abc path "/x y"
  [ -z "$output" ]
  ANFS_JSON=true run anfs_result id abc path "/x y"
  [ "$output" = '{"id":"abc","path":"/x y"}' ]
}

@test "--json is taken before the command and after it" {
  run "$TOOL" ls
  [ "${lines[0]}" = "one"$'\t'"~/a"$'\t'"ok" ]
  run "$TOOL" --json ls
  [[ "$output" == '[{"name":"one","dir":"'"$HOME"'/a","state":"ok"},{"name":"two","dir":null,"state":null}]' ]]
  run "$TOOL" ls --json
  [[ "$output" == '[{"name":"one"'* ]]
  run "$TOOL" -d --json ls
  [[ "$output" == '[{"name":"one"'* ]]
}

@test "--json is stripped from the arguments, but not after --" {
  run "$TOOL" args a --json b
  [ "${lines[0]}" = "<a><b>" ]
  [ "${lines[1]}" = "json" ]
  run "$TOOL" args a -- --json b
  [ "${lines[0]}" = "<a><--><--json><b>" ]
  [ "${lines[1]}" = "plain" ]
}

@test "--json is not passed on to a tool this one runs" {
  sed -i.bak 's|^cli_dispatch.*|cli_cmd child "What a child sees"\ncmd_child() { bash -c "echo child=\\${ANFS_JSON:-unset}"; }\ncli_dispatch "$@"|' "$TOOL"
  run "$TOOL" child --json
  [ "$output" = "child=unset" ]
}

@test "a command that changes something answers with an object under --json" {
  run "$TOOL" did
  [ "$output" = "done it" ]
  run "$TOOL" did --json
  [ "$output" = '{"what":"it","count":"2"}' ]
}

@test "--json is listed in help" {
  run "$TOOL" help
  [[ "$output" == *"--json"* ]]
}
