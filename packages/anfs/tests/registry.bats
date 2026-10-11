#!/usr/bin/env bats
# lib/anfs/cli.sh: a command declared once. Its usage line, its help, the check of what was typed
# and what tab completion offers all come from the declaration.
# Run: bats packages/anfs/tests/

setup() {
  LIB="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  export ANFS_LOG=off
  unset CLI_EX_USAGE ANFS_JSON
  TOOL="$BATS_TEST_TMPDIR/demo"
  cat > "$TOOL" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "$LIB/log.sh"
source "$LIB/cli.sh"
CLI_TOOL=demo CLI_VERSION=1.2.3

show() { local k; printf 'args:'; printf ' <%s>' "\$@"; echo; for k in \$(printf '%s\n' "\${!CLI_OPT[@]}" | sort); do printf '%s=%s\n' "\$k" "\${CLI_OPT[\$k]//\$'\n'/,}"; done; }

cli_cmd list "List the things" --alias ls --opt "-a --all: Hidden ones too" --arg "[filter]"
cmd_list() { show "\$@"; }
cli_cmd remove "Remove things
and what belongs to them" --alias rm --opt "-y --yes: Do not ask" --opt "-f --force: Even if used" --arg "thing..."
cmd_remove() { show "\$@"; }
cli_cmd up "Start a thing" --opt "--share PATH: Share a directory" --opt "-p PORT: Publish a port" --opt "--fresh: From scratch" --arg "thing" --arg "[snapshot]"
cmd_up() { show "\$@"; }
cli_cmd ps "What is running" --passthrough --opt "-q --quiet: Names only" --arg "[thing...]"
cmd_ps() { show "\$@"; }
cli_cmd run "Run a command in a thing" --arg "thing" --arg "[word...]"
cmd_run() { show "\$@"; }
cli_group link "Things linked to places"
cli_cmd "link add" "Link a directory" --opt "--to SPEC: Where" --opt "--as NAME: Its name" --arg "[dir]"
cmd_link_add() { show "\$@"; }
cli_cmd "link remove" "Unlink" --alias rm --arg "[dir]"
cmd_link_remove() { show "\$@"; }
cli_cmd "link list" "The links" --alias ls
cmd_link_list() { echo links; }
cmd_hidden() { echo "plumbing: \$*"; }
cli_standard

complete_thing() { printf 'alpha\tthe first\nbeta\n'; }
complete_spec() { echo "src/ws"; }
cli_dispatch "\$@"
SH
  chmod +x "$TOOL"
}

# --- running --------------------------------------------------------------------------------

