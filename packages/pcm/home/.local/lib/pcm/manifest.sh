#!/usr/bin/env bash
# pcm library: container.yml, a service's manifest; its memory, which is the service's limit and
# what `pcm up` checks the host (or the podman machine) has room for; the machine resize command.
# Sourced by ~/.local/bin/pcm; defines functions only.
#
#   version: 0.1.0
#   description: The anfs dashboard
#   upstream: docker.io/library/node:22     what it is built from (attribution)
#   license: MIT
#   url: https://github.com/anfs-io/anfs-ui
#   memory: 512m                            what it needs; also its limit
#   toolkit: write                          the toolkit's API (anfs rpc), read or write: pcm hands
#                                           the service the address and its grant's token (macOS)
#                                           or the grant's socket (Linux); absent, nothing
#
# Every key is optional beside version; an unknown one is a validate error. compose.yml stays
# plain compose: nothing here moves into it. A service without a container.yml is still valid
# (version -), with a warning.

PCM_MANIFEST_KEYS="version description upstream license url memory toolkit"

# MiB the podman machine gets on top of what its containers need: its own OS
: "${PCM_MACHINE_HEADROOM:=1024}"

manifest_file() { echo "$(svc_dir "$1")/container.yml"; }

# Field $2 of service $1's container.yml; empty when the file or the key is absent
manifest_get() {
  local file
  file=$(manifest_file "$1")
  [[ -f "$file" ]] || return 0
  yq eval ".$2 // \"\" | tostring" "$file" 2>/dev/null || true
}

# Service $1's manifest fields, in PCM_MANIFEST_KEYS order, into the array MANIFEST (empty
# strings when there is no container.yml)
manifest_fields() {
  local file
  file=$(manifest_file "$1")
  MANIFEST=("" "" "" "" "" "" "")
  [[ -f "$file" ]] || return 0
  mapfile -t MANIFEST < <(yq eval '[.version, .description, .upstream, .license, .url, .memory, .toolkit] | .[] | (. // "") | tostring' "$file" 2>/dev/null)
  [[ ${#MANIFEST[@]} -eq 7 ]] || MANIFEST=("" "" "" "" "" "" "")
}

# A memory size (512m, 2g, 1.5g, 1024k; a plain number is bytes, as in compose) in MiB, rounded
# up. Fails on anything else.
mem_mib() {
  local v="${1,,}" n unit
  v="${v%b}"
  [[ "$v" =~ ^([0-9]+(\.[0-9]+)?)([kmg]?)$ ]] || return 1
  n="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[3]}"
  case "$unit" in
    "") awk -v n="$n" 'BEGIN { m = n / 1048576; printf "%d\n", (m == int(m)) ? m : int(m) + 1 }' ;;
    k)  awk -v n="$n" 'BEGIN { m = n / 1024; printf "%d\n", (m == int(m)) ? m : int(m) + 1 }' ;;
    m)  awk -v n="$n" 'BEGIN { printf "%d\n", (n == int(n)) ? n : int(n) + 1 }' ;;
    g)  awk -v n="$n" 'BEGIN { m = n * 1024; printf "%d\n", (m == int(m)) ? m : int(m) + 1 }' ;;
  esac
}

# Service $1's memory: in MiB, or empty when it declares none (or an invalid one: validate says so)
service_memory() {
  local m
  m=$(manifest_get "$1" memory)
  [[ -n "$m" ]] || return 0
  mem_mib "$m" 2>/dev/null || true
}

# MiB as a person reads it: 1536 -> 1.5G, 512 -> 512M
mib_human() {
  awk -v m="$1" 'BEGIN { if (m >= 1024) { g = m / 1024; if (g == int(g)) printf "%dG\n", g; else printf "%.1fG\n", g } else printf "%dM\n", m }'
}

