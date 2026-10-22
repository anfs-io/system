#!/usr/bin/env bats
# lib/anfs/config.sh: the config group every tool with settings declares. <tool> config list shows
# each setting the tool's shipped file names, its value and where it came from (env, local,
# shipped, default); get prints one; set and unset write <tool>.local.env, nothing else; list
# --export is for eval; anfs config list --all is every installed tool's.
# Run: bats packages/anfs/tests/config.bats

setup() {
  PKGS="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$PKGS/anfs/home/.local/lib/anfs"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME=$(cd -P "$BATS_TEST_TMPDIR/home" && pwd -P)
  CFG="$HOME/.config"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/lib" "$CFG/anfs" "$CFG/fake"
  ln -s "$LIB" "$HOME/.local/lib/anfs"
  # the shipped files are linked, as ppm links them
  ln -s "$PKGS/anfs/home/.config/anfs/anfs.env" "$CFG/anfs/anfs.env"
  for t in anfs pcm; do ln -s "$PKGS/$t/home/.local/bin/$t" "$HOME/.local/bin/$t"; done
  ln -s "$PKGS/pcm/home/.local/lib/pcm" "$HOME/.local/lib/pcm"

  # A tool of its own on cli.sh with a shipped fake.env
  cat > "$HOME/.local/bin/fake" <<SH
#!/usr/bin/env bash
set -euo pipefail
source "\$HOME/.local/lib/anfs/bash.sh"
source "\$HOME/.local/lib/anfs/paths.sh"
source "\$HOME/.local/lib/anfs/log.sh"
source "\$HOME/.local/lib/anfs/cli.sh"
source "\$HOME/.local/lib/anfs/table.sh"
source "\$HOME/.local/lib/anfs/config.sh"
anfs_tool_paths fake
CLI_TOOL=fake CLI_VERSION=1.0.0
cli_cmd show "Print FAKE_X as the tool sees it"
cmd_show() { echo "FAKE_X=\${FAKE_X:-unset}"; }
anfs_config_declare
cli_standard
cli_dispatch "\$@"
SH
  chmod +x "$HOME/.local/bin/fake"
  cat > "$CFG/fake/fake.env" <<'EOF'
# fake settings: shipped. A prose comment, and one that looks like a line:
# NOT_A=setting
# Seconds to wait
#FAKE_X=120
# The path it uses
#FAKE_DIR=~/fake
# On, by the package
FAKE_ON=1
# Empty default
#FAKE_EMPTY=
EOF
}

# Run a tool in a clean environment: only HOME, PATH and what is given as NAME=value first
t() {
  local -a vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  run env -i HOME="$HOME" PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
    TMPDIR="$BATS_TEST_TMPDIR" ANFS_LOG=off ${vars[@]+"${vars[@]}"} "$@"
}

@test "list: one row per declared setting; FROM default, shipped, local, env" {
  printf 'FAKE_DIR=/srv/x\n' > "$CFG/fake/fake.local.env"
  t FAKE_ON=2 fake config list
  [ "$status" -eq 0 ]
  expected=$(printf '%s\t%s\t%s\n' FAKE_X 120 default FAKE_DIR /srv/x local FAKE_ON 2 env FAKE_EMPTY - default)
  [ "$output" = "$expected" ]
  t fake config list
  [ "${lines[2]}" = "$(printf 'FAKE_ON\t1\tshipped')" ]
}

@test "list: a default's leading ~ is expanded, as the tool gets it; prose comments are not settings" {
  t fake config list
  [[ "$output" != *NOT_A* ]]
  t ANFS_TABLE=json fake config list
  [[ "$output" == *"{\"name\":\"FAKE_DIR\",\"value\":\"$HOME/fake\",\"from\":\"default\""* ]]
}