@test "positional arguments arrive as arguments, options in CLI_OPT by long name" {
  run "$TOOL" remove -y one two
  [ "${lines[0]}" = "args: <one> <two>" ]
  [ "${lines[1]}" = "yes=true" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "options may come anywhere after the command, short or long, and run together" {
  run "$TOOL" remove one --force two -y
  [ "${lines[0]}" = "args: <one> <two>" ]
  [ "${lines[1]}" = "force=true" ]
  [ "${lines[2]}" = "yes=true" ]
  run "$TOOL" remove -yf one
  [ "${lines[1]}" = "force=true" ]
  [ "${lines[2]}" = "yes=true" ]
}

@test "an option with a value: separate, with =, attached to a short one, and twice" {
  run "$TOOL" up --share /a t
  [ "${lines[1]}" = "share=/a" ]
  run "$TOOL" up --share=/a=b t
  [ "${lines[1]}" = "share=/a=b" ]
  run "$TOOL" up -p8080 t
  [ "${lines[1]}" = "p=8080" ]
  run "$TOOL" up -p 80 --share /a --share "/b c" t snap
  [ "${lines[0]}" = "args: <t> <snap>" ]
  [ "${lines[1]}" = "p=80" ]
  [ "${lines[2]}" = "share=/a,/b c" ]
}

@test "after -- everything is an argument; a lone - is one too" {
  run "$TOOL" run thing -- --not-an-option -x
  [ "${lines[0]}" = "args: <thing> <--not-an-option> <-x>" ]
  run "$TOOL" run thing -
  [ "${lines[0]}" = "args: <thing> <->" ]
}

@test "an alias runs the command, at the top level and in a group" {
  run "$TOOL" ls -a x
  [ "${lines[0]}" = "args: <x>" ]
  [ "${lines[1]}" = "all=true" ]
  run "$TOOL" rm one
  [ "${lines[0]}" = "args: <one>" ]
  run "$TOOL" link rm dir
  [ "${lines[0]}" = "args: <dir>" ]
  run "$TOOL" link ls
  [ "$output" = "links" ]
}

@test "a two-word command runs its own function with its own options" {
  run "$TOOL" link add docs --to src/ws --as product
  [ "${lines[0]}" = "args: <docs>" ]
  [ "${lines[1]}" = "as=product" ]
  [ "${lines[2]}" = "to=src/ws" ]
}

@test "a passthrough command keeps what it did not declare, in place" {
  run "$TOOL" ps -q one --format json -a -- x
  [ "${lines[0]}" = "args: <one> <--format> <json> <-a> <--> <x>" ]
  [ "${lines[1]}" = "quiet=true" ]
}

@test "a cmd_ function nothing declared still runs, its arguments untouched, and is in no help" {
  run "$TOOL" hidden a -b
  [ "$output" = "plumbing: a -b" ]
}

# --- refusing -------------------------------------------------------------------------------

@test "an unknown option is named, the generated usage follows, exit 64" {
  run "$TOOL" remove --bogus x
  [ "$status" -eq 64 ]
  [ "${lines[0]}" = "demo: unknown option '--bogus'" ]
  [ "${lines[1]}" = "demo: usage: demo remove [-y] [-f] <thing>..." ]
  run "$TOOL" remove -yx one
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown option '-x'"* ]]
  run "$TOOL" list --all=yes
  [ "$status" -eq 64 ]
}

@test "a value that is missing, too few arguments and too many are usage errors" {
  run "$TOOL" up t --share
  [ "$status" -eq 64 ]
  [ "${lines[0]}" = "demo: --share needs a value (PATH)" ]
  run "$TOOL" remove
  [ "$status" -eq 64 ]
  [ "$output" = "demo: usage: demo remove [-y] [-f] <thing>..." ]
  run "$TOOL" up
  [ "$status" -eq 64 ]
  run "$TOOL" up a b c
  [ "$status" -eq 64 ]
  [ "${lines[0]}" = "demo: too many arguments" ]
  [ "${lines[1]}" = "demo: usage: demo up [--share PATH] [-p PORT] [--fresh] <thing> [snapshot]" ]
}

@test "an unknown command, and an unknown sub-command, exit 64 with the help that applies" {
  run "$TOOL" nope
  [ "$status" -eq 64 ]
  [ "${lines[0]}" = "demo: unknown command 'nope'" ]
  run "$TOOL" link nope
  [ "$status" -eq 64 ]
  [ "${lines[0]}" = "demo: unknown command 'link nope'" ]
  [[ "$output" == *"Usage: demo link <add|remove|list>"* ]]
}

# --- help -----------------------------------------------------------------------------------

@test "help lists each command once, its aliases after its name, its usage generated" {
  run "$TOOL" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"  list, ls [-a] [filter]"*"List the things"* ]]
  [[ "$output" == *"  remove, rm [-y] [-f] <thing>..."*"Remove things"* ]]
  [[ "$output" == *"and what belongs to them"* ]]
  [[ "$output" == *"  link <add|remove|list>"*"Things linked to places"* ]]
  [[ "$output" != *"hidden"* ]]
  [[ "$output" != *"link add"* ]]
  [[ "$output" == *"--version"* ]]
  # ls is not a line of its own
  ! grep -qE '^  ls( |$)' <<< "$output"
}

@test "a command's own help: usage, summary, alias, options" {
  run "$TOOL" remove --help
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Usage: demo remove [-y] [-f] <thing>..." ]
  [[ "$output" == *"Alias: rm"* ]]
  [[ "$output" == *"-y, --yes    Do not ask"* ]]
  [[ "$output" == *"-f, --force  Even if used"* ]]
  run "$TOOL" help rm
  [ "${lines[0]}" = "Usage: demo remove [-y] [-f] <thing>..." ]
  run "$TOOL" help link add
  [ "${lines[0]}" = "Usage: demo link add [--to SPEC] [--as NAME] [dir]" ]
}

@test "a group on its own, or with --help, shows its sub-commands" {
  run "$TOOL" link
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Usage: demo link <add|remove|list>" ]
  [[ "$output" == *"  add [--to SPEC] [--as NAME] [dir]"*"Link a directory"* ]]
  [[ "$output" == *"  remove, rm [dir]"* ]]
  run "$TOOL" link --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"  list, ls"* ]]
}

