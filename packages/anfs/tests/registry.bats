#!/usr/bin/env bats
# lib/anfs/cli.sh: a command declared once. Its usage line, its help, the check of what was typed
# and what tab completion offers all come from the declaration.
# Run: bats packages/anfs/tests/

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

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
cli_group note "Notes" --default add
cli_cmd "note add" "Add a note" --opt "--text TEXT: What it says" --opt "-q --quiet: Say nothing"
cmd_note_add() { show "\$@"; }
cli_cmd "note list" "The notes"
cmd_note_list() { echo notes; }
cmd_hidden() { echo "plumbing: \$*"; }
cli_standard

complete_thing() { printf 'alpha\tthe first\nbeta\n'; }
complete_spec() { echo "src/ws"; }
complete_word() { printf 'of:%s\n' "\${CLI_COMPLETE_ARGS[*]}"; }
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

@test "a group's default sub-command takes options with no sub-command; alone or -h it is the group" {
  run "$TOOL" note --text hi -q
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "args: <>" ]
  [ "${lines[1]}" = "quiet=true" ]
  [ "${lines[2]}" = "text=hi" ]
  run "$TOOL" note list
  [ "$output" = notes ]
  run "$TOOL" note
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: demo note <add|list>"* ]]
  [[ "$output" == *"Options with no command go to note add."* ]]
  run "$TOOL" note -h
  [[ "$output" == *"Usage: demo note <add|list>"* ]]
  run "$TOOL" note --bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage: demo note add"* ]]
  run "$TOOL" __complete note -
  [[ "$output" == *"--text"* && "$output" == *"--quiet"* ]]
  run "$TOOL" __complete note ""
  [[ "$output" == *"add"* && "$output" == *"list"* ]]
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

@test "every command takes -y and --yes, declared or not; only a declaration puts it in the usage" {
  run "$TOOL" up -y t
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "args: <t>" ]
  [ "${lines[1]}" = "yes=true" ]
  run "$TOOL" link add --yes d
  [ "${lines[1]}" = "yes=true" ]
  run "$TOOL" remove -yf one
  [[ "$output" == *"force=true"* && "$output" == *"yes=true"* ]]
  run "$TOOL" up --bogus t
  [[ "${lines[1]}" == "demo: usage: demo up "* && "${lines[1]}" != *"-y"* ]]
}

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

# --- asking: -i -----------------------------------------------------------------------------
# The answers are piped in; ANFS_TEST_TERMINAL=1 makes that stdin count as a terminal.

@test "-i asks for the arguments, then the value options, in order; answers land as if typed" {
  ANFS_TEST_TERMINAL=1 run "$TOOL" up -i <<< $'beta\nsnap\n/a\n8080'
  [ "$status" -eq 0 ]
  [[ "$output" == *"<thing>: [snapshot]: Share a directory (PATH): Publish a port (PORT): args: <beta> <snap>"* ]]
  [[ "$output" != *"--fresh"* ]]
  [ "${lines[-3]}" = "interactive=true" ]
  [ "${lines[-2]}" = "p=8080" ]
  [ "${lines[-1]}" = "share=/a" ]
  ANFS_TEST_TERMINAL=1 run "$TOOL" up -i <<< $'beta\n\n\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"args: <beta>"$'\n'"interactive=true" ]]
}

@test "-i: a required argument answered empty is asked again; a ... one is split on spaces" {
  ANFS_TEST_TERMINAL=1 run "$TOOL" up -i <<< $'\n\nbeta\n\n\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"<thing>: "*"<thing>: "*"<thing>: "*"[snapshot]: "*"args: <beta>"* ]]
  ANFS_TEST_TERMINAL=1 run "$TOOL" remove -i <<< 'one two  three'
  [[ "$output" == *"<thing>...: args: <one> <two> <three>"* ]]
  ANFS_TEST_TERMINAL=1 run "$TOOL" up -i < /dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"demo: nothing done" ]]
}

@test "-i shows a kind's candidates; a lone one is the default; dir and file show none" {
  ANFS_TEST_TERMINAL=1 run "$TOOL" up -i <<< $'alpha\n\n\n'
  [[ "$output" == "  alpha  the first"$'\n'"  beta"$'\n'"<thing>: "* ]]
  ANFS_TEST_TERMINAL=1 run "$TOOL" link add -i <<< $'\n\nprod'
  [ "$status" -eq 0 ]
  [[ "$output" == "[dir]:   src/ws"$'\n'"Where (SPEC) [src/ws]: Its name (NAME): args:"* ]]
  [[ "$output" == *"as=prod"*"to=src/ws"* ]]
}

@test "-i given some values asks only for the rest; --interactive is -i" {
  ANFS_TEST_TERMINAL=1 run "$TOOL" up t -p 80 --interactive <<< $'\n/s'
  [ "$status" -eq 0 ]
  [[ "$output" == "[snapshot]: Share a directory (PATH): args: <t>"$'\n'* ]]
  [[ "$output" == *"p=80"*"share=/s"* ]]
}

