#!/usr/bin/env bash
# pcm library: x-pcm.ingress (routing a hostname to a service) and x-pcm.provides (roles)
# Sourced by ~/.local/bin/pcm; defines functions only.
#
# A service declares what it serves, never which proxy serves it:
#
#   x-pcm:
#     ingress:
#       service: server        # compose service to route to (default: the only one)
#       port: 3000             # its container port
#       healthcheck: /healthz  # default /up
#       hosts: ${APP_HOSTS}    # comma-separated or a list; default <name>.$PCM_INGRESS_DOMAIN
#
# A proxy is an ordinary definition with `x-pcm.provides: proxy`; PCM_PROXY picks one when more
# than one does. A service with ingress implicitly depends on the active proxy (service_deps), so
# the proxy starts first and the service joins the shared network. The proxy plugs in through
# hooks in its definition directory, run like provision (run_hook) with the ingress as key=value
# args (name service port healthcheck hosts network):
#   labels     while compose_flags writes the service's override; prints label=value lines,
#              set on the ingress compose service
#   provision  prints URL=<public url of the first host>, exported as PCM_INGRESS_URL

# Roles a definition may provide, and the prefix its provision output is exported under: the role's,
# not the definition's name, so swapping the provider changes nothing for the services using it.
# edge: what an edge provider runs (cloudflared); it joins the shared network to reach the proxy.
PCM_ROLES="proxy edge"

role_prefix() {
  case "$1" in
    proxy) echo PCM_INGRESS_ ;;
  esac
}

# The role service $1 provides, if any
service_role() {
  local file
  file=$(compose_file "$1")
  grep -q 'provides:' "$file" 2>/dev/null || return 0
  yq eval '.["x-pcm"].provides // ""' "$file"
}

# The effective services providing role $1
role_providers() {
  local id
  while IFS= read -r id; do
    [[ "$(service_role "$id")" == "$1" ]] && echo "$id"
  done < <(effective_ids)
  return 0
}

# Resolve the active proxy: "ok|<id>", or "err|<why>" when there is none or no single one
resolve_proxy() {
  local id
  local -a providers=()
  if [[ -n "${PCM_PROXY:-}" ]]; then
    if ! id=$(canon "$PCM_PROXY"); then
      echo "err|PCM_PROXY=$PCM_PROXY is not a service"
    elif [[ "$(service_role "$id")" != proxy ]]; then
      echo "err|PCM_PROXY=$PCM_PROXY does not provide proxy (x-pcm.provides: proxy)"
    else
      echo "ok|$id"
    fi
    return 0
  fi
  while IFS= read -r id; do
    [[ -n "$id" ]] && providers+=("$id")
  done < <(role_providers proxy)
  case ${#providers[@]} in
    0) echo "err|no service provides proxy (x-pcm.provides: proxy)" ;;
    1) echo "ok|${providers[0]}" ;;
    *) echo "err|several services provide proxy (${providers[*]}); pick one with PCM_PROXY in anfs.conf" ;;
  esac
}

# The active proxy's id; fails when there is none or no single one
active_proxy() {
  local r
  r=$(resolve_proxy)
  [[ "$r" == ok\|* ]] || return 1
  echo "${r#ok|}"
}

has_ingress() {
  local file
  file=$(compose_file "$1")
  grep -q 'ingress:' "$file" 2>/dev/null || return 1
  [[ "$(yq eval '.["x-pcm"].ingress | tag' "$file")" == "!!map" ]]
}

