#!/usr/bin/env bats
# anfs's stacks (lib/anfs/stacks.sh): the manifest, list, show, install, remove, path, and
# `anfs src install`. The real anfs in a temp $HOME; ppm, psm, wsm, pcm and pmm are stubs that log
# their argv and keep what they "installed" in a file, which their `list --json` answers from.
# Run: bats packages/anfs/tests/stacks.bats

bats_require_minimum_version 1.5.0

setup() {
  local packages="$BATS_TEST_DIRNAME/../.." tools="$BATS_TEST_TMPDIR/tools" t
  ANFS="$packages/anfs/home/.local/bin/anfs"
  export HOME="$BATS_TEST_TMPDIR/home"
  ST="$HOME/stub"
  SOURCES="$HOME/.local/share/anfs/sources"
  RECORDS="$HOME/.local/state/anfs/stacks"
  LOG="$ST/log"
  mkdir -p "$HOME/.local/lib" "$HOME/.local/bin" "$HOME/.config/anfs" "$ST" "$tools" "$SOURCES"
  ln -s "$(cd "$packages/anfs/home/.local/lib/anfs" && pwd)" "$HOME/.local/lib/anfs"
  for t in bash yq; do ln -s "$(command -v "$t")" "$tools/$t"; done
  export PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_JSON
  unset PPM_STATE_HOME PCM_STATE_HOME PMM_STATE_HOME PSM_STATE_HOME WSM_STATE_HOME ANFS_STATE_HOME
  export ANFS_LOG=off ANFS_TABLE=tsv GIT_CONFIG_NOSYSTEM=1 ST LOG
  : > "$LOG"

  printf '# Your anfs sources\n' > "$HOME/.config/anfs/user.list"
  # lgat before core: lgat is the higher priority, so it may depend on core and not the reverse
  printf '%s  lgat\n%s  core\n' "$SOURCES/lgat" "$SOURCES/core" > "$HOME/.config/anfs/system.list"
  mkdir -p "$SOURCES/lgat/packages" "$SOURCES/core/packages"

  for t in ppm psm wsm pcm pmm; do stub "$t"; done
  printf 'lgat/main/tech\nlgat/main/org\n' > "$ST/wsm.spaces"

  stack core base <<'YML'
version: 0.1.0
description: the base
packages: [stack/git]
skills: [core/s1]
YML
  stack lgat app <<'YML'
version: 0.2.0
description: the app
stacks: [core/base]
packages: [stack/ruby]
skills: [core/s1]
spaces:
  - lgat/: { status: cloned }
containers:
  - core/ui: { status: running }
  - core/db
machines:
  - core/vm: { status: stopped }
YML
}

# stacks/<name>/stack.yml in source <src>, from stdin
stack() {
  mkdir -p "$SOURCES/$1/stacks/$2"
  cat > "$SOURCES/$1/stacks/$2/stack.yml"
}

