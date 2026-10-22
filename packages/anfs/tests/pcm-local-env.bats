#!/usr/bin/env bats
# pcm: a container's settings on this machine, $PCM_CONTAINERS_HOME/<name>/local.env. A directory
# there is a definition only with compose.yml; with only local.env it is settings for the name,
# defined in any source. What pcm records for one (the tunnel token) is
# $PCM_STATE_HOME/containers/<name>/state.env, never the person's local.env.
# Precedence: environment > local.env > state.env > the .env.schema defaults.
#
# pcm's own suites (packages/pcm/tests) are off until further notice (ROADMAP, 2026-10-19). This
# file is not one of them: it is small and needs no podman, so it runs with anfs's suites. It uses
# pcm's helper (pcm_setup, define, add_source) without the helper's off switch.
# Run: bats packages/anfs/tests/pcm-local-env.bats

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

load ../../pcm/tests/helper
PCM_PKG="$(cd "$BATS_TEST_DIRNAME/../../pcm" && pwd)"
setup_file() { :; }   # the helper's skips every test while pcm's suites are off; this file runs

setup() {
  pcm_setup
  add_source a
  define "$T/src/a/containers" app 'services:
  web:
    image: docker.io/library/alpine:3
    environment:
      X: ${X}'
  mkdir -p "$PCM_CONTAINERS_HOME/app"
  echo 'X=local' > "$PCM_CONTAINERS_HOME/app/local.env"
  unset X
}

@test "pcm_local_env: <name>/local.env under PCM_CONTAINERS_HOME, whatever the source" {
  [ "$(pcm_local_env a/app)" = "$PCM_CONTAINERS_HOME/app/local.env" ]
  [ "$(pcm_local_env local/app)" = "$PCM_CONTAINERS_HOME/app/local.env" ]
}

@test "a directory with only local.env is no definition: not listed, shadows nothing" {
  load_sources
  [ "$(all_ids)" = "a/app" ]
  [ "$(canon app)" = a/app ]
  run canon local/app
  [ "$status" -ne 0 ]
  run cmd_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"a/app"* && "$output" != *"local/app"* && "$output" != *shadowed* ]]
}

@test "completion leaves a settings-only directory out and offers the name from its source" {
  ANFS_SOURCES_HOME="$T/sources"
  mkdir -p "$ANFS_SOURCES_HOME/a"
  ln -s "$T/src/a/containers" "$ANFS_SOURCES_HOME/a/containers"
  mkdir -p "$PCM_CONTAINERS_HOME/only"
  echo 'Y=1' > "$PCM_CONTAINERS_HOME/only/local.env"
  define "$PCM_CONTAINERS_HOME" mine
  [ "$(complete_service | LC_ALL=C sort | paste -sd ' ' -)" = "a/app app mine" ]
}

@test "local.env is exported below the environment; export prefixes and quotes as in <tool>.env" {
  load_sources
  printf '%s\n' '# a comment' 'export X="local"' "Z='a b'" 'not a line' > "$PCM_CONTAINERS_HOME/app/local.env"
  ( export_env_overrides a/app; [ "$X" = local ] && [ "$Z" = "a b" ] )
  ( export X=env; export_env_overrides a/app; [ "$X" = env ] )
  ( export X=; export_env_overrides a/app; [ -z "$X" ] )
  [ -z "${X:-}" ]
}

@test "varlock: local.env beats the .env.schema default, the environment beats local.env" {
  command -v varlock >/dev/null || skip "no varlock"
  printf '%s\n' '# @defaultSensitive=false @defaultRequired=false' '# ---' '# @type=string' 'X=schema' \
    > "$T/src/a/containers/app/.env.schema"
  load_sources
  export HOME="$T/home" VARLOCK_TELEMETRY_DISABLED=1
  mkdir -p "$HOME"
  run in_service_dir a/app varlock load --format env
  [ "$status" -eq 0 ]
  [[ "$output" == *'X="local"'* || "$output" == *"X=local"* ]] || { echo "$output"; return 1; }
  X=env run in_service_dir a/app varlock load --format env
  [[ "$output" == *'X="env"'* || "$output" == *"X=env"* ]] || { echo "$output"; return 1; }
  rm "$PCM_CONTAINERS_HOME/app/local.env"
  run in_service_dir a/app varlock load --format env
  [[ "$output" == *'X="schema"'* || "$output" == *"X=schema"* ]] || { echo "$output"; return 1; }
}

@test "a local definition with compose.yml and local.env uses both" {
  define "$PCM_CONTAINERS_HOME" app
  load_sources
  [ "$(canon app)" = local/app ]
  [ "$(cmd_path app)" = "$PCM_CONTAINERS_HOME/app" ]
  ( export_env_overrides local/app; [ "$X" = local ] )
}

@test "pcm show prints the settings line when local.env exists, for any source" {
  load_sources
  run cmd_show app
  [ "$status" -eq 0 ]
  [[ "$output" == *"settings     $PCM_CONTAINERS_HOME/app/local.env"* ]] || { echo "$output"; return 1; }
  rm "$PCM_CONTAINERS_HOME/app/local.env"
  run cmd_show app
  [[ "$output" != *settings* ]]
}

@test "validate warns about settings for a name no source defines, and an empty directory" {
  mkdir -p "$PCM_CONTAINERS_HOME/ghost" "$PCM_CONTAINERS_HOME/empty"
  echo 'X=1' > "$PCM_CONTAINERS_HOME/ghost/local.env"
  define "$T/src/a/containers" plain
  load_sources
  run cmd_validate a/plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghost: warning: local.env for a container no source defines"* ]]
  [[ "$output" == *"empty: warning: "*"has neither compose.yml nor local.env"* ]]
  [[ "$output" != *"app: warning"* ]]
}

