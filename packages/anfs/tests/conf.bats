#!/usr/bin/env bats
# lib/anfs/paths.sh: each tool's settings. ~/.config/<tool>/<tool>.env (shipped) and
# <tool>.local.env (this machine's) beside it, read and never sourced; the environment wins, then
# the local file, then the shipped one. anfs's own are loaded when paths.sh is sourced, a tool's
# by anfs_tool_paths <tool>, and nothing else: a tool not installed contributes nothing.
# Run: bats packages/anfs/tests/conf.bats

setup() {
  LIB="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME=$(cd -P "$BATS_TEST_TMPDIR/home" && pwd -P)
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  unset ANFS_CONFIG_HOME ANFS_DATA_HOME ANFS_STATE_HOME ANFS_CACHE_HOME
  unset PCM_CONFIG_HOME PCM_DATA_HOME PCM_STATE_HOME PCM_CACHE_HOME
  unset ANFS_WORK ANFS_UPDATE_CACHE_DURATION ANFS_QUIET_SKIPPED_REPOS ANFS_SKILLS_CLI_VERSION
  unset HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_ENV_HINTS
  unset PCM_HEALTH_TIMEOUT PCM_SHARED_NETWORK PCM_COMPOSE PCM_MACHINE_MEMORY PCM_ATTACHED_SERVICES
  mkdir -p "$XDG_CONFIG_HOME/anfs" "$XDG_CONFIG_HOME/pcm"
}

# Run a snippet in a fresh bash that has sourced paths.sh; HOME and XDG come from setup
in_paths() {
  run "$BASH" -c 'set -euo pipefail; source "$1/paths.sh"; eval "$2"' _ "$LIB" "$1"
}

@test "anfs_conf_read: quoted, unquoted, export, blanks and comments; malformed lines skipped" {
  f="$BATS_TEST_TMPDIR/x.env"
  cat > "$f" <<'EOF'
# a comment
   # an indented comment

A=1
  B=two words
C="double quoted"
D='single quoted'
E="mixed'
export F=exported
export   G="exported, quoted"
H=
I=a=b
not a setting
1J=bad
K = spaced
exportL=1
M=$HOME/x
EOF
  in_paths "anfs_conf_read '$f'"
  [ "$status" -eq 0 ]
  expected=$(printf '%s\t%s\n' A 1 B 'two words' C 'double quoted' D 'single quoted' E "\"mixed'" \
    F exported G 'exported, quoted' H '' I a=b exportL 1 M '$HOME/x')
  [ "$output" = "$expected" ]
}

@test "anfs_conf_read: a missing file is no lines; nothing is exported" {
  in_paths "anfs_conf_read /nonexistent/x.env; echo \"[\${A-unset}]\""
  [ "$status" -eq 0 ]
  [ "$output" = "[unset]" ]
  printf 'A=1\n' > "$BATS_TEST_TMPDIR/a.env"
  in_paths "anfs_conf_read '$BATS_TEST_TMPDIR/a.env' >/dev/null; echo \"[\${A-unset}]\""
  [ "$output" = "[unset]" ]
}

@test "anfs_conf_files: local first, under the tool's config directory, which an env var moves" {
  in_paths 'anfs_conf_files; anfs_conf_files pcm; PCM_CONFIG_HOME=/elsewhere anfs_conf_files pcm; anfs_conf_files rpi-imager'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$HOME/.config/anfs/anfs.local.env" ]
  [ "${lines[1]}" = "$HOME/.config/anfs/anfs.env" ]
  [ "${lines[2]}" = "$HOME/.config/pcm/pcm.local.env" ]
  [ "${lines[3]}" = "$HOME/.config/pcm/pcm.env" ]
  [ "${lines[4]}" = "/elsewhere/pcm.local.env" ]
  [ "${lines[5]}" = "/elsewhere/pcm.env" ]
  [ "${lines[6]}" = "$HOME/.config/rpi-imager/rpi-imager.local.env" ]
}

