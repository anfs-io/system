#!/usr/bin/env bats
# skills: in space.yml and wsm skill: a space's skills installed into its directory by the skills
# CLI (lib/anfs/skill.sh), for the agents ppm installed. npx is a stub: it logs its working
# directory and arguments, and `list` answers $NPX_LIST. No network, nothing real installed.
# Run: bats packages/wsm/tests/skills.bats

load helper
setup() {
  wsm_setup
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/npx" <<'STUB'
#!/usr/bin/env bash
shift 2   # --yes skills@<version>
[[ "$1" == list ]] && { echo "${NPX_LIST:-[]}"; exit 0; }
echo "$PWD|$*" >> "$NPX_LOG"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/npx"
  export NPX_LOG="$BATS_TEST_TMPDIR/npx.log" PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  mksource acme >/dev/null
  SD="$BATS_TEST_TMPDIR/srcs/acme/spaces"
  agent pi pi
}

# An installed ppm package ai/<pkg> declaring meta.agent: <id>
agent() {
  local s="$BATS_TEST_TMPDIR/srcs/ai/packages/$1"
  [[ -e "$HOME/.local/share/anfs/sources/ai" ]] || mksource ai >/dev/null
  mkdir -p "$s" "$XDG_STATE_HOME/ppm/installed/ai"
  printf 'meta:\n  agent: %s\n' "$2" > "$s/package.yml"
  echo 'version: 0.1.0' > "$XDG_STATE_HOME/ppm/installed/ai/$1.yml"
}

# A skill <name> in the source at spaces/<dir>/<name>/SKILL.md
skill_file() {
  mkdir -p "$SD/$1/$2"
  printf -- '---\nname: %s\ndescription: t\n---\n' "$2" > "$SD/$1/$2/SKILL.md"
}

@test "install: a path's skills by name, a remote's as *, in the space's directory" {
  skill_file tech/skills hello
  skill_file tech/skills bye
  space_def acme tech <<'EOF'
skills:
  - repo: ./skills
  - repo: owner/repo
  - repo: other/repo
    skills: [one]
EOF
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  local dir; dir=$(cd -P "$SD/tech/skills" && pwd)
  run cat "$NPX_LOG"
  [ "${lines[0]}" = "$HOME/spaces/acme/tech|add $dir -y -s bye -s hello -a pi" ]
  [ "${lines[1]}" = "$HOME/spaces/acme/tech|add owner/repo -y -s * -a pi" ]
  [ "${lines[2]}" = "$HOME/spaces/acme/tech|add other/repo -y -s one -a pi" ]
}

@test "install: the skills come after the files; a skill dir copied in the source is not linked as a file by itself" {
  skill_file tech/skills hello
  space_def acme tech <<<'skills: [{repo: ./skills}]'
  wsm install acme/tech >/dev/null
  [ -L "$HOME/spaces/acme/tech/space.yml" ]
  # the skill's own file is a space file too (it is in spaces/): linked like any
  [ -L "$HOME/spaces/acme/tech/skills/hello/SKILL.md" ]
}

@test "a child space's install does not run its parent's skills, nor the parent's its child's" {
  skill_file org/skills hello
  space_def acme org <<<'skills: [{repo: ./skills}]'
  space_def acme org/team <<<'repositories: []'
  wsm install acme/org/team >/dev/null
  [ ! -s "$NPX_LOG" ]
  wsm install acme/org >/dev/null
  run cat "$NPX_LOG"
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "$HOME/spaces/acme/org|add "* ]]
}

@test "no agent yet: waiting, exit 0, nothing run" {
  rm "$XDG_STATE_HOME/ppm/installed/ai/pi.yml"
  space_def acme tech <<<'skills: [{repo: owner/repo}]'
  run wsm install acme/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"skills: waiting for an agent"* ]]
  [ ! -s "$NPX_LOG" ]
  run wsm skill ls --json
  [ "$(yq -p json -r '.[0].status' <<< "$output")" = waiting ]
}

@test "no npx: a warning, not a failure; a space without skills never asks for it" {
  rm "$BATS_TEST_TMPDIR/bin/npx"
  local p; p=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'mise\|node' | paste -sd: -)
  space_def acme plain <<<'repositories: []'
  PATH="$p" run wsm install acme/plain
  [ "$status" -eq 0 ]
  [[ "$output" != *npx* ]]
  space_def acme tech <<<'skills: [{repo: owner/repo}]'
  PATH="$p" MISE_DISABLE=1 run wsm install acme/tech
  [ "$status" -eq 0 ]
  [[ "$output" == *"npx not found"* ]]
}

@test "a missing skills directory or a repo-less entry fails the space's install" {
  space_def acme tech <<<'skills: [{repo: ./nope}]'
  run wsm install acme/tech
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such skills directory in acme/tech: ./nope"* ]]
}

