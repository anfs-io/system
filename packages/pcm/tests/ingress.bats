#!/usr/bin/env bats
# x-pcm.ingress and x-pcm.provides: the implicit proxy dependency, proxy selection, the labels
# hook in the generated override, role-prefixed provision output, and validation.
# Run: bats packages/pcm/tests/

load helper

setup() {
  pcm_setup
  add_source a
  unset PCM_PROXY
}

# A proxy definition <name> in source a whose labels hook echoes its args back as test.<arg>
define_proxy() {
  define "$T/src/a/containers" "$1" 'services:
  proxy:
    image: docker.io/library/alpine:3
x-pcm:
  provides: proxy'
  hook "$1" labels 'for a in "$@"; do echo "test.$a"; done'
}

# An executable hook <name> in source a's definition <svc>, running the given script
hook() {
  printf '#!/usr/bin/env bash\n%s\n' "$3" > "$T/src/a/containers/$1/$2"
  chmod +x "$T/src/a/containers/$1/$2"
}

# A service <name> in source a with the given x-pcm.ingress body (indented four spaces)
define_web() {
  define "$T/src/a/containers" "$1" "services:
  web:
    image: docker.io/library/alpine:3
x-pcm:
  ingress:
$2"
}

validate() {
  load_sources
  run validate_services "$@"
}

@test "a service with ingress depends on the proxy, which doesn't depend on itself" {
  define_proxy traefik
  define_web app '    port: 3000'
  load_sources
  [ "$(dep_ids a/app)" = "a/traefik" ]
  [ "$(service_dependents a/traefik)" = "a/app" ]
  [ -z "$(dep_ids a/traefik)" ]
}

@test "a proxy named in depends_on as well is not listed twice" {
  define_proxy traefik
  define "$T/src/a/containers" app 'services:
  web:
    image: docker.io/library/alpine:3
x-pcm:
  depends_on: [traefik]
  ingress:
    port: 3000'
  load_sources
  [ "$(service_deps a/app)" = "traefik" ]
}

@test "the proxy's own ingress (its dashboard) doesn't make it depend on itself" {
  define "$T/src/a/containers" traefik 'services:
  traefik:
    image: docker.io/library/alpine:3
x-pcm:
  provides: proxy
  ingress:
    port: 8080'
  hook traefik labels 'echo a=b'
  load_sources
  [ -z "$(service_deps a/traefik)" ]
}

@test "PCM_PROXY picks between providers; without it, several are an error" {
  define_proxy traefik
  define_proxy caddy
  define_web app '    port: 3000'
  validate a/app
  [ "$status" -eq 1 ]
  [[ "$output" == *"several services provide proxy (a/caddy a/traefik)"* ]]

  PCM_PROXY=caddy
  validate a/app
  [ "$status" -eq 0 ]
  [ "$(dep_ids a/app)" = "a/caddy" ]
}

@test "PCM_PROXY must name a proxy" {
  define_proxy traefik
  define_web app '    port: 3000'
  define "$T/src/a/containers" other
  PCM_PROXY=other
  validate a/app
  [ "$status" -eq 1 ]
  [[ "$output" == *"PCM_PROXY=other does not provide proxy"* ]]
}

@test "ingress without any proxy is an error" {
  define_web app '    port: 3000'
  validate a/app
  [ "$status" -eq 1 ]
  [[ "$output" == *"no service provides proxy"* ]]
}

@test "ingress: bad port, healthcheck and host are errors" {
  define_proxy traefik
  define_web app '    port: http
    healthcheck: up
    hosts: [ok.example.com, "bad_host.example.com"]'
  validate a/app
  [ "$status" -eq 1 ]
  [[ "$output" == *"x-pcm.ingress.port: 'http' is not a port"* ]]
  [[ "$output" == *"x-pcm.ingress.healthcheck: 'up' must be a path"* ]]
  [[ "$output" == *"'bad_host.example.com' is not a hostname"* ]]
  [[ "$output" != *"'ok.example.com'"* ]]
}

@test "ingress: the compose service must exist, and is required when there are several" {
  define_proxy traefik
  define_web app '    service: api
    port: 3000'
  define "$T/src/a/containers" multi 'services:
  web:
    image: docker.io/library/alpine:3
  worker:
    image: docker.io/library/alpine:3
x-pcm:
  ingress:
    port: 3000'
  validate a/app a/multi
  [ "$status" -eq 1 ]
  [[ "$output" == *"a/app: error: x-pcm.ingress.service: no service 'api'"* ]]
  [[ "$output" == *"a/multi: error: x-pcm.ingress.service: required when compose.yml has several"* ]]
}