@test "anfs_conf_env_only: the XDG kinds' homes and the job switch" {
  in_paths 'for n in ANFS_WORK ANFS_WORK_HOME ANFS_WORK_TMP PCM_CONFIG_HOME ANFS_DATA_HOME TSM_STATE_HOME X_CACHE_HOME \
    WSM_SPACES_HOME PCM_VOLUMES_HOME ANFS_WORK_JOB PCM_HEALTH_TIMEOUT; do anfs_conf_env_only "$n" && echo "$n yes" || echo "$n no"; done'
  [ "$status" -eq 0 ]
  [ "$output" = "ANFS_WORK yes
ANFS_WORK_HOME yes
ANFS_WORK_TMP yes
PCM_CONFIG_HOME yes
ANFS_DATA_HOME yes
TSM_STATE_HOME yes
X_CACHE_HOME yes
WSM_SPACES_HOME no
PCM_VOLUMES_HOME no
ANFS_WORK_JOB no
PCM_HEALTH_TIMEOUT no" ]
}

@test "sourcing paths.sh loads anfs.local.env over anfs.env, and exports them" {
  printf 'ANFS_UPDATE_CACHE_DURATION=10\nANFS_QUIET_SKIPPED_REPOS=true\n' > "$XDG_CONFIG_HOME/anfs/anfs.local.env"
  printf 'ANFS_UPDATE_CACHE_DURATION=86400\nHOMEBREW_NO_AUTO_UPDATE=1\n#ANFS_SKILLS_CLI_VERSION=latest\n' > "$XDG_CONFIG_HOME/anfs/anfs.env"
  in_paths 'echo "$ANFS_UPDATE_CACHE_DURATION $ANFS_QUIET_SKIPPED_REPOS $HOMEBREW_NO_AUTO_UPDATE ${ANFS_SKILLS_CLI_VERSION-unset}"; bash -c "echo \$ANFS_UPDATE_CACHE_DURATION"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "10 true 1 unset" ]
  [ "${lines[1]}" = "10" ]
}

@test "the environment beats both files, an empty value included" {
  printf 'ANFS_UPDATE_CACHE_DURATION=10\n' > "$XDG_CONFIG_HOME/anfs/anfs.local.env"
  printf 'ANFS_UPDATE_CACHE_DURATION=86400\nHOMEBREW_NO_ENV_HINTS=1\n' > "$XDG_CONFIG_HOME/anfs/anfs.env"
  ANFS_UPDATE_CACHE_DURATION=5 HOMEBREW_NO_ENV_HINTS= in_paths 'echo "$ANFS_UPDATE_CACHE_DURATION [$HOMEBREW_NO_ENV_HINTS]"'
  [ "$output" = "5 []" ]
}

@test "anfs.conf and anfs.local.conf are not read" {
  printf 'ANFS_UPDATE_CACHE_DURATION=1\n' > "$XDG_CONFIG_HOME/anfs/anfs.conf"
  printf 'ANFS_QUIET_SKIPPED_REPOS=true\n' > "$XDG_CONFIG_HOME/anfs/anfs.local.conf"
  in_paths 'echo "${ANFS_UPDATE_CACHE_DURATION-unset} ${ANFS_QUIET_SKIPPED_REPOS-unset}"'
  [ "$output" = "unset unset" ]
}

@test "anfs_tool_paths pcm loads pcm.local.env over pcm.env; the environment beats both" {
  printf 'PCM_HEALTH_TIMEOUT=200\n' > "$XDG_CONFIG_HOME/pcm/pcm.local.env"
  printf 'PCM_HEALTH_TIMEOUT=120\nPCM_SHARED_NETWORK=net\n#PCM_COMPOSE="podman compose"\n' > "$XDG_CONFIG_HOME/pcm/pcm.env"
  in_paths 'anfs_tool_paths pcm; echo "$PCM_CONFIG_HOME $PCM_HEALTH_TIMEOUT $PCM_SHARED_NETWORK ${PCM_COMPOSE-unset}"'
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.config/pcm 200 net unset" ]
  PCM_HEALTH_TIMEOUT=300 in_paths 'anfs_tool_paths pcm; echo "$PCM_HEALTH_TIMEOUT"'
  [ "$output" = "300" ]
}

@test "a PCM_CONFIG_HOME set in the environment moves pcm's files" {
  mkdir -p "$BATS_TEST_TMPDIR/other"
  printf 'PCM_HEALTH_TIMEOUT=200\n' > "$XDG_CONFIG_HOME/pcm/pcm.local.env"
  printf 'PCM_HEALTH_TIMEOUT=7\n' > "$BATS_TEST_TMPDIR/other/pcm.env"
  PCM_CONFIG_HOME="$BATS_TEST_TMPDIR/other" in_paths 'anfs_tool_paths pcm; echo "$PCM_HEALTH_TIMEOUT"'
  [ "$output" = "7" ]
}

@test "a tool whose directory does not exist loads nothing and fails nothing" {
  in_paths 'anfs_tool_paths nothere; echo "ok $NOTHERE_CONFIG_HOME"'
  [ "$status" -eq 0 ]
  [ "$output" = "ok $HOME/.config/nothere" ]
}

@test "a second call loads nothing new" {
  printf 'PCM_HEALTH_TIMEOUT=200\n' > "$XDG_CONFIG_HOME/pcm/pcm.env"
  in_paths 'anfs_tool_paths pcm; printf "PCM_HEALTH_TIMEOUT=9\n" > "$PCM_CONFIG_HOME/pcm.local.env"; anfs_load_conf pcm; echo "$PCM_HEALTH_TIMEOUT"'
  [ "$output" = "200" ]
}

@test "ANFS_WORK and a *_HOME in a file are not exported, and each warns once" {
  printf 'ANFS_WORK=job\nANFS_WORK_HOME=/w\nANFS_UPDATE_CACHE_DURATION=1\n' > "$XDG_CONFIG_HOME/anfs/anfs.env"
  printf 'PCM_CONFIG_HOME=/x\nPCM_DATA_HOME=/y\nPCM_HEALTH_TIMEOUT=3\n' > "$XDG_CONFIG_HOME/pcm/pcm.env"
  in_paths 'anfs_tool_paths pcm; echo "${ANFS_WORK-unset} ${ANFS_WORK_HOME-unset} $ANFS_UPDATE_CACHE_DURATION $PCM_CONFIG_HOME $PCM_DATA_HOME $PCM_HEALTH_TIMEOUT"'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "unset unset 1 $HOME/.config/pcm $HOME/.local/share/pcm 3" ]
  [ "$(grep -c 'anfs: ~/.config/anfs/anfs.env: ANFS_WORK is read from the environment only' <<< "$output")" -eq 1 ]
  [ "$(grep -c 'ANFS_WORK_HOME is read from the environment only' <<< "$output")" -eq 1 ]
  [ "$(grep -c 'anfs: ~/.config/pcm/pcm.env: PCM_CONFIG_HOME is read from the environment only' <<< "$output")" -eq 1 ]
  [ "$(grep -c 'PCM_DATA_HOME is read from the environment only' <<< "$output")" -eq 1 ]
}