@test "--version, and -h for help" {
  run "$TOOL" --version
  [ "$output" = "demo 1.2.3" ]
  run "$TOOL" -h
  [[ "${lines[0]}" == "Usage: demo <command> [args]" ]]
}

# --- completion -----------------------------------------------------------------------------

complete() { "$TOOL" __complete "$@"; }

@test "completing the command: every command once, aliases in the description" {
  run complete ""
  [[ "$output" == *"list"$'\t'"List the things (alias: ls)"* ]]
  [[ "$output" == *"remove"$'\t'"Remove things (alias: rm)"* ]]
  [[ "$output" == *"link"$'\t'"Things linked to places"* ]]
  ! grep -qE '^(ls|rm)	' <<< "$output"
  ! grep -q hidden <<< "$output"
}

@test "an alias is offered only when what is typed can be nothing else" {
  run complete "l"
  ! grep -qE '^ls	' <<< "$output"
  run complete "rm"
  [[ "$output" == *"rm"$'\t'"alias of remove"* ]]
}

@test "options are offered only once a - is typed" {
  run complete remove ""
  [ "${lines[0]}" = "alpha"$'\t'"the first" ]
  [ "${lines[1]}" = "beta" ]
  [[ "$output" != *"--yes"* ]]
  run complete remove "-"
  [[ "$output" == *"--yes"$'\t'"Do not ask"* ]]
  [[ "$output" == *"-f"$'\t'"Even if used"* ]]
  [[ "$output" != *"alpha"* ]]
}

@test "an argument completes by its kind: the tool's function, a path, or nothing" {
  run complete rm one ""
  [ "${lines[0]}" = "alpha"$'\t'"the first" ]
  run complete up ""
  [ "${lines[0]}" = "alpha"$'\t'"the first" ]
  # the second argument is a snapshot: no function for that kind
  run complete up alpha ""
  [ -z "$output" ]
  run complete link add ""
  [ "$output" = ":dirs" ]
}

@test "an option's value completes by the option's kind, and does not count as an argument" {
  run complete link add --to ""
  [ "$output" = "src/ws" ]
  run complete up --share ""
  [ "$output" = ":files" ]
  run complete up --share /x ""
  [ "${lines[0]}" = "alpha"$'\t'"the first" ]
}

@test "a group completes its sub-commands, then the sub-command's arguments" {
  run complete link ""
  [[ "$output" == *"add"$'\t'"Link a directory"* ]]
  [[ "$output" == *"remove"$'\t'"Unlink (alias: rm)"* ]]
  ! grep -qE '^rm	' <<< "$output"
  run complete link rm ""
  [ "$output" = ":dirs" ]
}

@test "the options before the command are stepped over; an unknown command completes nothing" {
  run complete -d --json remove ""
  [ "${lines[0]}" = "alpha"$'\t'"the first" ]
  run complete nope ""
  [ -z "$output" ]
  run complete "-"
  [[ "$output" == *"--json"* && "$output" == *"--version"* ]]
}

@test "help completes command names, and plumbing completes nothing" {
  run complete help ""
  [[ "$output" == *"remove"$'\t'* ]]
  run complete hidden ""
  [ -z "$output" ]
}

@test "a tab press costs little: under 100 ms" {
  [[ -n "${EPOCHREALTIME:-}" ]] || skip "no microsecond clock in this bash"
  local start end best=999999 i
  # The best of three: the first run pays for a cold file cache
  for i in 1 2 3; do
    start="${EPOCHREALTIME/[.,]/}"
    complete remove "" >/dev/null
    end="${EPOCHREALTIME/[.,]/}"
    (( end - start >= best )) || best=$(( end - start ))
  done
  echo "best of three: $(( best / 1000 )) ms"
  (( best / 1000 < 100 ))
}

@test "completion zsh prints a script that asks the tool, and knows nothing of its commands" {
  run "$TOOL" completion zsh
  [ "${lines[0]}" = "#compdef demo" ]
  [[ "$output" == *"command demo __complete"* ]]
  [[ "$output" != *"remove"* ]]
  run "$TOOL" completion
  [ "${lines[0]}" = "#compdef demo" ]
  run "$TOOL" completion bash
  [[ "$output" == *"complete -F _demo_complete demo"* ]]
  run "$TOOL" completion fish
  [ "$status" -eq 64 ]
}