@test "provides: an unknown role is an error; a proxy without a labels hook is an error" {
  define "$T/src/a/containers" odd 'services:
  app:
    image: docker.io/library/alpine:3
x-pcm:
  provides: database'
  define "$T/src/a/containers" bare 'services:
  proxy:
    image: docker.io/library/alpine:3
x-pcm:
  provides: proxy'
  define_web app '    port: 3000'
  validate a/odd a/app
  [ "$status" -eq 1 ]
  [[ "$output" == *"x-pcm.provides: unknown role 'database' (known: proxy edge)"* ]]
  [[ "$output" == *"proxy a/bare has no executable labels hook"* ]]
}

@test "the same host on two services is a warning" {
  define_proxy traefik
  define_web one '    port: 3000
    hosts: shared.localhost'
  define_web two '    port: 3000
    hosts: [shared.localhost]'
  validate a/one
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: host shared.localhost is also routed to a/two"* ]]
}

@test "hosts default to <name>.localhost, follow PCM_INGRESS_DOMAIN, and expand variables" {
  define_proxy traefik
  define_web app '    port: 3000'
  define_web env '    port: 3000
    hosts: ${APP_HOSTS:-}'
  load_sources
  [ "$(ingress_hosts a/app)" = "app.localhost" ]
  [ "$(PCM_INGRESS_DOMAIN=lan.example.com ingress_hosts a/app)" = "app.lan.example.com" ]
  [ "$(ingress_hosts a/env)" = "env.localhost" ]
  [ "$(APP_HOSTS=' crm.example.com, crm.example.org ' ingress_hosts a/env)" = "crm.example.com,crm.example.org" ]
}

@test "the override carries the proxy's labels on the ingress compose service only" {
  define_proxy traefik
  define "$T/src/a/containers" app 'services:
  web:
    image: docker.io/library/alpine:3
  worker:
    image: docker.io/library/alpine:3
x-pcm:
  ingress:
    service: web
    port: 3000
    hosts: [a.example.com, b.example.com]'
  # The shared network exists; everything else podman is asked fails
  podman() { [[ "$1 $2" == "network exists" ]]; }
  load_sources
  compose_flags a/app
  local o
  o=$(cat "$(override_file a/app)")
  [[ "$o" == *'io.pcm.ingress: "true"'* ]]
  [[ "$o" == *'test.name: "app"'* ]]
  [[ "$o" == *'test.service: "web"'* ]]
  [[ "$o" == *'test.port: "3000"'* ]]
  [[ "$o" == *'test.healthcheck: "/up"'* ]]
  [[ "$o" == *'test.hosts: "a.example.com,b.example.com"'* ]]
  [[ "$o" == *'test.network: "dev-net"'* ]]
  # Labels only once, under web
  [ "$(grep -c 'io.pcm.ingress' <<< "$o")" -eq 1 ]
  [[ "$(sed -n '/^  worker:/,$p' <<< "$o")" != *test.* ]]
}

@test "label values are quoted for YAML and \$ is escaped from compose interpolation" {
  define_proxy traefik
  hook traefik labels 'echo "rule=Host(\`a\`) || \"q\" \$x"'
  define_web app '    port: 3000'
  podman() { [[ "$1 $2" == "network exists" ]]; }
  load_sources
  compose_flags a/app
  grep -qF 'rule: "Host(`a`) || \"q\" $$x"' "$(override_file a/app)"
  yq eval '.services.web.labels.rule' "$(override_file a/app)" | grep -qF 'Host(`a`) || "q" $$x'
}

@test "the proxy joins the shared network" {
  define_proxy traefik
  podman() { [[ "$1 $2" == "network exists" ]]; }
  load_sources
  compose_flags a/traefik
  grep -q 'external: true' "$(override_file a/traefik)"
}

@test "a proxy's provision output is PCM_INGRESS_*; a plain dependency's stays PCM_<NAME>_*" {
  define_proxy traefik
  hook traefik provision 'for a in "$@"; do if [[ $a == hosts=* ]]; then echo "URL=http://${a#hosts=}:8080"; fi; done'
  define "$T/src/a/containers" db
  hook db provision 'echo URL=postgres://db'
  define "$T/src/a/containers" app 'services:
  web:
    image: docker.io/library/alpine:3
x-pcm:
  depends_on: [db]
  ingress:
    port: 3000'
  load_sources
  PROVISIONED=()
  provision a/app a/traefik a/traefik
  provision a/app a/db db
  [ "${PROVISIONED[0]}" = "PCM_INGRESS_URL=http://app.localhost:8080" ]
  [ "${PROVISIONED[1]}" = "PCM_DB_URL=postgres://db" ]
}
