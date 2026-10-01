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
  export HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  mkdir -p "$HOME/.local/lib" "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources" "$T/bin"
  ln -s "$(cd "$BATS_TEST_DIRNAME/../../anfs/home/.local/lib/anfs" && pwd)" "$HOME/.local/lib/anfs"

  # npx stub: `skills list -g --json` lists nothing; everything else is logged
  cat > "$T/bin/npx" <<'STUB'
#!/usr/bin/env bash
shift 2   # --yes skills@<version>
[[ "$1" == list ]] && { echo '[]'; exit 0; }
echo "$*" >> "$NPX_LOG"
STUB
  chmod +x "$T/bin/npx"
  export NPX_LOG="$T/npx.log" PATH="$T/bin:$PATH"

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

@test "skills ls: a source's skills are listed under its alias" {
  source_dir acme
  skill acme hello
  skill acme bye
  run psm skills ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing  acme"*"bye"* ]]
  [[ "$output" == *"missing  acme"*"hello"* ]]
}

@test "install source/: adds each of its skills for the detected agents" {
  source_dir acme
  skill acme hello
  run psm install acme/
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
