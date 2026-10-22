#!/usr/bin/env bats
# lib/anfs/skill.sh: the skills CLI with a scope (-g or a directory), the agents ppm's trackers
# declare, and what is installed. npx is a stub that logs its arguments and working directory.
# Run: bats packages/anfs/tests/skill.bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home"
  export XDG_STATE_HOME="$HOME/.local/state" ANFS_LOG=off
  unset PPM_STATE_HOME ANFS_SKILLS_CLI_VERSION ANFS_DATA_HOME XDG_DATA_HOME XDG_CONFIG_HOME
  mkdir -p "$HOME" "$T/bin"
  cat > "$T/bin/npx" <<'STUB'
#!/usr/bin/env bash
v="$2"; shift 2
[[ "$1" == list ]] && { echo "${NPX_LIST:-[]}"; exit 0; }
printf '%s|%s|%s\n' "$PWD" "$v" "$*" >> "$NPX_LOG"
STUB
  chmod +x "$T/bin/npx"
  export NPX_LOG="$T/npx.log" PATH="$T/bin:$PATH"
  # shellcheck source=/dev/null
  source "$LIB/paths.sh"
  source "$LIB/log.sh"
  source "$LIB/skill.sh"
}

@test "cli -g: -g before the first option, the version from ANFS_SKILLS_CLI_VERSION" {
  anfs_skill_cli -g add /x -y -s a -a pi
  ANFS_SKILLS_CLI_VERSION=1.7.4 anfs_skill_cli -g remove a b -y -a pi
  anfs_skill_cli -g update
  run cat "$NPX_LOG"
  [ "${lines[0]}" = "$PWD|skills@latest|add /x -g -y -s a -a pi" ]
  [ "${lines[1]}" = "$PWD|skills@1.7.4|remove a b -g -y -a pi" ]
  [ "${lines[2]}" = "$PWD|skills@latest|update -g" ]
}

@test "cli <dir>: no -g, run in that directory, the caller's cwd unchanged" {
  mkdir -p "$T/space"
  local here="$PWD"
  anfs_skill_cli "$T/space" add /x -y -s a -a pi
  [ "$PWD" = "$here" ]
  run cat "$NPX_LOG"
  [ "$output" = "$(cd "$T/space" && pwd)|skills@latest|add /x -y -s a -a pi" ]
  anfs_skill_unlink "$T/space" claude-code a b
  anfs_skill_remove "$T/space" a   # not installed (the list is empty): nothing run
  run cat "$NPX_LOG"
  [[ "${lines[1]}" == *"|remove a b -y -a claude-code" ]]
  [ "${#lines[@]}" -eq 2 ]
}

@test "agents: meta.agent of installed ppm packages, one or a list, csv and sorted" {
  local s="$HOME/.local/share/anfs/sources/ai/packages" t="$XDG_STATE_HOME/ppm/installed/ai"
  mkdir -p "$s/pi" "$s/claude" "$s/two" "$s/none" "$t"
  printf 'meta:\n  agent: pi\n' > "$s/pi/package.yml"
  printf 'meta:\n  agent: [opencode, claude-code]\n' > "$s/two/package.yml"
  echo 'version: 0.1.0' > "$s/none/package.yml"
  run anfs_skill_agents
  [ -z "$output" ]
  for p in pi two none; do echo 'version: 0.1.0' > "$t/$p.yml"; done
  run anfs_skill_agents
  [ "$output" = "claude-code,opencode,pi" ]
  run anfs_skill_package_agents ai/two
  [ "$output" = $'opencode\nclaude-code' ]
  run anfs_skill_package_agents ai/gone
  [ -z "$output" ]
}

@test "status: ok for every agent, partial for some, missing; unknown ids are not ok" {
  export NPX_LIST='[{"name":"a","agents":["Pi","Claude Code"],"source":""},{"name":"b","agents":["Pi"]}]'
  anfs_skill_load -g
  [ "$(anfs_skill_status a pi,claude-code)" = ok ]
  [ "$(anfs_skill_status b pi,claude-code)" = partial ]
  [ "$(anfs_skill_status c pi)" = missing ]
  [ "$(anfs_skill_status a nosuch)" = partial ]
}