@test "list: a name only in the local file is listed, FROM local; an environment-only line is not" {
  printf 'FAKE_STRAY=1\nFAKE_CONFIG_HOME=/x\n' > "$CFG/fake/fake.local.env"
  t fake config list
  [[ "$output" == *$'\n'"FAKE_STRAY"$'\t'"1"$'\t'"local"* ]]
  # the loader warns about the line; no row
  [[ "$output" == *"FAKE_CONFIG_HOME is read from the environment only"* ]]
  [[ "$output" != *"FAKE_CONFIG_HOME"$'\t'* ]]
}

@test "--json: name value from file; file is null for env, the shipped file for default" {
  printf 'FAKE_DIR=/srv/x\n' > "$CFG/fake/fake.local.env"
  t FAKE_ON=2 fake config list --json
  [ "$status" -eq 0 ]
  [[ "$output" == '[{"name":"FAKE_X","value":"120","from":"default","file":"'"$CFG/fake/fake.env"'"},'* ]]
  [[ "$output" == *'{"name":"FAKE_DIR","value":"/srv/x","from":"local","file":"'"$CFG/fake/fake.local.env"'"}'* ]]
  [[ "$output" == *'{"name":"FAKE_ON","value":"2","from":"env","file":null}'* ]]
  [[ "$output" == *'{"name":"FAKE_EMPTY","value":null,"from":"default",'* ]]
}

@test "set: creates fake.local.env with a header, replaces the line in place, and the tool reads it" {
  t fake config set FAKE_X=300
  [ "$status" -eq 0 ]
  [ "$(head -1 "$CFG/fake/fake.local.env")" = "# fake settings for this machine (fake config set and unset write here; the defaults are in fake.env)" ]
  printf '# mine\nFAKE_DIR=/a\n' >> "$CFG/fake/fake.local.env"
  t fake config set FAKE_X=400
  [ "$(tail -n +2 "$CFG/fake/fake.local.env")" = "$(printf 'FAKE_X=400\n# mine\nFAKE_DIR=/a')" ]
  t fake config get FAKE_X
  [ "$output" = 400 ]
  t fake show
  [ "$output" = "FAKE_X=400" ]
  # nothing else in the directory: the temp file is gone, the shipped one untouched
  [ "$(ls -A "$CFG/fake" | sort | tr '\n' ' ')" = "fake.env fake.local.env " ]
}

@test "set: a value with a space is quoted and reads back whole; several at once; --json" {
  t fake config set "FAKE_X=a b # c" "FAKE_DIR=~/d"
  [ "$status" -eq 0 ]
  grep -qx "FAKE_X='a b # c'" "$CFG/fake/fake.local.env"
  grep -qx "FAKE_DIR=~/d" "$CFG/fake/fake.local.env"
  t fake config get FAKE_X
  [ "$output" = "a b # c" ]
  t fake config get FAKE_DIR
  [ "$output" = "$HOME/d" ]
  t fake config set FAKE_X=1 --json
  [ "$output" = '{"name":"FAKE_X","value":"1","file":"'"$CFG/fake/fake.local.env"'"}' ]
}

@test "set: through a link to the local file, the file it points to is written" {
  mkdir -p "$HOME/dots"
  printf 'FAKE_X=1\n' > "$HOME/dots/fake.local.env"
  ln -s "$HOME/dots/fake.local.env" "$CFG/fake/fake.local.env"
  t fake config set FAKE_X=2
  [ "$status" -eq 0 ]
  [ -L "$CFG/fake/fake.local.env" ]
  [ "$(cat "$HOME/dots/fake.local.env")" = "FAKE_X=2" ]
}