# A tool stub: logs "<tool> <argv>"; install and remove keep $ST/<tool>.have ("name status" lines),
# list --json prints it with the tool's keys. wsm's spaces are $ST/wsm.spaces (ids); a prefix
# (lgat/) installs or removes every one under it, and list prints each, null when not installed.
stub() {
  cat > "$HOME/.local/bin/$1" <<'SH'
#!/bin/bash
t="${0##*/}" have="$ST/${0##*/}.have"
touch "$have"
case "$*" in *--json*) ;; *) echo "$t $*" >> "$LOG" ;; esac
cmd="$1"; shift
# wsm: a prefix stands for the spaces under it
expand() {
  local a
  for a in "$@"; do
    case "$t:$a" in
      -*) ;;
      wsm:*/) grep -E "^${a%/}(/|\$)" "$ST/wsm.spaces" || true ;;
      *) echo "$a" ;;
    esac
  done
}
case "$t:$cmd" in
  wsm:list)
    printf '['; sep=""
    while read -r n; do
      if grep -qx "$n .*" "$have"; then s='"ok"'; d="\"/w/$n\""; else s=null; d=null; fi
      printf '%s{"space":"%s","status":%s,"dir":%s}' "$sep" "$n" "$s" "$d"; sep=,
    done < "$ST/wsm.spaces"
    echo ']' ;;
  wsm:install)
    for a in $(expand "$@"); do grep -qx "$a .*" "$have" || echo "$a ok" >> "$have"; done ;;
  wsm:remove)
    for a in $(expand "$@"); do grep -vx "$a .*" "$have" > "$have.n" || true; mv "$have.n" "$have"; done ;;
  *:install)
    for a in "$@"; do
      case "$a" in -*) continue ;; esac
      grep -qx "$a .*" "$have" || echo "$a $([ "$t" = pcm ] || [ "$t" = pmm ] && echo running || echo ok)" >> "$have"
    done ;;
  *:remove)
    for a in "$@"; do
      case "$a" in -*) continue ;; esac
      grep -vx "$a .*" "$have" > "$have.n" || true; mv "$have.n" "$have"
    done ;;
  *:list)
    sep="" ; printf '['
    while read -r n s; do
      case "$t" in
        ppm) printf '%s{"package":"%s","status":"installed","version":"0.1.0"}' "$sep" "$n" ;;
        psm) printf '%s{"skill":"%s","status":"%s"}' "$sep" "$n" "$s" ;;
        pcm) printf '%s{"container":"%s","status":"%s"}' "$sep" "$n" "$s" ;;
        pmm) printf '%s{"machine":"%s","status":"%s","image":null,"address":null}' "$sep" "$n" "$s" ;;
      esac
      sep=,
    done < "$have"
    echo ']' ;;
esac
exit 0
SH
  chmod +x "$HOME/.local/bin/$1"
}

# Pre-install <name> with <tool>
have() { echo "$2 ${3:-ok}" >> "$ST/$1.have"; }

# --- the manifest --------------------------------------------------------------------------------

@test "an unknown key is 64, naming it" {
  stack lgat bad <<<'packages: [a/b]
bogus: 1'
  run "$ANFS" show lgat/bad
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown key 'bogus'"* ]]
  run "$ANFS" install -y lgat/bad </dev/null
  [ "$status" -eq 64 ]
  [ ! -s "$LOG" ]
}

@test "vaults are not a kind: a stack.yml with vaults: is 64" {
  stack lgat notes <<<'packages: [a/b]
vaults: [x/y]'
  run "$ANFS" show lgat/notes
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown key 'vaults'"* ]]
  [[ "$output" != *"vaults, "* ]]
}

@test "a status that is not the kind's is 64; a kind without status takes none" {
  stack lgat bad <<<'containers:
  - a/b: { status: installed }'
  run "$ANFS" show lgat/bad
  [ "$status" -eq 64 ]
  [[ "$output" == *"status 'installed' (running or stopped)"* ]]
  stack lgat bad2 <<<'packages:
  - a/b: { status: running }'
  run "$ANFS" show lgat/bad2
  [ "$status" -eq 64 ]
  stack lgat bad3 <<<'containers:
  - a/b: { status: running, port: 1 }'
  run "$ANFS" show lgat/bad3
  [ "$status" -eq 64 ]
  [[ "$output" == *"only status:"* ]]
}

@test "a cycle is 1, naming the chain" {
  stack lgat c1 <<<'stacks: [c2]'
  stack lgat c2 <<<'stacks: [c3]'
  stack lgat c3 <<<'stacks: [lgat/c1]'
  run "$ANFS" show lgat/c1
  [ "$status" -eq 1 ]
  [[ "$output" == *"circular stack dependency: lgat/c1 -> lgat/c2 -> lgat/c3 -> lgat/c1"* ]]
}

@test "a stack depends only on its own source or a lower-priority one" {
  stack core up <<<'stacks: [lgat/app]'
  run "$ANFS" show core/up
  [ "$status" -eq 1 ]
  [[ "$output" == *"lower-priority"* ]]
}