# validate: container.yml is a map of known keys with a version; memory parses and is what any
# compose mem_limit says
check_manifest() {
  local svc="$1" file k version memory want key limit toolkit
  file=$(manifest_file "$svc")
  if [[ ! -f "$file" ]]; then
    v_warn "$svc" "no container.yml (version, description, upstream, license, url, memory, toolkit)"
    return 0
  fi
  if [[ "$(yq eval 'tag' "$file" 2>/dev/null)" != "!!map" ]]; then
    v_error "$svc" "container.yml is not a YAML map"
    return 0
  fi
  while IFS= read -r k; do
    [[ -z "$k" || " $PCM_MANIFEST_KEYS " == *" $k "* ]] ||
      v_error "$svc" "container.yml: unknown key '$k' (known: $PCM_MANIFEST_KEYS)"
  done < <(yq eval 'keys | .[]' "$file")
  version=$(manifest_get "$svc" version)
  [[ -n "$version" ]] || v_error "$svc" "container.yml: version: is required"
  toolkit=$(manifest_get "$svc" toolkit)
  [[ -z "$toolkit" || "$toolkit" == read || "$toolkit" == write ]] ||
    v_error "$svc" "container.yml: toolkit '$toolkit' is read or write"

  memory=$(manifest_get "$svc" memory)
  [[ -n "$memory" ]] || return 0
  if ! want=$(mem_mib "$memory"); then
    v_error "$svc" "container.yml: memory '$memory' is not a size (512m, 2g)"
    return 0
  fi
  # memory: is the limit; a compose mem_limit that says otherwise is a second answer
  while IFS='|' read -r key limit; do
    [[ -n "$key" && -n "$limit" ]] || continue
    limit=$(expand_vars "$svc" "$limit")
    [[ "$(mem_mib "$limit" 2>/dev/null)" == "$want" ]] ||
      v_error "$svc" "services.$key.mem_limit $limit differs from container.yml memory $memory (memory: is the limit; drop mem_limit)"
  done < <(yq eval '.services // {} | to_entries | .[] | .key + "|" + ((.value.mem_limit // "") | tostring)' "$(compose_file "$svc")")
  return 0
}

# The override line that makes memory: compose service $2's limit, whatever compose says
_override_memory() {
  local mib
  mib=$(service_memory "$1")
  [[ -n "$mib" ]] || return 0
  printf '    mem_limit: "%sm"\n' "$mib"
}

# --- the memory check before `pcm up` -----------------------------------------

# The pcm ids with a running container, one per line
running_ids() {
  local containers _cid _cname state pid _status
  containers=$(pcm_containers 2>/dev/null) || return 0
  while IFS='|' read -r _cid _cname state pid _status; do
    [[ -n "$pid" && "$state" == running ]] && echo "$pid"
  done <<< "$containers" | sort -u
}

# MiB the host has available (Linux): MemAvailable, via free
host_available_mib() {
  free -m 2>/dev/null | awk '/^Mem:/ { print $7; exit }'
}

# MiB the podman machine has (macOS)
machine_memory_mib() {
  podman machine inspect --format '{{.Resources.Memory}}' 2>/dev/null | head -n1
}

# Sum of the memory of ids $@, in MiB
sum_memory() {
  local id m total=0
  for id in "$@"; do
    m=$(service_memory "$id")
    total=$((total + ${m:-0}))
  done
  echo "$total"
}

