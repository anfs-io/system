#!/usr/bin/env bats
# Edges: edges.yml resolution, implicit edge dependencies, the public PCM_INGRESS_URL, publishing
# on up, validation; and the cloudflare-tunnel provider against a fake Cloudflare API (curl stub).
# Run: bats packages/pcm/tests/

load helper

setup() {
  pcm_setup
  add_source a
  unset PCM_PROXY CLOUDFLARE_API_TOKEN PCM_TUNNEL_NAME
  mkdir -p "$PCM_CONFIG_HOME/edges" "$PCM_ENV_HOME"
  define "$T/src/a/containers" traefik 'services:
  traefik:
    image: docker.io/library/alpine:3
x-pcm:
  provides: proxy'
  proxy_hook labels 'echo a=b'
  proxy_hook provision 'for a in "$@"; do if [[ $a == hosts=* ]]; then h=${a#hosts=}; echo "URL=http://${h%%,*}:8088"; fi; done'
  # A fake edge: records its calls, runs service "tun"
  define "$T/src/a/containers" tun 'services:
  tun:
    image: docker.io/library/alpine:3
x-pcm:
  provides: edge'
  edge fake 'echo "$*" >> "$T/fake.calls"
case "$1" in deps) echo tun ;; scheme) echo https ;; check) [[ -z "${FAIL_CHECK:-}" ]] || { echo "no token"; exit 1; } ;; esac'
  export T
}

proxy_hook() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/src/a/containers/traefik/$1"
  chmod +x "$T/src/a/containers/traefik/$1"
}

edge() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$PCM_CONFIG_HOME/edges/$1"
  chmod +x "$PCM_CONFIG_HOME/edges/$1"
}

edges_yml() { printf '%s\n' "$1" > "$PCM_CONFIG_HOME/edges.yml"; }

define_app() {
  define "$T/src/a/containers" app "services:
  web:
    image: docker.io/library/alpine:3
x-pcm:
  ingress:
    port: 3000
    hosts: \${APP_HOSTS:-}"
}

@test "host_edge: the longest domain wins; no match is nothing" {
  edges_yml 'example.com: { provider: fake }
int.example.com: { provider: local }'
  [ "$(host_edge crm.example.com)" = "example.com|fake" ]
  [ "$(host_edge example.com)" = "example.com|fake" ]
  [ "$(host_edge n8n.int.example.com)" = "int.example.com|local" ]
  [ -z "$(host_edge app.localhost)" ]
  [ -z "$(host_edge badexample.com)" ]
}

@test "hosts come from \$PCM_ENV_HOME/<name>.env, without varlock" {
  define_app
  echo 'APP_HOSTS=crm.example.com, app.localhost' > "$PCM_ENV_HOME/app.env"
  load_sources
  [ "$(ingress_hosts a/app)" = "crm.example.com,app.localhost" ]
  # and nothing leaks into the caller
  [ -z "${APP_HOSTS:-}" ]
}

@test "a published host makes the service depend on its edge's service; local ones don't" {
  edges_yml 'example.com: { provider: fake }
int.example.com: { provider: local }'
  define_app
  load_sources
  [ "$(dep_ids a/app)" = "a/traefik" ]
  echo 'APP_HOSTS=n8n.int.example.com' > "$PCM_ENV_HOME/app.env"
  [ "$(dep_ids a/app)" = "a/traefik" ]
  echo 'APP_HOSTS=crm.example.com,app.localhost' > "$PCM_ENV_HOME/app.env"
  [ "$(dep_ids a/app | paste -sd ' ' -)" = "a/traefik a/tun" ]
}

@test "PCM_INGRESS_URL is the edge's public URL when the first host is published" {
  edges_yml 'example.com: { provider: fake }'
  define_app
  load_sources
  PROVISIONED=()
  provision a/app a/traefik a/traefik
  [ "${PROVISIONED[0]}" = "PCM_INGRESS_URL=http://app.localhost:8088" ]

  echo 'APP_HOSTS=crm.example.com,app.localhost' > "$PCM_ENV_HOME/app.env"
  PROVISIONED=()
  provision a/app a/traefik a/traefik
  [ "${PROVISIONED[0]}" = "PCM_INGRESS_URL=https://crm.example.com" ]
}