@test "dependency order: depth-first, each stack once, dependencies first" {
  stack core a <<<'packages: [p/a]'
  stack core b <<<'stacks: [a]
packages: [p/b]'
  stack lgat c <<<'stacks: [core/b, a]
packages: [p/c]'
  run "$ANFS" show lgat/c
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "lgat/c" ]
  [ "${lines[1]}" = $'stacks\tcore/a\t-\t-\tcore/b' ]
  [ "${lines[2]}" = $'stacks\tcore/b\t-\t-\tlgat/c' ]
  [ "${lines[3]}" = $'packages\tp/a\t-\t-\tcore/a' ]
  [ "${lines[4]}" = $'packages\tp/b\t-\t-\tcore/b' ]
  [ "${lines[5]}" = $'packages\tp/c\t-\t-\tlgat/c' ]
}

# --- install -------------------------------------------------------------------------------------

@test "install: the tools in kind order, a kind's resources at once, then the statuses" {
  run "$ANFS" install -y lgat/app </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"anfs install lgat/app (with core/base):"* ]]
  run cat "$LOG"
  [ "${lines[0]}" = "ppm install -y stack/git stack/ruby" ]
  [ "${lines[1]}" = "psm install -y core/s1" ]
  [ "${lines[2]}" = "wsm install -y lgat/" ]
  [ "${lines[3]}" = "pcm install -y core/ui core/db" ]
  [ "${lines[4]}" = "pmm install -y core/vm" ]
  [ "${lines[5]}" = "pcm up core/ui" ]
  [ "${lines[6]}" = "pmm stop core/vm" ]
  [ "${lines[7]}" = "wsm repo install lgat/" ]
  [ "${#lines[@]}" -eq 8 ]
  # a record for the stack and one for what it depends on
  [ -f "$RECORDS/lgat/app.yml" ]
  [ -f "$RECORDS/core/base.yml" ]
  [ "$(yq -r '.stack + " " + .version + " " + (.build | tostring)' "$RECORDS/lgat/app.yml")" = "lgat/app 0.2.0 false" ]
  [ "$(yq -r '.resources[] | select(.resource == "stack/git") | .from' "$RECORDS/lgat/app.yml")" = core/base ]
}

@test "install: before is true for what was there, and never flips to false on a re-run" {
  have ppm stack/git
  run "$ANFS" install -y lgat/app </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed: stack/git"* ]]
  grep -qx "ppm install -y stack/ruby" "$LOG"
  b() { yq -r ".resources[] | select(.resource == \"$2\") | .before" "$RECORDS/$1.yml"; }
  [ "$(b lgat/app stack/git)" = true ]
  [ "$(b lgat/app stack/ruby)" = false ]
  [ "$(b core/base stack/git)" = true ]
  : > "$LOG"
  run "$ANFS" install -y lgat/app </dev/null
  [ "$status" -eq 0 ]
  # nothing missing: no install, the statuses again
  ! grep -q " install -y\| install core" "$LOG"
  [ "$(b lgat/app stack/git)" = true ]
  [ "$(b lgat/app stack/ruby)" = false ]
  [ "$(yq -r '.resources | length' "$RECORDS/lgat/app.yml")" = 7 ]
}

@test "install: what another stack's record holds is not 'before'" {
  run "$ANFS" install -y core/base </dev/null
  [ "$status" -eq 0 ]
  stack lgat other <<<'packages: [stack/git]'
  run "$ANFS" install -y lgat/other </dev/null
  [ "$status" -eq 0 ]
  [ "$(yq -r '.resources[0].before' "$RECORDS/lgat/other.yml")" = false ]
}

@test "install: a tool that is not installed is 69, before anything runs" {
  rm "$HOME/.local/bin/pmm"
  run "$ANFS" install -y lgat/app </dev/null
  [ "$status" -eq 69 ]
  [[ "$output" == *"ppm install core/pmm"* ]]
  [ ! -s "$LOG" ]
  [ ! -d "$RECORDS" ]
}

@test "install --build: only ppm and psm, no status; recorded" {
  rm "$HOME/.local/bin/pmm" "$HOME/.local/bin/pcm"
  run "$ANFS" install -y --build lgat/app </dev/null
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [ "${lines[0]}" = "ppm install -y stack/git stack/ruby" ]
  [ "${lines[1]}" = "psm install -y core/s1" ]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(yq -r '.build' "$RECORDS/lgat/app.yml")" = true ]
  [ "$(yq -r '[.resources[].kind] | unique | join(" ")' "$RECORDS/lgat/app.yml")" = "packages skills" ]
}