@test "skill ls: SKILL STATUS REPO; statuses from the CLI; null when not installed" {
  skill_file tech/skills hello
  skill_file tech/skills bye
  space_def acme tech <<'EOF'
skills:
  - repo: ./skills
  - repo: owner/repo
EOF
  space_def acme other <<<'skills: [{repo: o/r, skills: [x]}]'
  ANFS_TABLE=aligned run wsm skill ls
  [[ "${lines[0]}" == "SKILL"*"STATUS"*"REPO" ]]
  wsm install acme/tech >/dev/null
  export NPX_LIST='[{"name":"hello","agents":["Pi"]}]'
  run wsm skill ls --json
  [ "$status" -eq 0 ]
  run yq -p json -r '.[] | .skill + " " + (.status // "null") + " " + .space + " " + .name' <<< "$output"
  [ "${lines[0]}" = "acme/other/x null acme/other x" ]
  [ "${lines[1]}" = "acme/tech/bye missing acme/tech bye" ]
  [ "${lines[2]}" = "acme/tech/hello ok acme/tech hello" ]
  [ "${lines[3]}" = "acme/tech/* * acme/tech *" ]
  agent claude claude-code
  run wsm skill ls acme/tech --json
  [ "$(yq -p json -r '.[] | select(.name == "hello") | .status' <<< "$output")" = partial ]
}

@test "skill remove: asks; -y removes the declared, installed ones; a name; never an undeclared one" {
  space_def acme tech <<<'skills: [{repo: o/r, skills: [a, b]}]'
  wsm install acme/tech >/dev/null
  export NPX_LIST='[{"name":"a","agents":["Pi"]},{"name":"b","agents":["Pi"]},{"name":"mine","agents":["Pi"]}]'
  : > "$NPX_LOG"
  run wsm skill remove acme/tech </dev/null
  [ "$status" -eq 77 ]
  [ ! -s "$NPX_LOG" ]
  run wsm skill rm -y acme/tech/b
  [ "$status" -eq 0 ]
  [ "$(cat "$NPX_LOG")" = "$HOME/spaces/acme/tech|remove b -y" ]
  run wsm skill rm -y acme/tech/mine
  [ "$status" -eq 1 ]
  [[ "$output" == *"acme/tech declares no skill mine"* ]]
  : > "$NPX_LOG"
  run wsm skill rm -y acme/tech
  [ "$status" -eq 0 ]
  [ "$(cat "$NPX_LOG")" = "$HOME/spaces/acme/tech|remove a b -y" ]
}

@test "skill remove of a remote *: what skills-lock.json says came from that repo" {
  space_def acme tech <<<'skills: [{repo: o/r}]'
  wsm install acme/tech >/dev/null
  printf '{"version":1,"skills":{"x":{"source":"o/r"},"y":{"source":"else/where"}}}\n' > "$HOME/spaces/acme/tech/skills-lock.json"
  export NPX_LIST='[{"name":"x","agents":["Pi"]},{"name":"y","agents":["Pi"]}]'
  : > "$NPX_LOG"
  wsm skill rm -y acme/tech >/dev/null
  [ "$(cat "$NPX_LOG")" = "$HOME/spaces/acme/tech|remove x -y" ]
}

@test "wsm remove: the space's skills first, the empty lock and skill dirs go, a skill it did not declare stays" {
  space_def acme tech <<<'skills: [{repo: o/r, skills: [a]}]'
  wsm install acme/tech >/dev/null
  local h="$HOME/spaces/acme/tech"
  mkdir -p "$h/.agents/skills" "$h/.claude/skills"
  printf '{"version":1,"skills":{}}\n' > "$h/skills-lock.json"
  export NPX_LIST='[{"name":"a","agents":["Pi"]},{"name":"mine","agents":["Pi"]}]'
  : > "$NPX_LOG"
  run wsm remove -y acme/tech
  [ "$status" -eq 0 ]
  [ "$(cat "$NPX_LOG")" = "$h|remove a -y" ]
  [ ! -e "$h" ]
}

@test "remove keeps what the user put there: a lock with skills, a non-empty skill dir" {
  space_def acme tech <<<'skills: [{repo: o/r, skills: [a]}]'
  wsm install acme/tech >/dev/null
  local h="$HOME/spaces/acme/tech"
  mkdir -p "$h/.agents/skills/mine"
  echo x > "$h/.agents/skills/mine/SKILL.md"
  printf '{"version":1,"skills":{"mine":{"source":"x/y"}}}\n' > "$h/skills-lock.json"
  wsm remove -y acme/tech >/dev/null
  [ -f "$h/skills-lock.json" ]
  [ -f "$h/.agents/skills/mine/SKILL.md" ]
}