@test "set: refused, 64, nothing written: undeclared, ANFS_WORK, a *_HOME, a single quote, malformed" {
  t fake config set OTHER_X=1
  [ "$status" -eq 64 ]
  [ "$output" = "fake config: OTHER_X is not a fake setting (fake config list)" ]
  t fake config set ANFS_WORK=x
  [ "$status" -eq 64 ]
  t fake config set FAKE_CONFIG_HOME=/x
  [ "$status" -eq 64 ]
  [[ "$output" == *"FAKE_CONFIG_HOME is read from the environment only"* ]]
  t fake config set "FAKE_X=it's"
  [ "$status" -eq 64 ]
  t fake config set FAKE_X
  [ "$status" -eq 64 ]
  t fake config set FAKE_X=1 9X=1
  [ "$status" -eq 64 ]
  # a stray local line is listed, never set
  printf 'FAKE_STRAY=1\n' > "$CFG/fake/fake.local.env"
  t fake config set FAKE_STRAY=2
  [ "$status" -eq 64 ]
  [ "$(cat "$CFG/fake/fake.local.env")" = "FAKE_STRAY=1" ]
  rm "$CFG/fake/fake.local.env"
  t fake config set FAKE_X=1 OTHER_X=1
  [ ! -e "$CFG/fake/fake.local.env" ]
}

@test "set with the name in the environment: written, a warning, and get prints the environment's" {
  t FAKE_X=5 fake config set FAKE_X=300
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake: FAKE_X is set in the environment (5), which wins over fake.local.env"* ]]
  grep -qx FAKE_X=300 "$CFG/fake/fake.local.env"
  t FAKE_X=5 fake config get FAKE_X
  [ "$output" = 5 ]
}

@test "get: refuses what is not declared; 1 and nothing for an empty default" {
  t fake config get OTHER_X
  [ "$status" -eq 64 ]
  t fake config get FAKE_EMPTY
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  t fake config set FAKE_EMPTY=
  t fake config get FAKE_EMPTY
  [ "$status" -eq 0 ]
}

@test "unset: removes the line (and any later one of the name), keeps the others; absent is 0" {
  printf '# mine\nFAKE_X=1\nFAKE_DIR=/a\nexport FAKE_X=2\nFAKE_STRAY=1\n' > "$CFG/fake/fake.local.env"
  t fake config unset FAKE_X FAKE_STRAY
  [ "$status" -eq 0 ]
  [ "$(cat "$CFG/fake/fake.local.env")" = "$(printf '# mine\nFAKE_DIR=/a')" ]
  t fake config unset FAKE_X
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAKE_X is not in ~/.config/fake/fake.local.env"* ]]
  t fake config unset OTHER_X
  [ "$status" -eq 64 ]
  # no local file: nothing is created
  rm "$CFG/fake/fake.local.env"
  t fake config unset FAKE_X
  [ "$status" -eq 0 ]
  [ ! -e "$CFG/fake/fake.local.env" ]
}

@test "list --export: eval'd in a clean bash it sets the values; env rows and empty defaults are left out" {
  printf "FAKE_DIR='/a b'\n" > "$CFG/fake/fake.local.env"
  t FAKE_ON=9 fake config list --export
  [ "$status" -eq 0 ]
  [[ "$output" != *FAKE_ON* && "$output" != *FAKE_EMPTY* ]]
  run env -i /bin/bash -c 'eval "$1"; printf "%s|%s|%s\n" "$FAKE_X" "$FAKE_DIR" "${FAKE_ON-unset}"' _ "$output"
  [ "$output" = "120|/a b|unset" ]
}

@test "completion: get, set and unset complete the declared names, set as NAME=" {
  t fake __complete config get ""
  [ "$output" = "$(printf 'FAKE_X\nFAKE_DIR\nFAKE_ON\nFAKE_EMPTY')" ]
  t fake __complete config set ""
  [ "${lines[0]}" = "FAKE_X=" ]
  t fake __complete config unset FAKE_X ""
  [ "${lines[1]}" = "FAKE_DIR" ]
}

@test "help: the group names the files and the precedence" {
  t fake help config
  [[ "$output" == *"Settings in ~/.config/fake: fake.local.env over fake.env (shipped), the environment over both"* ]]
  [[ "$output" == *"set <assignment>..."* ]]
}

# --- anfs and pcm -------------------------------------------------------------------------------