@test "install: a source is 64, with the hint; -t takes only host" {
  run "$ANFS" install -y lgat </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"did you mean anfs src install lgat"* ]]
  run "$ANFS" install -y -t container:web lgat/app </dev/null
  [ "$status" -eq 64 ]
  [[ "$output" == *"plan 04"* ]]
  run "$ANFS" install -y -t host core/base </dev/null
  [ "$status" -eq 0 ]
}

@test "install: a failed tool leaves the record of what ran" {
  printf '#!/bin/bash\n[ "$1" = list ] && { echo "[]"; exit 0; }\necho "pcm $*" >> "$LOG"; exit 1\n' > "$HOME/.local/bin/pcm"
  run "$ANFS" install -y lgat/app </dev/null
  [ "$status" -eq 1 ]
  [ "$(yq -r '.resources[] | select(.kind == "packages") | .resource' "$RECORDS/lgat/app.yml" | wc -l | tr -d ' ')" = 2 ]
}

@test "spaces: a prefix is installed when every space under it is, partial when some are" {
  stack lgat sp <<'YML'
spaces: [lgat/, lgat/main/tech, other/x]
YML
  printf 'lgat/main/tech\nlgat/main/org\nother/x\n' > "$ST/wsm.spaces"
  run "$ANFS" show lgat/sp </dev/null
  [[ "$output" == *$'spaces\tlgat/\t-\t-'* ]]
  have wsm lgat/main/tech
  run "$ANFS" show lgat/sp </dev/null
  [[ "$output" == *$'spaces\tlgat/\t-\tpartial'* ]]
  [[ "$output" == *$'spaces\tlgat/main/tech\t-\tinstalled'* ]]
  # one wsm install for every space still missing; a partial prefix is installed again
  run "$ANFS" install -y lgat/sp </dev/null
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [ "$output" = "wsm install -y lgat/ other/x" ]
  run "$ANFS" show lgat/sp </dev/null
  [[ "$output" == *$'spaces\tlgat/\t-\tinstalled'* ]]
  run "$ANFS" list </dev/null
  [[ "$output" == *$'lgat/sp\tinstalled'* ]]
}

# --- remove --------------------------------------------------------------------------------------

@test "remove: only what this stack installed and no other record holds, in reverse order" {
  have ppm stack/git
  run "$ANFS" install -y lgat/app </dev/null
  [ "$status" -eq 0 ]
  : > "$LOG"
  run "$ANFS" remove -y lgat/app </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep   packages stack/git: there before lgat/app"* ]]
  [[ "$output" == *"keep   skills core/s1: core/base holds it"* ]]
  run cat "$LOG"
  [ "${lines[0]}" = "pmm remove -y core/vm" ]
  [ "${lines[1]}" = "pcm remove -y core/db core/ui" ]
  [ "${lines[2]}" = "wsm remove -y lgat/" ]
  [ "${lines[3]}" = "ppm remove -y stack/ruby" ]
  [ "${#lines[@]}" -eq 4 ]
  [ ! -f "$RECORDS/lgat/app.yml" ]
  [ -f "$RECORDS/core/base.yml" ]
}

@test "remove: a resource removed by hand is skipped" {
  run "$ANFS" install -y core/base </dev/null
  "$HOME/.local/bin/psm" remove core/s1
  : > "$LOG"
  run "$ANFS" remove -y base </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep   skills core/s1: already gone"* ]]
  run cat "$LOG"
  [ "$output" = "ppm remove -y stack/git" ]
  [ ! -f "$RECORDS/core/base.yml" ]
}

@test "remove: a stack that is not installed is 1" {
  run "$ANFS" remove -y lgat/app </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"not installed"* ]]
}

# --- list, show, path ----------------------------------------------------------------------------