@test "the encapsulation: with only anfs's files, anfs_tool_paths pcm sets no PCM_* setting" {
  # what core/anfs ships, as installed; core/pcm is not, so ~/.config/pcm has nothing
  cp "$LIB/../../../.config/anfs/anfs.env" "$XDG_CONFIG_HOME/anfs/anfs.env"
  rmdir "$XDG_CONFIG_HOME/pcm"
  # a clean environment: a job's run exports PMM_SOCK_DIR and PMM_SSH_PORT_BASE
  run env -i HOME="$HOME" PATH="$PATH" "$BASH" -c 'set -euo pipefail; source "$1/paths.sh"; eval "$2"' _ "$LIB" \
    'anfs_tool_paths pcm; anfs_tool_paths pmm; compgen -e | grep -E "^(PCM|PMM)_" | grep -vE "_(CONFIG|DATA|STATE|CACHE)_HOME$" || echo none; echo "$ANFS_UPDATE_CACHE_DURATION"'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "none" ]
  [ "${lines[1]}" = "86400" ]
}

@test "the loader expands a leading ~/ and a lone ~ to \$HOME, nothing else; anfs_conf_read keeps them" {
  cat > "$XDG_CONFIG_HOME/pcm/pcm.env" <<'X'
PCM_A=~/mnt
PCM_B="~/quoted dir"
PCM_C=~
PCM_D=~user/x
PCM_E=a/~/b
PCM_F=$HOME/x
PCM_G=~/*.txt
PCM_H='~'
PCM_I=~x
X
  in_paths 'anfs_tool_paths pcm; for n in A B C D E F G H I; do v=PCM_$n; echo "$n=${!v}"; done'
  [ "$status" -eq 0 ]
  [ "$output" = "A=$HOME/mnt
B=$HOME/quoted dir
C=$HOME
D=~user/x
E=a/~/b
F=\$HOME/x
G=$HOME/*.txt
H=$HOME
I=~x" ]
  in_paths "anfs_conf_read '$XDG_CONFIG_HOME/pcm/pcm.env' | head -3"
  [ "$output" = "$(printf 'PCM_A\t~/mnt\nPCM_B\t~/quoted dir\nPCM_C\t~')" ]
}

@test "anfs_conf_expand: into REPLY" {
  in_paths 'anfs_conf_expand "~/a"; echo "$REPLY"; anfs_conf_expand "~"; echo "$REPLY"; anfs_conf_expand "x~/"; echo "$REPLY"'
  [ "$output" = "$HOME/a
$HOME
x~/" ]
}