@test "edges_publish/unpublish: add/remove each published host with the origin and options" {
  edges_yml 'example.com: { provider: fake, tunnel: home }'
  define_app
  echo 'APP_HOSTS=crm.example.com,app.localhost,www.example.com' > "$PCM_ENV_HOME/app.env"
  load_sources
  edges_publish a/app 2>/dev/null
  edges_unpublish a/app 2>/dev/null
  [ "$(cat "$T/fake.calls")" = "add crm.example.com origin=http://traefik:80 tunnel=home
add www.example.com origin=http://traefik:80 tunnel=home
remove crm.example.com origin=http://traefik:80 tunnel=home
remove www.example.com origin=http://traefik:80 tunnel=home" ]
}

@test "validate: a failing check and an unknown provider are errors; an unpublished public host warns" {
  edges_yml 'example.com: { provider: fake }
example.org: { provider: nope }'
  define_app
  echo 'APP_HOSTS=crm.example.com,www.example.org,app.example.net' > "$PCM_ENV_HOME/app.env"
  load_sources
  FAIL_CHECK=1 run validate_services a/app
  [ "$status" -eq 1 ]
  [[ "$output" == *"edge fake for crm.example.com: no token"* ]]
  [[ "$output" == *"example.org uses unknown edge provider 'nope'"* ]]
  [[ "$output" == *"warning: host app.example.net is under no domain in edges.yml"* ]]
}

@test "a role provider gets its name as an alias on the shared network" {
  podman() { [[ "$1 $2" == "network exists" ]]; }
  load_sources
  compose_flags a/traefik
  [ "$(yq eval '.services.traefik.networks.dev-net.aliases[0]' "$(override_file a/traefik)")" = traefik ]
}

# --- cloudflare-tunnel against a fake API -------------------------------------------------------
# One zone, example.com (Z1, account A1). State: $CF/tunnel (exists when created), $CF/records
# (id|type|name|content), $CF/log (METHOD path [body]).

fake_cloudflare() {
  CF="$T/cf"
  mkdir -p "$CF" "$T/bin"
  : > "$CF/records"; : > "$CF/log"
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
method=GET url="" body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data) body="$2"; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
path="${url#*/client/v4}"
echo "$method $path${body:+ $body}" >> "$CF/log"
ok() { echo "{\"success\":true,\"result\":$1}"; }
records() { # name [type]
  local first=true out="["
  while IFS='|' read -r id type name content; do
    [[ -n "$id" && "$name" == "$1" && ( -z "${2:-}" || "$type" == "$2" ) ]] || continue
    $first || out+=","; first=false
    out+="{\"id\":\"$id\",\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\"}"
  done < "$CF/records"
  echo "$out]"
}
q() { sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p" <<< "$path"; }
case "$method $path" in
  "GET /zones?name="*) [[ "$(q name)" == example.com ]] && ok '[{"id":"Z1","account":{"id":"A1"}}]' || ok '[]' ;;
  "GET /accounts/A1/cfd_tunnel?"*) [[ -f "$CF/tunnel" ]] && ok '[{"id":"T1"}]' || ok '[]' ;;
  "POST /accounts/A1/cfd_tunnel") echo "$body" > "$CF/tunnel"; ok '{"id":"T1"}' ;;
  "PUT /accounts/A1/cfd_tunnel/T1/configurations") ok '{}' ;;
  "GET /accounts/A1/cfd_tunnel/T1/token") ok '"tok-123"' ;;
  "GET /zones/Z1/dns_records?"*) ok "$(records "$(q name)" "$(q type)")" ;;
  "POST /zones/Z1/dns_records")
    n=$(yq -p json '.name' <<< "$body"); c=$(yq -p json '.content' <<< "$body")
    echo "R$RANDOM|CNAME|$n|$c" >> "$CF/records"; ok '{}' ;;
  "DELETE /zones/Z1/dns_records/"*) id="${path##*/}"; grep -v "^$id|" "$CF/records" > "$CF/r" || true; mv "$CF/r" "$CF/records"; ok '{}' ;;
  *) echo '{"success":false,"errors":[{"message":"unexpected call"}]}' ;;
esac
EOF
  chmod +x "$T/bin/curl"
  export CF PATH="$T/bin:$PATH" CLOUDFLARE_API_TOKEN=test PCM_TUNNEL_NAME=pcm-test
}