@test "-i with no terminal is 77; with -y it is a usage error; it is no passthrough's option" {
  run "$TOOL" up -i < /dev/null
  [ "$status" -eq 77 ]
  [ "$output" = "demo: -i needs a terminal" ]
  ANFS_TEST_TERMINAL=1 run "$TOOL" up -i -y t < /dev/null
  [ "$status" -eq 64 ]
  [ "${lines[0]}" = "demo: -i and -y: one asks, the other does not" ]
  ANFS_TEST_TERMINAL=1 run "$TOOL" ps --format json -i < /dev/null
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "args: <--format> <json>" ]
  [ "${lines[1]}" = "interactive=true" ]
  run "$TOOL" up --bogus t
  [[ "${lines[1]}" != *"-i"* ]]
  run "$TOOL" --help
  [[ "$output" == *"  -i, --interactive  Ask for what is not given (after any command)"* ]]
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

@test "a completion function is told the arguments before the one being typed" {
  run complete run alpha ""
  [ "$output" = "of:alpha" ]
  # options and their values are not arguments
  run complete run alpha x ""
  [ "$output" = "of:alpha x" ]
  run complete up --share /x alpha ""
  [ -z "$output" ]
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

# --- anfs: the tools as anfs <resource>, and commands from packages (anfs-<name>) ----------------

# The real anfs in a temp HOME whose ~/.local/bin holds stubs: each prints its name and its
# arguments, notes that it ran, and exits with $STUB_STATUS
anfs_home() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  unset ANFS_CONFIG_HOME ANFS_DATA_HOME ANFS_STATE_HOME ANFS_CACHE_HOME ANFS_DEBUG ANFS_TRACE
  mkdir -p "$HOME/.local/bin" "$HOME/.local/lib" "$HOME/.config/anfs"
  ln -s "$LIB" "$HOME/.local/lib/anfs"
  ANFS="$BATS_TEST_DIRNAME/../home/.local/bin/anfs"
  RAN="$BATS_TEST_TMPDIR/ran"
}
stub() {
  cat > "$HOME/.local/bin/$1" <<SH
#!/usr/bin/env bash
echo "\${0##*/}: \$*"
echo "\${0##*/}" >> "$RAN"
exit \${STUB_STATUS:-0}
SH
  chmod +x "$HOME/.local/bin/$1"
}

@test "anfs <name> runs anfs-<name> with the rest of the line, and its exit status is anfs's" {
  anfs_home
  stub anfs-x
  STUB_STATUS=3 run "$ANFS" x a --b "c d"
  [ "$status" -eq 3 ]
  [ "$output" = "anfs-x: a --b c d" ]
  # -d, --trace and --json given to anfs go along
  run "$ANFS" -d x --json a
  [ "$output" = "anfs-x: -d --json a" ]
  run "$ANFS" x --help
  [ "$output" = "anfs-x: --help" ]
  run "$ANFS" help x sub
  [ "$output" = "anfs-x: help sub" ]
}

@test "a declared command wins over anfs-<its name>, an alias too; an unknown name is still 64" {
  anfs_home
  stub anfs-callbacks
  stub anfs-ppm
  stub ppm
  run "$ANFS" callbacks
  [ "$status" -eq 0 ]
  [ "$output" = "no callbacks registered" ]
  run "$ANFS" ppm --version
  [ "$output" = "ppm: --version" ]
  run "$ANFS" help
  [[ "$output" != *"anfs-callbacks"* && "$output" != *"anfs-ppm"* ]]
  run "$ANFS" bogus
  [ "$status" -eq 64 ]
  [[ "$output" == *"anfs: unknown command 'bogus'"* ]]
}

@test "the tools: anfs package and anfs ppm are ppm, line, status and all" {
  anfs_home
  stub ppm
  stub pmm
  run "$ANFS" package --version
  [ "$output" = "ppm: --version" ]
  run "$ANFS" ppm --version
  [ "$output" = "ppm: --version" ]
  STUB_STATUS=5 run "$ANFS" machine image build debian-13 --json
  [ "$status" -eq 5 ]
  [ "$output" = "pmm: --json image build debian-13" ]
  run "$ANFS" help machine
  [ "$output" = "pmm: help" ]
}

@test "a tool that is not installed: 69, and how to install it" {
  anfs_home
  run "$ANFS" machine list
  [ "$status" -eq 69 ]
  [[ "$output" == *"pmm is not installed (ppm install core/pmm)"* ]]
}

@test "vault is not a resource: anfs vault is an unknown command" {
  anfs_home
  run "$ANFS" vault list
  [ "$status" -eq 64 ]
  run "$ANFS" pvm list
  [ "$status" -eq 64 ]
}

@test "help lists the tools under Tools and the packages' commands under From packages" {
  anfs_home
  stub anfs-x
  run "$ANFS" help
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nTools:\n'*"package, ppm"*"machine, pmm"*"skill, psm"*"space, wsm"* ]]
  [[ "$output" != *vault* && "$output" != *pvm* ]]
  [[ "$output" == *$'\nFrom packages:\n  x '* ]]
  [[ "$output" != *$'Commands:\n'*"  package, ppm"*$'\nTools:'* ]]
  # without a package command there is no such section
  rm "$HOME/.local/bin/anfs-x"
  run "$ANFS" help
  [[ "$output" != *"From packages"* ]]
}

