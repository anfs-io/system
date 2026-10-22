#!/usr/bin/env bats
# psm over anfs sources: every source with skills/ is a skill repo named by its alias, agents come
# from installed ppm packages declaring meta.agent, and the skills CLI is stubbed (npx logs its
# arguments) so nothing is installed and nothing touches the network.
# Run: bats packages/psm/tests/

setup() {
  PSM="$BATS_TEST_DIRNAME/../home/.local/bin/psm"
  T="$BATS_TEST_TMPDIR"
  HOME="$T/home"
  XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  unset ANFS_CONFIG_HOME ANFS_DATA_HOME ANFS_CACHE_HOME PSM_CONFIG_HOME PPM_STATE_HOME
  unset ANFS_SKILLS_CLI_VERSION PSM_CLI_VERSION
  export HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  export ANFS_LOG=off   # no log file from tests (lib/anfs/log.sh)
  mkdir -p "$HOME/.local/lib" "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources" "$T/bin"
  ln -s "$(cd "$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs" && pwd)" "$HOME/.local/lib/anfs"

  # npx stub: `skills list -g --json` lists $NPX_LIST (nothing by default); everything else is logged
  cat > "$T/bin/npx" <<'STUB'
#!/usr/bin/env bash
echo "$2" > "$NPX_VER"
shift 2   # --yes skills@<version>
[[ "$1" == list ]] && { echo "${NPX_LIST:-[]}"; exit 0; }
echo "$*" >> "$NPX_LOG"
STUB
  chmod +x "$T/bin/npx"
  export NPX_LOG="$T/npx.log" NPX_VER="$T/npx.ver" PATH="$T/bin:$PATH"

  # An installed agent package: ai/pi with meta.agent: pi
  source_dir ai
  mkdir -p "$T/srcs/ai/packages/pi" "$XDG_STATE_HOME/ppm/installed/ai"
  printf 'meta:\n  agent: pi\n' > "$T/srcs/ai/packages/pi/package.yml"
  echo 'version: 0.1.0' > "$XDG_STATE_HOME/ppm/installed/ai/pi.yml"
}

# An anfs source <alias> at $T/srcs/<alias>, listed and linked like `anfs src update` does
source_dir() {
  mkdir -p "$T/srcs/$1"
  ln -sfn "$T/srcs/$1" "$HOME/.local/share/anfs/sources/$1"
  printf '%s  %s\n' "$T/srcs/$1" "$1" >> "$HOME/.config/anfs/user.list"
}

skill() {
  mkdir -p "$T/srcs/$1/skills/$2"
  printf -- '---\nname: %s\ndescription: test\n---\n' "$2" > "$T/srcs/$1/skills/$2/SKILL.md"
}

psm() { "$PSM" "$@"; }

@test "ls: a source's skills are listed as source/skill" {
  source_dir acme
  skill acme hello
  skill acme bye
  run psm ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme/bye"$'\t'"missing"* ]]
  [[ "$output" == *"acme/hello"$'\t'"missing"* ]]
  ANFS_TABLE=aligned run psm ls
  [[ "${lines[0]}" == "SKILL"*"STATUS" ]]
  run psm ls --json
  run yq -p json -r '.[] | .skill + " " + .status + " " + .config + " " + (.repo | test("skills$") | tostring)' <<< "$output"
  [ "${lines[0]}" = "acme/bye missing acme true" ]
}

@test "repo ls: REPOSITORY STATUS CONFIG" {
  source_dir acme
  skill acme hello
  ANFS_TABLE=aligned run psm repo ls
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "REPOSITORY"*"STATUS"*"CONFIG" ]]
  run psm repo ls --json
  run yq -p json -r '.[0] | keys | join(" ")' <<< "$output"
  [ "$output" = "repository status config" ]
}

@test "remove and prune are top-level; skills is no group" {
  run psm remove hello </dev/null
  [ "$status" -eq 77 ]
  [ ! -s "$NPX_LOG" ]
  export NPX_LIST='[{"name":"hello","agents":["Pi"]}]'
  run psm remove -y hello
  [ "$status" -eq 0 ]
  [ "$(cat "$NPX_LOG")" = "remove hello -g -y -a pi" ]
  unset NPX_LIST
  run psm prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to prune"* ]]
  run psm skills ls
  [ "$status" -eq 64 ]
}

@test "install source/: adds each of its skills for the detected agents" {
  source_dir acme
  skill acme hello
  run psm install acme/ </dev/null
  [ "$status" -eq 77 ]
  run psm install -y acme/
  [ "$status" -eq 0 ]
  run cat "$NPX_LOG"
  [[ "$output" == "add $(cd -P "$T/srcs/acme/skills" && pwd) -g -y -s hello -a pi" ]]
}

@test "install source/skill: only that skill" {
  source_dir acme
  skill acme hello
  skill acme bye
  run psm install acme/bye
  [ "$status" -eq 0 ]
  run cat "$NPX_LOG"
  [[ "$output" == *"-s bye -a pi" ]]
  [[ "$output" != *"hello"* ]]
}

