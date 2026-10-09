#!/usr/bin/env bash
# pcm library: edges, which get internet traffic to the proxy for a service's ingress hosts
# Sourced by ~/.local/bin/pcm; defines functions only.
#
# $PCM_CONFIG_HOME/edges.yml maps domains to edge providers; a host uses the longest domain it is
# under, and a host under none (like <name>.localhost) is only routed by the proxy:
#
#   roteoh.com:     { provider: cloudflare-tunnel }
#   int.roteoh.com: { provider: tailnet }
#
# A provider is an executable, $PCM_CONFIG_HOME/edges/<provider> or pcm's own edges/<provider>,
# called with a verb:
#   deps                    pcm services the edge needs running (printed one per line); the
#                           service implicitly depends on them, like on the proxy
#   scheme                  the public scheme (https), for PCM_INGRESS_URL
#   check                   prints what is missing (credentials) and fails; run by validate
#   add <host> [k=v...]     publish host (DNS and so on); idempotent. Run on `pcm up`
#   remove <host> [k=v...]  undo add; idempotent. Run on `pcm remove`
# add and remove also get origin=<the proxy's HTTP address on the shared network>, and the
# domain's other edges.yml keys as k=v. check, add and remove run under fnox when a fnox config
# applies in $PCM_CONFIG_HOME, so credentials come from 1Password rather than the environment.

edges_file() {
  echo "$PCM_CONFIG_HOME/edges.yml"
}

# The edges.yml entry host $1 falls under, "domain|provider"; nothing when none does
host_edge() {
  local host="$1" file domain provider best="" best_provider=""
  file=$(edges_file)
  [[ -f "$file" ]] || return 0
  while IFS='|' read -r domain provider; do
    [[ -n "$domain" && ( "$host" == "$domain" || "$host" == *".$domain" ) ]] || continue
    if (( ${#domain} > ${#best} )); then best="$domain" best_provider="$provider"; fi
  done < <(yq eval 'to_entries | .[] | .key + "|" + (.value.provider // "")' "$file")
  [[ -z "$best" ]] || echo "$best|$best_provider"
}

# The domain's edges.yml keys other than provider, as k=v
edge_options() {
  yq eval ".[\"$1\"] | to_entries | .[] | select(.key != \"provider\") | .key + \"=\" + (.value | tostring)" "$(edges_file)"
}

# Path of edge provider $1
edge_bin() {
  local dir
  for dir in "$PCM_CONFIG_HOME/edges" "${PCM_LIB_DIR:-$HOME/.local/lib/pcm}/edges"; do
    [[ -x "$dir/$1" ]] && { echo "$dir/$1"; return 0; }
  done
  return 1
}

# Call provider $1 with verb and args, without credentials (deps, scheme)
edge_call() {
  local bin
  bin=$(edge_bin "$1") || return 1
  shift
  "$bin" "$@"
}

# Call provider $1 with verb and args, with credentials: under fnox when a config applies
edge_run() {
  local bin
  if ! bin=$(edge_bin "$1"); then
    echo "pcm: no edge provider '$1' (in $PCM_CONFIG_HOME/edges or pcm's edges/)" >&2
    return 1
  fi
  shift
  if command -v fnox >/dev/null 2>&1 && uses_fnox "$PCM_CONFIG_HOME"; then
    (cd "$PCM_CONFIG_HOME" && exec fnox exec -- "$bin" "$@")
  else
    "$bin" "$@"
  fi
}

# Service $1's hosts that an edge publishes, "host|domain|provider" per line (local is no edge)
service_edge_hosts() {
  local h e
  local -a list=()
  has_ingress "$1" || return 0
  IFS=',' read -ra list <<< "$(ingress_hosts "$1")"
  for h in ${list[@]+"${list[@]}"}; do
    e=$(host_edge "$h")
    [[ -n "$e" && "${e#*|}" != local ]] && echo "$h|$e"
  done
  return 0
}

# The pcm services service $1's edges need running (implicit dependencies), one per line
edge_deps() {
  local provider seen=" "
  while IFS='|' read -r _ _ provider; do
    [[ -n "$provider" && "$seen" != *" $provider "* ]] || continue
    seen+="$provider "
    edge_call "$provider" deps 2>/dev/null || true
  done < <(service_edge_hosts "$1")
  return 0
}

# The public URL of service $1's first host when an edge publishes it ("<scheme>://<host>"),
# which replaces the proxy's local URL as PCM_INGRESS_URL; nothing when the first host is local
ingress_public_url() {
  local first e scheme
  has_ingress "$1" || return 0
  first=$(ingress_hosts "$1")
  first="${first%%,*}"
  e=$(host_edge "$first")
  [[ -n "$e" && "${e#*|}" != local ]] || return 0
  scheme=$(edge_call "${e#*|}" scheme 2>/dev/null) || scheme=https
  echo "${scheme:-https}://$first"
}

# The proxy's HTTP address on the shared network, which edges send traffic to. A proxy serves
# HTTP on its container's port 80 and is reachable on the shared network by its name (the alias
# compose_flags gives a role provider).
edge_origin() {
  local proxy
  proxy=$(active_proxy) || return 1
  echo "http://$(svc_name "$proxy"):80"
}

# Run verb $2 (add or remove) of each edge for service $1's published hosts
edges_apply() {
  local svc="$1" verb="$2" host domain provider origin line rc=0
  local -a opts
  origin=$(edge_origin) || origin=""
  while IFS='|' read -r host domain provider; do
    [[ -n "$host" ]] || continue
    opts=()
    while IFS= read -r line; do [[ -n "$line" ]] && opts+=("$line"); done < <(edge_options "$domain")
    echo "pcm: $provider: $verb $host" >&2
    PCM_SERVICE="$(svc_name "$svc")" edge_run "$provider" "$verb" "$host" ${origin:+"origin=$origin"} \
      ${opts[@]+"${opts[@]}"} >&2 || { echo "pcm: $provider could not $verb $host" >&2; rc=1; }
  done < <(service_edge_hosts "$svc")
  return $rc
}

edges_publish()   { edges_apply "$1" add; }
edges_unpublish() { edges_apply "$1" remove; }

# Every edges.yml provider must exist and have what it needs (check); hosts with a public name
# but no edge are only routed locally, which is worth a warning
check_edges() {
  local svc="$1" host domain provider out h e
  local -a list=()
  has_ingress "$svc" || return 0
  while IFS='|' read -r host domain provider; do
    [[ -n "$host" ]] || continue
    if [[ -z "$provider" ]]; then
      v_error "$svc" "edges.yml: $domain has no provider"
    elif ! edge_bin "$provider" >/dev/null; then
      v_error "$svc" "edges.yml: $domain uses unknown edge provider '$provider'"
    elif ! out=$(edge_run "$provider" check 2>&1); then
      v_error "$svc" "edge $provider for $host: ${out:-check failed}"
    fi
  done < <(service_edge_hosts "$svc")

  IFS=',' read -ra list <<< "$(ingress_hosts "$svc")"
  for h in ${list[@]+"${list[@]}"}; do
    [[ "$h" == localhost || "$h" == *.localhost ]] && continue
    e=$(host_edge "$h")
    [[ -n "$e" ]] || v_warn "$svc" "host $h is under no domain in edges.yml: routed by the proxy, but nothing publishes it"
  done
  return 0
}