@test "list: every stack, installed, partial or -" {
  run "$ANFS" list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'lgat/app\t-\t0.2.0' ]
  [ "${lines[1]}" = $'core/base\t-\t0.1.0' ]
  "$ANFS" install -y core/base </dev/null >/dev/null
  run "$ANFS" ls
  [ "${lines[1]}" = $'core/base\tinstalled\t0.1.0' ]
  "$HOME/.local/bin/ppm" remove stack/git
  ANFS_TABLE= run "$ANFS" list --json
  [ "$status" -eq 0 ]
  [ "$(yq -p json -r '.[] | select(.stack == "core/base") | .status' <<< "$output")" = partial ]
  [ "$(yq -p json -r '.[0] | keys | join(" ")' <<< "$output")" = "stack status version" ]
}

@test "list on a terminal: the header" {
  ANFS_TABLE=aligned run "$ANFS" list
  [[ "${lines[0]}" == "STACK"*"STATUS"*"VERSION" ]]
}

@test "show: declared and actual, who brought it in; --json keys" {
  have pcm core/ui stopped
  run "$ANFS" show app
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "lgat/app 0.2.0: the app" ]
  [[ "$output" == *$'containers\tcore/ui\trunning\tstopped\tlgat/app'* ]]
  [[ "$output" == *$'skills\tcore/s1\t-\t-\tcore/base'* ]]
  ANFS_TABLE= run "$ANFS" show --json lgat/app
  [ "$status" -eq 0 ]
  [ "$(yq -p json -r '.[0] | keys | join(" ")' <<< "$output")" = "kind resource declared actual from" ]
  [ "$(yq -p json -r '.[] | select(.resource == "core/ui") | .actual' <<< "$output")" = stopped ]
}

@test "path: the stack's directory" {
  run "$ANFS" path base
  [ "$status" -eq 0 ]
  [ "$output" = "$SOURCES/core/stacks/base" ]
}

@test "src list shows stacks in PROVIDES" {
  ANFS_TABLE= run "$ANFS" src list --json
  [ "$status" -eq 0 ]
  [[ "$(yq -p json -r '.[] | select(.source == "core") | .provides | join(" ")' <<< "$output")" == *stacks* ]]
}

@test "install and remove both ask: a stack is a group" {
  run "$ANFS" install lgat/app </dev/null
  [ "$status" -eq 77 ]
  [[ "$output" == *"pass -y"* ]]
  [ ! -s "$LOG" ]
  run "$ANFS" install -y lgat/app </dev/null
  [ "$status" -eq 0 ]
  grep -qx "ppm install -y stack/git stack/ruby" "$LOG"
  run "$ANFS" install --help
  [[ "$output" == *"--yes"* ]]
  : > "$LOG"
  run "$ANFS" remove lgat/app </dev/null
  [ "$status" -eq 77 ]
  [[ "$output" == *"pass -y"* ]]
  [ ! -s "$LOG" ]
}

@test "src remove asks before taking a source off the list" {
  printf 'file:///x/mine.git  mine\n' >> "$HOME/.config/anfs/user.list"
  run "$ANFS" src remove mine </dev/null
  [ "$status" -eq 77 ]
  grep -q ' mine$' "$HOME/.config/anfs/user.list"
  run "$ANFS" src rm -y mine </dev/null
  [ "$status" -eq 0 ]
  ! grep -q ' mine$' "$HOME/.config/anfs/user.list"
}

# --- anfs src install ----------------------------------------------------------------------------

@test "src install: several sources' spaces go to one wsm install" {
  mkdir -p "$SOURCES/core/spaces" "$SOURCES/lgat/spaces"
  run "$ANFS" src install -y lgat core </dev/null
  [ "$status" -eq 0 ]
  run grep '^wsm' "$LOG"
  [ "$output" = "wsm install -y lgat/ core/" ]
}

@test "src install: every resource of a source, tool by tool" {
  mkdir -p "$SOURCES/core/skills"
  run "$ANFS" src install -y core </dev/null
  [ "$status" -eq 0 ]
  run cat "$LOG"
  [ "${lines[0]}" = "ppm install -y core/" ]
  [ "${lines[1]}" = "psm install -y core/" ]
  : > "$LOG"
  # a whole source: asked about
  run "$ANFS" src install core </dev/null
  [ "$status" -eq 77 ]
  [ ! -s "$LOG" ]
  run "$ANFS" src install -y core/x </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"src install takes whole sources"* ]]
}