@test "add steps around what the skills CLI wrote: the lock and the copies it names" {
  space_def acme tech <<<'skills: [{repo: o/r, skills: [hello]}]'
  wsm install acme/tech >/dev/null
  local h="$HOME/spaces/acme/tech"
  mkdir -p "$h/.agents/skills/hello" "$h/.claude/skills/hello" "$h/.claude/notes"
  echo x > "$h/.agents/skills/hello/SKILL.md"
  echo x > "$h/.claude/skills/hello/SKILL.md"
  echo mine > "$h/.claude/notes/n.md"
  printf '{"version":1,"skills":{"hello":{"source":"o/r"}}}\n' > "$h/skills-lock.json"
  run wsm add "$h"
  [ "$status" -eq 0 ]
  [ ! -e "$SD/tech/skills-lock.json" ]
  [ ! -e "$SD/tech/.agents" ]
  [ ! -e "$SD/tech/.claude/skills" ]
  [ -f "$SD/tech/.claude/notes/n.md" ]
  run wsm add "$h/skills-lock.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"written by the skills CLI"* ]]
}

@test "implode removes every space's skills" {
  space_def acme a <<<'skills: [{repo: o/r, skills: [x]}]'
  space_def acme b <<<'skills: [{repo: o/r, skills: [y]}]'
  wsm install acme/ -y >/dev/null
  export NPX_LIST='[{"name":"x","agents":["Pi"]},{"name":"y","agents":["Pi"]}]'
  : > "$NPX_LOG"
  wsm implode -y >/dev/null 2>&1
  run sort "$NPX_LOG"
  [ "${lines[0]}" = "$HOME/spaces/acme/a|remove x -y" ]
  [ "${lines[1]}" = "$HOME/spaces/acme/b|remove y -y" ]
}

# --- the ppm callback (install.sh) ---------------------------------------------------------

callback() {
  # As ppm runs it: install.sh sourced, wsm on PATH
  mkdir -p "$BATS_TEST_TMPDIR/wbin"
  ln -sf "$WSM" "$BATS_TEST_TMPDIR/wbin/wsm"
  PATH="$BATS_TEST_TMPDIR/wbin:$PATH" bash -c '
    ppm_fail() { echo "FAIL $*"; return 1; }
    user_message() { :; }
    source "$1/home/.local/lib/anfs/paths.sh"
    source "$1/home/.local/lib/anfs/log.sh"
    source "$2"
    shift 2
    wsm_ppm_changed "$@"' - "$BATS_TEST_DIRNAME/../../anfs" "$BATS_TEST_DIRNAME/../install.sh" "$@"
}

@test "wsm_ppm_changed install: an agent package re-syncs every installed space; another does nothing" {
  space_def acme tech <<<'skills: [{repo: o/r, skills: [x]}]'
  wsm install acme/tech >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/srcs/ai/packages/tool"
  echo 'version: 0.1.0' > "$BATS_TEST_TMPDIR/srcs/ai/packages/tool/package.yml"
  : > "$NPX_LOG"
  run callback install ai/tool
  [ "$status" -eq 0 ]
  [ ! -s "$NPX_LOG" ]
  run callback install ai/tool ai/pi
  [ "$status" -eq 0 ]
  [ "$(cat "$NPX_LOG")" = "$HOME/spaces/acme/tech|add o/r -y -s x -a pi" ]
}

@test "wsm_ppm_changed remove: unlinks only an agent nothing else declares" {
  agent claude claude-code
  agent claude2 claude-code
  space_def acme tech <<<'skills: [{repo: o/r, skills: [x]}]'
  wsm install acme/tech >/dev/null
  export NPX_LIST='[{"name":"x","agents":["Pi","Claude Code"]},{"name":"mine","agents":["Pi"]}]'
  : > "$NPX_LOG"
  # claude2 goes; claude still declares claude-code
  rm "$XDG_STATE_HOME/ppm/installed/ai/claude2.yml"
  run callback remove ai/claude2
  [ "$status" -eq 0 ]
  [ ! -s "$NPX_LOG" ]
  rm "$XDG_STATE_HOME/ppm/installed/ai/pi.yml"
  run callback remove ai/pi
  [ "$status" -eq 0 ]
  [ "$(cat "$NPX_LOG")" = "$HOME/spaces/acme/tech|remove x -y -a pi" ]
}

@test "a space's directory replaced by a link: not installed (the check), so no skills run through it" {
  space_def acme tech <<<'skills: [{repo: o/r}]'
  wsm install acme/tech >/dev/null
  : > "$NPX_LOG"
  mv "$HOME/spaces/acme/tech" "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$HOME/spaces/acme/tech"
  ln -sfn "$SD/tech/space.yml" "$BATS_TEST_TMPDIR/elsewhere/space.yml"
  run wsm skill install acme/tech
  [ "$status" -eq 0 ]
  run wsm skill rm -y acme/tech
  [ ! -s "$NPX_LOG" ]
  [ -z "$(ls_field acme/tech status | grep -v null)" ]
}