# Service $1's ingress as written, "service|port|healthcheck|hosts", with the compose service
# defaulted when there is only one, and the healthcheck to /up. Nothing when it has no ingress.
service_ingress() {
  local file csvc port hc hosts
  has_ingress "$1" || return 0
  file=$(compose_file "$1")
  IFS='|' read -r csvc port hc hosts < <(yq eval '.["x-pcm"].ingress | [
      (.service // ""), ((.port // "") | tostring), (.healthcheck // "/up"),
      ((.hosts // "") | ((select(tag == "!!seq") | join(",")), (select(tag != "!!seq") | tostring)))
    ] | join("|")' "$file")
  if [[ -z "$csvc" && "$(yq eval '.services // {} | length' "$file")" == 1 ]]; then
    csvc=$(yq eval '.services | keys | .[0]' "$file")
  fi
  echo "$csvc|$port|$hc|$hosts"
}

# Service $1's hosts, expanded with its env and comma-separated; <name>.$PCM_INGRESS_DOMAIN when
# none are set. The env is the environment, then $PCM_ENV_HOME/<name>.env (where `pcm expose`
# writes hosts), then what load_env resolved; a subshell, so nothing leaks into the caller.
ingress_hosts() (
  local raw h out=""
  local -a list=()
  export_env_overrides "$1"
  IFS="|" read -r _ _ _ raw < <(service_ingress "$1") || true
  raw=$(expand_vars "$1" "$raw")
  IFS=',' read -ra list <<< "$raw"
  for h in ${list[@]+"${list[@]}"}; do
    h="${h//[[:space:]]/}"
    [[ -n "$h" ]] && out+="${out:+,}$h"
  done
  echo "${out:-$(svc_name "$1").${PCM_INGRESS_DOMAIN:-localhost}}"
)

# The key=value args proxy hooks get for service $1's ingress
ingress_args() {
  local csvc port hc
  IFS="|" read -r csvc port hc _ < <(service_ingress "$1") || true
  printf '%s\n' "name=$(svc_name "$1")" "service=$csvc" "port=$port" "healthcheck=$hc" \
    "hosts=$(ingress_hosts "$1")" "network=${PCM_SHARED_NETWORK:-dev-net}"
}

# The proxy service $1 implicitly depends on: the active one, unless it is the proxy itself or
# already names it in x-pcm.depends_on
ingress_dep() {
  local proxy
  has_ingress "$1" || return 0
  proxy=$(active_proxy) || return 0
  [[ "$(svc_name "$proxy")" != "$(svc_name "$1")" ]] && echo "$proxy"
  return 0
}

# True if spec $2 in service $1's dependencies is its implicit proxy dependency
is_ingress_dep() {
  local proxy dep
  has_ingress "$1" || return 1
  proxy=$(active_proxy) || return 1
  dep=$(canon "$2") || return 1
  [[ "$dep" == "$proxy" ]]
}

# Override lines for compose service $2 of service $1: the active proxy's labels hook output, as
# YAML map entries under labels (indented, quoted; $ doubled so compose doesn't interpolate)
ingress_labels() {
  local svc="$1" key="$2" csvc proxy out line k v
  IFS="|" read -r csvc _ _ _ < <(service_ingress "$svc") || true
  [[ -n "$csvc" && "$csvc" == "$key" ]] || return 0
  printf '      %s: "true"\n' "$PCM_LABEL_INGRESS"
  proxy=$(active_proxy) || return 0
  has_hook labels "$proxy" || return 0
  if ! out=$(run_hook labels "$svc" "$proxy" "$proxy"); then
    echo "pcm: $(svc_name "$proxy")'s labels hook failed for $(svc_name "$svc"); it will not be routed" >&2
    return 0
  fi
  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    k="${line%%=*}" v="${line#*=}"
    v="${v//\\/\\\\}" v="${v//\"/\\\"}" v="${v//\$/\$\$}"
    printf '      %s: "%s"\n' "$k" "$v"
  done <<< "$out"
}

PCM_LABEL_INGRESS=io.pcm.ingress

# Hostnames: dot-separated labels of letters, digits and inner hyphens
valid_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]
}

# x-pcm.provides must be a known role; x-pcm.ingress must be routable by the active proxy
check_ingress() {
  local svc="$1" role csvc port hc hosts h r proxy other services file
  local -a list=()
  file=$(compose_file "$svc")

  role=$(service_role "$svc")
  if [[ -n "$role" && " $PCM_ROLES " != *" $role "* ]]; then
    v_error "$svc" "x-pcm.provides: unknown role '$role' (known: $PCM_ROLES)"
  fi

  has_ingress "$svc" || return 0
  IFS="|" read -r csvc port hc _ < <(service_ingress "$svc") || true
  services=" $(yq eval '.services // {} | keys | .[]' "$file" | paste -sd ' ' -) "

  if [[ -z "$csvc" ]]; then
    v_error "$svc" "x-pcm.ingress.service: required when compose.yml has several services"
  elif [[ "$services" != *" $csvc "* ]]; then
    v_error "$svc" "x-pcm.ingress.service: no service '$csvc' in compose.yml"
  fi
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    v_error "$svc" "x-pcm.ingress.port: '${port}' is not a port (the container port to route to)"
  fi
  [[ "$hc" == /* ]] || v_error "$svc" "x-pcm.ingress.healthcheck: '$hc' must be a path starting with /"

  hosts=$(ingress_hosts "$svc")
  IFS=',' read -ra list <<< "$hosts"
  for h in ${list[@]+"${list[@]}"}; do
    valid_hostname "$h" || v_error "$svc" "x-pcm.ingress.hosts: '$h' is not a hostname"
  done

  r=$(resolve_proxy)
  if [[ "$r" == err\|* ]]; then
    v_error "$svc" "x-pcm.ingress: ${r#err|}"
  else
    proxy="${r#ok|}"
    has_hook labels "$proxy" ||
      v_error "$svc" "x-pcm.ingress: proxy $proxy has no executable labels hook"
  fi

  # The same host on two services: the proxy can route it to only one
  while IFS= read -r other; do
    [[ -n "$other" && "$(svc_name "$other")" != "$(svc_name "$svc")" ]] || continue
    has_ingress "$other" || continue
    load_env "$other" 2>/dev/null || true
    for h in ${list[@]+"${list[@]}"}; do
      [[ ",$(ingress_hosts "$other")," == *",$h,"* ]] && v_warn "$svc" "host $h is also routed to $other"
    done
  done < <(effective_ids)

  check_edges "$svc"
}