@test "anfs config list: ANFS_* and HOMEBREW_NO_*, nothing of pcm's; ANFS_WORK from the environment only" {
  mkdir -p "$CFG/pcm"
  ln -s "$PKGS/pcm/home/.config/pcm/pcm.env" "$CFG/pcm/pcm.env"
  t anfs config list
  [ "$status" -eq 0 ]
  [[ "$output" == *"ANFS_UPDATE_CACHE_DURATION"$'\t'"86400"$'\t'"shipped"* ]]
  [[ "$output" == *"HOMEBREW_NO_AUTO_UPDATE"$'\t'"1"$'\t'"shipped"* ]]
  [[ "$output" == *"HOMEBREW_NO_ENV_HINTS"* && "$output" != *PCM_* && "$output" != *ANFS_WORK* ]]
  t ANFS_WORK=j anfs config list
  [[ "$output" == *"ANFS_WORK"$'\t'"j"$'\t'"env"* ]]
  t ANFS_WORK=j anfs config get ANFS_WORK
  [ "$output" = j ]
  # a line in anfs.local.env is ignored, with the loader's warning, and gives no row
  printf 'ANFS_WORK=x\n' > "$CFG/anfs/anfs.local.env"
  t anfs config list
  [[ "$output" != *ANFS_WORK$'\t'* ]]
}

@test "anfs config list --all: a TOOL column, pcm's rows when pcm.env is there, none when not" {
  t anfs config list --all
  [ "$status" -eq 0 ]
  [[ "$output" == "anfs"$'\t'"ANFS_UPDATE_CACHE_DURATION"* && "$output" != *PCM_* ]]
  mkdir -p "$CFG/pcm"
  ln -s "$PKGS/pcm/home/.config/pcm/pcm.env" "$CFG/pcm/pcm.env"
  printf 'PCM_HEALTH_TIMEOUT=300\n' > "$CFG/pcm/pcm.local.env"
  t anfs config list --all
  [[ "$output" == *$'\n'"pcm"$'\t'"PCM_HEALTH_TIMEOUT"$'\t'"300"$'\t'"local"* ]]
  [[ "$output" == *$'\n'"fake"$'\t'"FAKE_X"* ]]
  t anfs config list --all --json
  [[ "$output" == *'{"tool":"pcm","name":"PCM_HEALTH_TIMEOUT","value":"300","from":"local","file":'* ]]
  # a tool's files moved by its *_CONFIG_HOME
  mv "$CFG/fake" "$HOME/elsewhere"
  t FAKE_CONFIG_HOME="$HOME/elsewhere" anfs config list --all
  [[ "$output" == *$'\n'"fake"$'\t'"FAKE_X"* ]]
  # --export takes --all too; other tools have no --all
  t anfs config list --all --export
  [[ "$output" == *"export PCM_HEALTH_TIMEOUT='300'"* && "$output" == *"export ANFS_UPDATE_CACHE_DURATION='86400'"* ]]
  t fake config list --all
  [ "$status" -eq 64 ]
}

@test "pcm: its own settings; PMM_INSTALL is refused; anfs container config list is pcm config list" {
  mkdir -p "$CFG/pcm"
  ln -s "$PKGS/pcm/home/.config/pcm/pcm.env" "$CFG/pcm/pcm.env"
  t pcm config set PCM_HEALTH_TIMEOUT=300
  [ "$status" -eq 0 ]
  grep -qx PCM_HEALTH_TIMEOUT=300 "$CFG/pcm/pcm.local.env"
  t pcm config set PMM_INSTALL=x
  [ "$status" -eq 64 ]
  [ "$output" = "pcm config: PMM_INSTALL is not a pcm setting (pcm config list)" ]
  t pcm config list
  [ "$status" -eq 0 ]
  pcm_out="$output"
  [[ "$pcm_out" == "PCM_COMPOSE"* && "$pcm_out" == *"PCM_HEALTH_TIMEOUT"$'\t'"300"$'\t'"local"* ]]
  t anfs container config list
  [ "$status" -eq 0 ]
  [ "$output" = "$pcm_out" ]
}