# Before `pcm up`: is there room for services $@ (the closure), beside what already runs?
#   Linux: what starts must fit in the host's available memory (what runs already uses its own)
#   macOS: what runs plus what starts must fit in the podman machine. When it does not and no
#          container runs, the machine is resized (stop, set, start) to the sum plus headroom;
#          when something runs, refuse: a resize would stop it
# Services without memory: count as 0, so none declared means no check.
check_memory() {
  local id running_names=" " new=0 used=0 have want
  local -a running=() starting=()
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    running+=("$id")
    running_names+="$(svc_name "$id") "
  done < <(running_ids)
  for id in "$@"; do
    [[ "$running_names" == *" $(svc_name "$id") "* ]] || starting+=("$id")
  done
  new=$(sum_memory ${starting[@]+"${starting[@]}"})
  (( new > 0 )) || return 0
  used=$(sum_memory ${running[@]+"${running[@]}"})

  if [[ "$OSTYPE" != darwin* ]]; then
    have=$(host_available_mib)
    [[ "$have" =~ ^[0-9]+$ ]] || return 0
    (( new <= have )) && return 0
    anfs_warn "not starting ${starting[*]}: they need $(mib_human "$new"), the host has $(mib_human "$have") available"
    return 1
  fi

  have=$(machine_memory_mib)
  [[ "$have" =~ ^[0-9]+$ ]] || return 0
  (( used + new <= have )) && return 0
  want=$((used + new + PCM_MACHINE_HEADROOM))

  local others
  others=$(podman ps --format '{{.Names}}' 2>/dev/null | paste -sd ' ' -)
  if [[ -z "$others" ]]; then
    anfs_warn "the podman machine has $(mib_human "$have"); ${starting[*]} need $(mib_human "$new"): resizing it to $(mib_human "$want")"
    pcm_machine_resize "$want"
    return
  fi
  anfs_warn "not starting ${starting[*]}: they need $(mib_human "$new") beside the $(mib_human "$used") of what runs; the podman machine has $(mib_human "$have")"
  anfs_warn "a resize stops these containers: $others"
  anfs_warn "to resize it: pcm machine resize $(mib_human "$want")"
  return 1
}

# Stop the podman machine if it runs, give it $1 MiB, start it
pcm_machine_resize() {
  local mib="$1"
  if [[ "$(podman machine inspect --format '{{.State}}' 2>/dev/null)" == running ]]; then
    podman machine stop >&2 || { anfs_warn "podman machine stop failed"; return 1; }
  fi
  podman machine set --memory "$mib" >&2 || { anfs_warn "podman machine set --memory $mib failed"; return 1; }
  podman machine start >&2 || { anfs_warn "podman machine start failed"; return 1; }
}

# `pcm machine resize [size]` (macOS): stop, set, start the podman machine. No size: what runs
# needs, plus headroom. Confirms when containers run, since stopping the machine stops them.
cmd_machine_resize() {
  local size="${1:-}" mib id others have
  [[ "$OSTYPE" == darwin* ]] || { anfs_warn "there is no podman machine on Linux: podman runs natively"; return 1; }
  [[ -n "$(podman machine list --format '{{.Name}}' 2>/dev/null)" ]] ||
    { anfs_warn "there is no podman machine yet; pcm up creates it"; return 1; }
  if [[ -n "$size" ]]; then
    mib=$(mem_mib "$size") || { anfs_warn "'$size' is not a size (4g, 6144m)"; return "$CLI_EX_USAGE"; }
  else
    local -a running=()
    while IFS= read -r id; do [[ -n "$id" ]] && running+=("$id"); done < <(running_ids)
    mib=$(( $(sum_memory ${running[@]+"${running[@]}"}) + PCM_MACHINE_HEADROOM ))
  fi
  have=$(machine_memory_mib)
  if [[ "$have" == "$mib" ]]; then
    echo "pcm: the podman machine already has $(mib_human "$mib")"
    return 0
  fi
  others=$(podman ps --format '{{.Names}}' 2>/dev/null | paste -sd ' ' -)
  [[ -z "$others" ]] || anfs_confirm "resizing stops these containers: $others" \
    "Stop the podman machine (and $others) to give it $(mib_human "$mib")?"
  pcm_machine_resize "$mib" || return 1
  echo "pcm: the podman machine has $(mib_human "$mib")${have:+ (was $(mib_human "$have"))}"
  [[ -z "$others" ]] || echo "pcm: stopped with it: $others (start them again with pcm up)"
}