@test "sync_rows: adds what is missing, skips what is there, forces local paths, waits without agents" {
  mkdir -p "$T/space"
  export NPX_LIST='[{"name":"a","agents":["Pi"]}]'
  anfs_skill_load "$T/space"
  anfs_skill_sync_rows "$T/space" false pi < <(printf '%s\n' "x|/s|a,b|" "y|o/r|*|" "z|/l|a|")
  [ "$ANFS_SKILL_SYNCED" = 2 ]
  [ "$ANFS_SKILL_CURRENT" = 1 ]
  run cat "$NPX_LOG"
  [[ "${lines[0]}" == *"|add /s -y -s b -a pi" ]]
  [[ "${lines[1]}" == *"|add o/r -y -s * -a pi" ]]
  : > "$NPX_LOG"
  anfs_skill_sync_rows "$T/space" true pi <<< "z|/l|a|"
  [[ "$(cat "$NPX_LOG")" == *"|add /l -y -s a -a pi" ]]
  anfs_skill_sync_rows "$T/space" true "" <<< "z|/l|a|"
  [ "$ANFS_SKILL_WAITING" = 1 ]
  [ "$ANFS_SKILL_SYNCED" = 0 ]
}

@test "cli: an empty, relative or missing scope is refused, nothing run" {
  run anfs_skill_cli "" list --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a directory to install skills in: ''"* ]]
  run anfs_skill_cli relative add /x -y
  [ "$status" -eq 1 ]
  run anfs_skill_cli "$T/nope" add /x -y
  [ "$status" -eq 1 ]
  run anfs_skill_remove "" a
  [ "$status" -eq 1 ]
  [ ! -e "$NPX_LOG" ]
}

@test "has: a universal agent the list leaves out counts when the copy is in .agents/skills" {
  export NPX_LIST='[{"name":"a","agents":["Claude Code"],"path":"/s/.agents/skills/a"},{"name":"b","agents":["Claude Code"],"path":"/s/.claude/skills/b"}]'
  anfs_skill_load -g
  [ "$(anfs_skill_status a pi,claude-code)" = ok ]
  [ "$(anfs_skill_status a opencode)" = ok ]
  [ "$(anfs_skill_status b pi,claude-code)" = partial ]
  [ "$(anfs_skill_status a hermes-agent)" = partial ]
}

@test "remove: -a for the agents each is on, never unscoped; the shared copy and lock entry go, nothing else" {
  mkdir -p "$T/space/.agents/skills/a" "$T/space/skills/a" "$HOME/.agents/skills/a" "$HOME/agent/skills/a"
  printf '{"version":1,"skills":{"a":{},"keep":{}}}\n' > "$T/space/skills-lock.json"
  printf '{"version":3,"skills":{"a":{},"keep":{}},"dismissed":{}}\n' > "$HOME/.agents/.skill-lock.json"
  echo mine > "$T/space/skills/a/SKILL.md"
  echo mine > "$HOME/agent/skills/a/SKILL.md"
  export NPX_LIST='[{"name":"a","agents":["Claude Code","Pi"]}]'
  anfs_skill_remove "$T/space" a gone
  [ "${ANFS_SKILL_REMOVED[*]}" = a ]
  anfs_skill_remove -g a
  run cat "$NPX_LOG"
  [[ "${lines[0]}" == *"|remove a -y -a claude-code pi" ]]
  [[ "${lines[1]}" == *"|remove a -g -y -a claude-code pi" ]]
  [ ! -e "$T/space/.agents/skills/a" ] && [ ! -e "$HOME/.agents/skills/a" ]
  [ -f "$T/space/skills/a/SKILL.md" ]
  [ -f "$HOME/agent/skills/a/SKILL.md" ]
  [ "$(yq -p json -r '.skills | keys | join(",")' "$T/space/skills-lock.json")" = keep ]
  [ "$(yq -p json -r '.skills | keys | join(",")' "$HOME/.agents/.skill-lock.json")" = keep ]
  run anfs_skill_remove "" a
  [ "$status" -eq 1 ]
}