@test "completion: the names start no process; after the name the executable is asked" {
  anfs_home
  stub anfs-x
  stub ppm
  run "$ANFS" __complete ""
  [[ "$output" == *"x"$'\t'* && "$output" == *"machine"$'\t'*"(alias: pmm)"* ]]
  run "$ANFS" __complete pa
  [[ "$output" == *"package"$'\t'* ]]
  [ ! -e "$RAN" ]
  run "$ANFS" __complete x ""
  [ "$output" = "anfs-x: __complete " ]
  run "$ANFS" __complete package ins
  [ "$output" = "ppm: __complete ins" ]
  run "$ANFS" __complete -d ppm install ""
  [ "$output" = "ppm: __complete install " ]
  # a tool that is not installed completes nothing
  run "$ANFS" __complete machine ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the shell function: anfs <resource> goes through the tool's own function (its cd)" {
  anfs_home
  stub anfs
  local sh="$BATS_TEST_DIRNAME/../home/.config/sh/anfs.sh"
  # wsm and pmm as shell functions, as sh/wsm.sh and sh/pmm.sh define them; pcm not installed
  # PATH is the stubs' and the system's only: the host's own pcm must not be found
  run bash -c 'PATH="$HOME/.local/bin:/usr/bin:/bin"; . "$1"
    wsm() { echo "wsm function: $*"; }; pmm() { echo "pmm function: $*"; }
    anfs space cd x; anfs wsm ls; anfs machine cd y; anfs container ls' _ "$sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "wsm function: cd x" ]
  [ "${lines[1]}" = "wsm function: ls" ]
  [ "${lines[2]}" = "pmm function: cd y" ]
  # pcm is not installed: anfs is asked, and says so
  [ "${lines[3]}" = "anfs: container ls" ]
}

@test "every list starts with its resource's kind, or is one of the lists that are not; none says STATE" {
  local root="$BATS_TEST_DIRNAME/../.." line head bad=""
  local kinds=" PACKAGE CONTAINER MACHINE IMAGE NETWORK SKILL SPACE REPOSITORY SOURCE ISO STACK "
  # Lists that are not of a source's resources take only STATUS (AGENTS.md "Lists and --json")
  local others="|NAME ARCH BACKEND PID SSH|NAME BUILD|TOOL LISTENER STATUS HANDLER|STEP PACKAGE STATUS DETAIL|CHECK STATUS DETAIL|KIND RESOURCE DECLARED ACTUAL FROM|NAME VALUE FROM|TOOL NAME VALUE FROM|EVENT SUBJECT SPACE BY|SERVICE STATUS DETAIL|RUN STATUS RULE ROLE SPACE HARNESS JOB AGE|RULE STATUS SPACE ON AS HARNESS|EVENT SUBJECT RULE REASON AGE|"
  while IFS= read -r line; do
    head="${line#*anfs_table \"}" head="${head%%\"*}"
    # push's list (lib/anfs/repo.sh) is headed by the kind its caller names, checked below
    [[ "$head" != '${kind^^} STATUS BRANCH UPSTREAM' ]] || continue
    [[ " $head " != *" STATE "* ]] || bad+="$line"$'\n'
    [[ "$kinds" == *" ${head%% *} "* || "$others" == *"|$head|"* ]] || bad+="$line"$'\n'
  done < <(grep -rh 'anfs_table "' "$root"/*/home | grep -v '^[[:space:]]*#')
  while IFS= read -r line; do
    head="${line#*anfs_repo_push_cli }" head="${head%% *}"
    [[ "$kinds" == *" ${head^^} "* ]] || bad+="$line"$'\n'
  done < <(grep -rhE '^[[:space:]]*anfs_repo_push_cli [a-z]' "$root"/*/home)
  [ -z "$bad" ] || { printf '%s' "$bad"; false; }
}

@test "a core tool ships its <tool>.env if and only if it declares the config group" {
  local root="$BATS_TEST_DIRNAME/../.." dir t bad=""
  for dir in "$root"/*/home/.local/bin; do
    t="${dir%/home/.local/bin}" t="${t##*/}"
    [[ -f "$dir/$t" ]] || continue
    if [[ -f "$root/$t/home/.config/$t/$t.env" ]]; then
      grep -rqs anfs_config_declare "$dir/$t" "$root/$t/home/.local/lib/$t" || bad+="$t ships $t.env and declares no config group"$'\n'
    else
      ! grep -rqs anfs_config_declare "$dir/$t" "$root/$t/home/.local/lib/$t" || bad+="$t declares the config group and ships no $t.env"$'\n'
    fi
  done
  [ -z "$bad" ] || { printf '%s' "$bad"; false; }
  # the five with settings, psm without
  for t in anfs ppm pcm pmm wsm; do grep -rqs anfs_config_declare "$root/$t/home/.local"; done
  ! grep -rqs anfs_config_declare "$root/psm/home/.local"
}