# A Cloudflare that knows one zone, one tunnel (T1) and its CNAME already: a curl on PATH
fake_curl() {
  mkdir -p "$T/bin"
  cat > "$T/bin/curl" <<'EOF2'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == http* ]] && url="$a"; done
ok() { echo "{\"success\":true,\"result\":$1}"; }
case "${url#*/client/v4}" in
  "/zones?name=example.com") ok '[{"id":"Z1","account":{"id":"A1"}}]' ;;
  /zones\?name=*) ok '[]' ;;
  /accounts/A1/cfd_tunnel\?*) ok '[{"id":"T1"}]' ;;
  /accounts/A1/cfd_tunnel/T1/configurations) ok '{}' ;;
  /accounts/A1/cfd_tunnel/T1/token) ok '"tok-123"' ;;
  /zones/Z1/dns_records\?*) ok '[{"id":"R1","type":"CNAME","name":"crm.example.com","content":"T1.cfargotunnel.com"}]' ;;
  *) echo '{"success":false}' ;;
esac
EOF2
  chmod +x "$T/bin/curl"
}

cft_add() {
  PATH="$T/bin:$PATH" CLOUDFLARE_API_TOKEN=test PCM_TUNNEL_NAME=pcm-test \
    "$PCM_LIB_DIR/edges/cloudflare-tunnel" add crm.example.com origin=http://traefik:80
}

mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

@test "pcm_state_env: <name>/state.env under PCM_STATE_HOME, whatever the source" {
  [ "$(pcm_state_env a/app)" = "$PCM_STATE_HOME/containers/app/state.env" ]
  [ "$(pcm_state_env local/app)" = "$PCM_STATE_HOME/containers/app/state.env" ]
}

@test "cloudflare-tunnel writes TUNNEL_TOKEN into cloudflared's state.env (0600 in a 0700 dir), other lines kept, nothing in CONFIG" {
  fake_curl
  f="$PCM_STATE_HOME/containers/cloudflared/state.env"
  mkdir -p "${f%/*}"
  printf '%s\n' 'OTHER=kept' 'TUNNEL_TOKEN=old' > "$f"
  cft_add
  [ "$(cat "$f")" = "OTHER=kept
TUNNEL_TOKEN=tok-123" ]
  [ "$(mode "$f")" = 600 ]
  rm -r "$PCM_STATE_HOME/containers"
  cft_add
  [ "$(cat "$f")" = "TUNNEL_TOKEN=tok-123" ]
  [ "$(mode "$f")" = 600 ]
  [ "$(mode "${f%/*}")" = 700 ]
  # nothing under $PCM_CONFIG_HOME but what the test made (containers/app)
  [ "$(cd "$PCM_CONFIG_HOME" && find . -mindepth 1 | LC_ALL=C sort | paste -sd ' ' -)" = "./containers ./containers/app ./containers/app/local.env" ]
}

@test "the edge's PCM_STATE_HOME comes from pcm: bin/pcm exports it" {
  grep -qE '^export .*\bPCM_STATE_HOME\b' "$PCM_PKG/home/.local/bin/pcm"
}

@test "state.env is exported below local.env, the environment above both" {
  load_sources
  mkdir -p "$PCM_STATE_HOME/containers/app"
  printf '%s\n' 'X=state' 'Y=state' > "$PCM_STATE_HOME/containers/app/state.env"
  ( export_env_overrides a/app; [ "$X" = local ] && [ "$Y" = state ] )
  ( export Y=env; export_env_overrides a/app; [ "$X" = local ] && [ "$Y" = env ] )
  rm "$PCM_CONTAINERS_HOME/app/local.env"
  ( export_env_overrides a/app; [ "$X" = state ] )
  [ -z "${X:-}" ] && [ -z "${Y:-}" ]
}

@test "pcm show prints the state line when state.env exists" {
  load_sources
  run cmd_show app
  [[ "$output" != *"state        "* ]]
  mkdir -p "$PCM_STATE_HOME/containers/app"
  echo 'TUNNEL_TOKEN=t' > "$PCM_STATE_HOME/containers/app/state.env"
  run cmd_show app
  [ "$status" -eq 0 ]
  [[ "$output" == *"state        $PCM_STATE_HOME/containers/app/state.env"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"TUNNEL_TOKEN"* && "$output" != *"=t"* ]]
}

@test "pcm remove deletes what pcm recorded (state.env) and keeps local.env" {
  load_sources
  mkdir -p "$PCM_STATE_HOME/containers/app" "$PCM_STATE_HOME/containers/other"
  echo 'TUNNEL_TOKEN=t' > "$PCM_STATE_HOME/containers/app/state.env"
  echo 'TUNNEL_TOKEN=o' > "$PCM_STATE_HOME/containers/other/state.env"
  # no engine: compose and the edges are stubbed, as nothing runs
  compose_flags() { FLAGS=(); }
  compose_run() { :; }
  export_podman_socket() { :; }
  edges_unpublish() { :; }
  run cli_call remove -y app
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"state        $PCM_STATE_HOME/containers/app/state.env  (deleted"* ]] || { echo "$output"; return 1; }
  [ ! -e "$PCM_STATE_HOME/containers/app" ]
  [ -f "$PCM_STATE_HOME/containers/other/state.env" ]
  [ -f "$PCM_CONTAINERS_HOME/app/local.env" ]
}

@test "nothing in core names PCM_ENV_HOME or ~/.config/pcm/env" {
  repo="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  run grep -rn --exclude=pcm-local-env.bats -e 'PCM_ENV_HOME' -e 'pcm/env\b' "$repo/packages" "$repo/containers" "$repo/skills" "$repo/AGENTS.md" "$repo/README.md"
  [ -z "$output" ] || { echo "$output"; return 1; }
}