@test "install: an unknown source or skill fails" {
  source_dir acme
  skill acme hello
  run psm install nope/
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an anfs source with skills"* ]]
  run psm install acme/nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"no skill 'nope' in acme"* ]]
}

@test "sync: a source alias works as a config name" {
  source_dir acme
  skill acme hello
  run psm sync acme
  [ "$status" -eq 0 ]
  [[ "$(cat "$NPX_LOG")" == *"-s hello -a pi" ]]
}

@test "sources without skills/ are not skill repos" {
  source_dir bare
  run psm install bare/
  [ "$status" -ne 0 ]
}

@test "implode: removes psm's dirs and empty agent skills dirs, keeps agent files" {
  mkdir -p "$HOME/.config/psm" "$HOME/.pi/agent/skills" "$HOME/.keep/skills"
  echo keep > "$HOME/.keep/settings"
  run psm implode -y
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.config/psm" ]
  [ ! -e "$HOME/.pi" ]
  [ -f "$HOME/.keep/settings" ]
}

@test "sync: no agent installed yet is waiting, not a failure" {
  rm "$XDG_STATE_HOME/ppm/installed/ai/pi.yml"
  source_dir acme
  skill acme hello
  run psm sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"No agent installed yet: 1 skill source(s) sync when an agent package is installed"* ]]
  [ ! -s "$NPX_LOG" ]
}

@test "prune and agents remove ask before removing; -y removes" {
  export NPX_LIST='[{"name":"stray","agents":["Pi"],"source":""}]'
  run psm prune </dev/null
  [ "$status" -eq 77 ]
  [[ "$output" == *"undeclared  stray"* ]]
  [ ! -s "$NPX_LOG" ]
  run psm prune -y
  [ "$status" -eq 0 ]
  [[ "$(cat "$NPX_LOG")" == "remove stray -g -y -a pi" ]]
  : > "$NPX_LOG"
  run psm agents remove pi </dev/null
  [ "$status" -eq 77 ]
  [ ! -s "$NPX_LOG" ]
  run psm agents remove -y pi
  [ "$status" -eq 0 ]
  [[ "$(cat "$NPX_LOG")" == "remove stray -g -y -a pi" ]]
}

@test "repo remove asks before deleting the config" {
  mkdir -p "$T/mine/one"
  printf -- '---\nname: one\ndescription: test\n---\n' > "$T/mine/one/SKILL.md"
  psm repo add "$T/mine" >/dev/null
  local f
  f=$(ls "$HOME/.config/psm/"*.yml)
  run psm repo remove "$T/mine" </dev/null
  [ "$status" -eq 77 ]
  [ -f "$f" ]
  run psm repo rm -y "$T/mine"
  [ "$status" -eq 0 ]
  [ ! -e "$f" ]
}

@test "the CLI's version is ANFS_SKILLS_CLI_VERSION (latest by default); PSM_CLI_VERSION is not read" {
  source_dir acme
  skill acme hello
  psm sync >/dev/null
  [ "$(cat "$NPX_VER")" = skills@latest ]
  PSM_CLI_VERSION=1.0.0 psm sync >/dev/null
  [ "$(cat "$NPX_VER")" = skills@latest ]
  ANFS_SKILLS_CLI_VERSION=1.7.4 psm sync >/dev/null
  [ "$(cat "$NPX_VER")" = skills@1.7.4 ]
}

@test "prune keeps what a * repo installed (the CLI's source), whatever the path" {
  mkdir -p "$HOME/.config/psm"
  printf 'sources:\n  - repo: o/r\n    skills: ["*"]\n' > "$HOME/.config/psm/r.yml"
  export NPX_LIST='[{"name":"x","agents":["Pi"],"source":"o/r","path":"/h/.agents/skills/x"}]'
  run psm prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to prune"* ]]
}

@test "every remove carries -a (an unscoped one sweeps ~/agent/skills/<name>); the shared copy goes, the user's files stay" {
  mkdir -p "$HOME/.agents/skills/a" "$HOME/agent/skills/a" "$HOME/.config/psm"
  echo copy > "$HOME/.agents/skills/a/SKILL.md"
  echo mine > "$HOME/agent/skills/a/SKILL.md"
  export NPX_LIST='[{"name":"a","agents":["Claude Code","OpenCode"]},{"name":"b","agents":["Pi"]},{"name":"c","agents":["Some Agent"]}]'
  psm remove -y a b c >/dev/null 2>&1
  psm prune -y >/dev/null 2>&1
  psm agents remove -y pi >/dev/null 2>&1
  psm implode -y >/dev/null 2>&1
  run grep -c . "$NPX_LOG"
  [ "$output" -ge 4 ]
  run grep -v -- ' -a ' "$NPX_LOG"
  [ -z "$output" ]
  [ "$(head -1 "$NPX_LOG")" = "remove a b -g -y -a claude-code opencode pi" ]
  [ ! -e "$HOME/.agents/skills/a" ]
  [ "$(cat "$HOME/agent/skills/a/SKILL.md")" = mine ]
}