cft() { "$PCM_LIB_DIR/edges/cloudflare-tunnel" "$@"; }

@test "cloudflare-tunnel: deps, scheme, and check needs a token" {
  [ "$(cft deps)" = cloudflared ]
  [ "$(cft scheme)" = https ]
  run cft check
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLOUDFLARE_API_TOKEN is not set"* ]]
}

@test "cloudflare-tunnel add: creates the tunnel, points it at the origin, writes the token, adds the CNAME" {
  fake_cloudflare
  echo 'OTHER=kept' > "$PCM_ENV_HOME/cloudflared.env"
  cft add crm.example.com origin=http://traefik:80 2>/dev/null
  grep -qF 'POST /accounts/A1/cfd_tunnel {"name":"pcm-test","config_src":"cloudflare"}' "$CF/log"
  grep -qF 'PUT /accounts/A1/cfd_tunnel/T1/configurations {"config":{"ingress":[{"service":"http://traefik:80"}]}}' "$CF/log"
  grep -qx 'TUNNEL_TOKEN=tok-123' "$PCM_ENV_HOME/cloudflared.env"
  grep -qx 'OTHER=kept' "$PCM_ENV_HOME/cloudflared.env"
  [ "$(stat -f %Lp "$PCM_ENV_HOME/cloudflared.env" 2>/dev/null || stat -c %a "$PCM_ENV_HOME/cloudflared.env")" = 600 ]
  grep -q '|CNAME|crm.example.com|T1.cfargotunnel.com$' "$CF/records"
  grep -qF '"proxied":true' "$CF/log"
}

@test "cloudflare-tunnel add: idempotent, the tunnel and record are reused" {
  fake_cloudflare
  cft add crm.example.com origin=http://traefik:80 2>/dev/null
  cft add crm.example.com origin=http://traefik:80 2>/dev/null
  [ "$(grep -c 'POST /accounts/A1/cfd_tunnel ' "$CF/log")" -eq 1 ]
  [ "$(grep -c 'POST /zones/Z1/dns_records' "$CF/log")" -eq 1 ]
  [ "$(grep -c 'TUNNEL_TOKEN=' "$PCM_ENV_HOME/cloudflared.env")" -eq 1 ]
}

@test "cloudflare-tunnel add: never replaces someone else's record; an unknown zone fails" {
  fake_cloudflare
  echo 'R1|A|www.example.com|203.0.113.7' >> "$CF/records"
  run cft add www.example.com origin=http://traefik:80
  [ "$status" -eq 1 ]
  [[ "$output" == *"www.example.com already has a A record (203.0.113.7); not replacing it"* ]]
  grep -qx 'R1|A|www.example.com|203.0.113.7' "$CF/records"

  run cft add crm.example.org origin=http://traefik:80
  [ "$status" -eq 1 ]
  [[ "$output" == *"no zone for crm.example.org"* ]]
}

@test "cloudflare-tunnel remove: deletes only a CNAME to this tunnel" {
  fake_cloudflare
  cft add crm.example.com origin=http://traefik:80 2>/dev/null
  echo 'R2|CNAME|other.example.com|elsewhere.example.net' >> "$CF/records"
  cft remove crm.example.com 2>/dev/null
  cft remove other.example.com 2>/dev/null
  ! grep -q 'crm.example.com' "$CF/records"
  grep -q 'other.example.com' "$CF/records"
  [ -f "$CF/tunnel" ]
}

@test "cloudflare-tunnel: an API error stops add before it changes DNS" {
  fake_cloudflare
  # The tunnel config call fails
  sed -i.bak 's|"PUT /accounts/A1/cfd_tunnel/T1/configurations") ok|"PUT /accounts/A1/cfd_tunnel/T1/configurations") echo "{\\"success\\":false,\\"errors\\":[{\\"message\\":\\"denied\\"}]}" ;; "PUT /never") ok|' "$T/bin/curl"
  run cft add crm.example.com origin=http://traefik:80
  [ "$status" -eq 1 ]
  [[ "$output" == *"denied"* ]]
  ! grep -q 'POST /zones/Z1/dns_records' "$CF/log"
  [ ! -s "$CF/records" ]
}
