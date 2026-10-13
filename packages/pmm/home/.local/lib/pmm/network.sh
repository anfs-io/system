#!/usr/bin/env bash
# pmm library: networks — definitions across the sources, and the `network` commands.
# Sourced by ~/.local/bin/pmm; functions only.
#
# A network is networks/<name>/network.yml in a source, or in $PMM_NETWORKS_HOME (made on the
# spot, and first). Its id is `source/name`; the name alone is the network, as with machines.
#
# On Linux a nat or isolated network is a libvirt network, pmm-<name>, on a bridge of the same
# name: libvirt makes the bridge and runs dnsmasq on it for DHCP and DNS. A bridged network is a
# bridge the host already has; pmm defines nothing for it. Either way the bridge is added to the
# list qemu's bridge helper is allowed ($PMM_BRIDGE_CONF), since pmm starts qemu itself.
# What was installed is recorded in $PMM_DATA_HOME/networks/<name>/state.yml, so a network can be
# listed and removed after its definition has gone.
#
# What the host needs for any of this (libvirt, the helper's setuid bit, the allow list) is the
# pmm-network package's to set up, once and as root. PMM_NET_BACKEND is libvirt on Linux and none
# elsewhere.

PMM_NET_KEYS="kind subnet interface domain description"
PMM_NET_KINDS="nat isolated bridged"

NET_SRC_NAMES=() NET_SRC_DIRS=()

# The sources holding networks/, in priority order, the local one first. Reads the source list
# catalog_load collected (load_machines calls this).
load_networks() {
  local i dir
  NET_SRC_NAMES=("$PMM_LOCAL_SOURCE") NET_SRC_DIRS=("$PMM_NETWORKS_HOME")
  for i in "${!GITSRC_NAMES[@]}"; do
    [[ "${GITSRC_NAMES[$i]}" != "$PMM_LOCAL_SOURCE" ]] || continue
    dir="$(gitsrc_dir "${GITSRC_NAMES[$i]}")/networks"
    [[ -d "$dir" ]] || continue
    NET_SRC_NAMES+=("${GITSRC_NAMES[$i]}") NET_SRC_DIRS+=("$dir")
  done
}

net_source_dir() {
  local i
  for i in "${!NET_SRC_NAMES[@]}"; do
    [[ "${NET_SRC_NAMES[$i]}" == "$1" ]] && { echo "${NET_SRC_DIRS[$i]}"; return 0; }
  done
  return 1
}

net_def_dir() {
  local dir
  dir=$(net_source_dir "${1%%/*}") || return 1
  echo "$dir/${1#*/}"
}
net_yml() { echo "$(net_def_dir "$1")/network.yml"; }

# name or source/name -> id; a plain name is the highest-priority source that has it
net_canon() {
  local spec="$1" i
  [[ -n "$spec" && "$spec" != */*/* ]] || return 1
  if [[ "$spec" == */* ]]; then
    [[ -f "$(net_def_dir "$spec" 2>/dev/null)/network.yml" ]] || return 1
    echo "$spec"
    return 0
  fi
  for i in "${!NET_SRC_NAMES[@]}"; do
    [[ -f "${NET_SRC_DIRS[$i]}/$spec/network.yml" ]] && { echo "${NET_SRC_NAMES[$i]}/$spec"; return 0; }
  done
  return 1
}

net_all_ids() {
  local i dir
  for i in "${!NET_SRC_NAMES[@]}"; do
    for dir in "${NET_SRC_DIRS[$i]}"/*/; do
      [[ -f "${dir}network.yml" ]] && echo "${NET_SRC_NAMES[$i]}/$(basename "$dir")"
    done
  done
  return 0
}

# A scalar from network.yml, or <default>
# Usage: net_get <id> <yq path> [default]
net_get() {
  local v
  v=$(yq -r "($2) | select(. != null)" "$(net_yml "$1")" 2>/dev/null) || v=""
  [[ -n "$v" ]] && echo "$v" || echo "${3:-}"
}

# The kernel caps an interface name at 15 characters, and the bridge is pmm-<name>
net_name_ok() { name_ok "$1" && [[ ${#1} -le 11 ]]; }

# Resolve a network spec. Sets N_NAME, and N_ID to its definition's id, or to nothing for an
# installed network whose definition is gone. Dies when there is neither, or on a shadowed id.
net_find() {
  local spec="$1" id
  N_ID="" N_NAME="${spec#*/}"
  if id=$(net_canon "$spec"); then
    N_ID=$(net_canon "$N_NAME")
    [[ "$N_ID" == "$id" ]] || die "$id is shadowed by $N_ID: the network $N_NAME is $N_ID's"
    return 0
  fi
  [[ "$spec" != */* ]] && net_installed "$spec" && return 0
  die "network '$spec' not found (see: pmm network list)"
}

# --- addresses ----------------------------------------------------------------------------------

# 10.20.0.11 -> an integer; fails on anything that is not a dotted quad
ip_int() {
  local a b c d
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  (( 10#$a < 256 && 10#$b < 256 && 10#$c < 256 && 10#$d < 256 )) || return 1
  echo $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}
int_ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }

# Take a subnet apart: 10.20.0.0/24 sets SN_BASE and SN_SIZE (integers) and SN_MASK (dotted).
# Fails unless it is a network address with a prefix of 16 to 28.
# The host is the first address. The upper half is what DHCP hands out to whoever asks; the rest,
# from the second address, is where a machine with no address of its own is given one to keep.
subnet_parse() {
  local base prefix
  [[ "$1" == */* ]] || return 1
  base=$(ip_int "${1%/*}") || return 1
  prefix="${1#*/}"
  [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix >= 16 && prefix <= 28 )) || return 1
  SN_SIZE=$(( 1 << (32 - prefix) ))
  (( base % SN_SIZE == 0 )) || return 1
  SN_BASE=$base
  SN_MASK=$(int_ip $(( (0xffffffff << (32 - prefix)) & 0xffffffff )))
}

# True when <address> is one a machine may have in <subnet>: inside it, not the network's own,
# the host's or the broadcast address
subnet_has() {
  local a
  subnet_parse "$1" || return 1
  a=$(ip_int "$2") || return 1
  (( a > SN_BASE + 1 && a < SN_BASE + SN_SIZE - 1 ))
}

# --- what is installed --------------------------------------------------------------------------

net_state_file() { echo "$PMM_DATA_HOME/networks/$1/state.yml"; }
net_installed()  { [[ -f "$(net_state_file "$1")" ]]; }
net_state_get() {
  [[ -f "$(net_state_file "$1")" ]] || return 0
  yq -r "($2) | select(. != null)" "$(net_state_file "$1")" 2>/dev/null || true
}

# The bridge machines attach to: pmm's own for nat and isolated, the host's for bridged
# Usage: net_bridge <kind> <name> <interface>
net_bridge() { [[ "$1" == bridged ]] && echo "$3" || echo "pmm-$2"; }

net_virsh() { "${PMM_VIRSH:-virsh}" -c "$PMM_LIBVIRT_URI" "$@"; }

bridge_exists() { [[ -d "$PMM_SYS_NET/$1/bridge" ]]; }

# What this host lacks for networks, one line each; nothing when it is ready
net_host_problems() {
  [[ "$PMM_NET_CHECK" == true ]] || return 0
  if [[ "$PMM_NET_BACKEND" != libvirt ]]; then
    echo "networks are built on Linux only so far; this host has none"
    return 0
  fi
  if ! command -v "${PMM_VIRSH:-virsh}" >/dev/null 2>&1; then
    echo "libvirt is not installed"
  elif ! net_virsh net-list --name >/dev/null 2>&1; then
    echo "libvirt's system daemon does not answer $(id -un) (the libvirt group; log in again after it is added)"
  fi
  [[ -u "$PMM_BRIDGE_HELPER" ]] || echo "qemu's bridge helper is not setuid ($PMM_BRIDGE_HELPER)"
  [[ -w "$PMM_BRIDGE_CONF" ]] || echo "$PMM_BRIDGE_CONF is missing or not writable by $(id -un)"
}

net_require() {
  local problems
  problems=$(net_host_problems)
  [[ -z "$problems" ]] && return 0
  printf '%s\n' "$problems" | sed 's/^/  /' >&2
  die "this host is not set up for networks (ppm install core/pmm-network)"
}

# Let qemu's bridge helper use a bridge, or stop letting it. The file is rewritten in place: its
# directory is root's.
bridge_allow() {
  grep -qx "allow $1" "$PMM_BRIDGE_CONF" 2>/dev/null && return 0
  echo "allow $1" >> "$PMM_BRIDGE_CONF" || die "could not add $1 to $PMM_BRIDGE_CONF (ppm install core/pmm-network)"
}
bridge_disallow() {
  local rest
  [[ -w "$PMM_BRIDGE_CONF" ]] || return 0
  rest=$(grep -vx "allow $1" "$PMM_BRIDGE_CONF" || true)
  printf '%s' "${rest:+$rest$'\n'}" > "$PMM_BRIDGE_CONF"
}

# The libvirt network for a nat or isolated definition
# Usage: net_xml <name> <kind> <subnet> <domain>
net_xml() {
  local name="$1" kind="$2" domain="$4"
  subnet_parse "$3" || return 1
  echo "<network>"
  echo "  <name>pmm-$name</name>"
  [[ "$kind" != nat ]] || echo "  <forward mode='nat'/>"
  echo "  <bridge name='pmm-$name' stp='on' delay='0'/>"
  [[ -z "$domain" ]] || echo "  <domain name='$domain' localOnly='yes'/>"
  echo "  <ip address='$(int_ip $((SN_BASE + 1)))' netmask='$SN_MASK'>"
  echo "    <dhcp>"
  echo "      <range start='$(int_ip $((SN_BASE + SN_SIZE / 2)))' end='$(int_ip $((SN_BASE + SN_SIZE - 2)))'/>"
  echo "    </dhcp>"
  echo "  </ip>"
  echo "</network>"
}

# active | inactive | missing, for an installed network
net_status() {
  local name="$1"
  if [[ "$(net_state_get "$name" .kind)" == bridged ]]; then
    bridge_exists "$(net_state_get "$name" .bridge)" && echo active || echo missing
  elif [[ "$PMM_NET_BACKEND" != libvirt ]]; then echo missing
  elif net_virsh net-list --name 2>/dev/null | grep -x "pmm-$name" >/dev/null; then echo active
  elif net_virsh net-list --all --name 2>/dev/null | grep -x "pmm-$name" >/dev/null; then echo inactive
  else echo missing
  fi
}

# The machines on a network, from their records, one per line
net_machines() {
  local f n
  for f in "$PMM_DATA_HOME"/machines/*/state.yml; do
    [[ -f "$f" ]] || continue
    n=$(N="$1" yq -r '[.interfaces[]? | select(.network == strenv(N))] | length' "$f" 2>/dev/null) || n=0
    [[ "${n:-0}" == 0 ]] || basename "$(dirname "$f")"
  done
  return 0
}

# Install a network from its definition: define it, have it start with the host, start it, and
# let qemu attach to its bridge. Again on an installed one only makes sure it is up.
net_install() {
  local id="$1" name kind subnet domain iface bridge f tmp
  name="${id#*/}"
  validate_network_quiet "$id" || die "$id does not validate (pmm validate)"
  net_require
  kind=$(net_get "$id" .kind) subnet=$(net_get "$id" .subnet)
  domain=$(net_get "$id" .domain) iface=$(net_get "$id" .interface)
  bridge=$(net_bridge "$kind" "$name" "$iface")
  if net_installed "$name"; then
    [[ "$(net_state_get "$name" .kind)" == "$kind" && "$(net_state_get "$name" .subnet)" == "$subnet" &&
       "$(net_state_get "$name" .bridge)" == "$bridge" && "$(net_state_get "$name" .domain)" == "$domain" ]] ||
      die "$name is installed with other settings; pmm network remove $name, then install it again"
    net_up "$name"
    echo "$name is installed ($kind, $(net_status "$name"))"
    return 0
  fi
  if [[ "$kind" == bridged ]]; then
    bridge_exists "$bridge" || die "$name: the host has no bridge '$bridge' (a bridged network uses one that is there; pmm does not make it)"
  else
    tmp=$(mktemp "${TMPDIR:-/tmp}/pmm-net.XXXXXX")
    net_xml "$name" "$kind" "$subnet" "$domain" > "$tmp"
    net_virsh net-define "$tmp" >/dev/null || { rm -f "$tmp"; die "libvirt did not take $name's definition"; }
    rm -f "$tmp"
    net_virsh net-autostart "pmm-$name" >/dev/null || warn "$name will not start with the host"
    net_virsh net-start "pmm-$name" >/dev/null ||
      { net_virsh net-undefine "pmm-$name" >/dev/null 2>&1 || true; die "$name did not start (is $subnet in use on this host?)"; }
  fi
  bridge_allow "$bridge"
  f=$(net_state_file "$name")
  mkdir -p "$(dirname "$f")"
  ID="$id" KIND="$kind" SUBNET="$subnet" BRIDGE="$bridge" DOMAIN="$domain" AT="$(now_iso)" \
    yq -n '.id = strenv(ID) | .kind = strenv(KIND) | .bridge = strenv(BRIDGE) | .created_at = strenv(AT)
           | .subnet = (strenv(SUBNET) | select(. != "")) | .domain = (strenv(DOMAIN) | select(. != ""))' > "$f"
  echo "Installed network $name ($kind, ${subnet:-on $bridge})"
}

# Make sure an installed network is there to attach to: start a stopped one
net_up() {
  local name="$1"
  case "$(net_status "$name")" in
    active) ;;
    inactive) net_virsh net-start "pmm-$name" >/dev/null || die "network $name did not start" ;;
    *) die "network $name is gone from this host (pmm network remove $name, then install it again)" ;;
  esac
  bridge_allow "$(net_state_get "$name" .bridge)"
}

# Take a network away: stop and undefine it, and forget its bridge
net_delete() {
  local name="$1"
  if [[ "$(net_state_get "$name" .kind)" != bridged && "$PMM_NET_BACKEND" == libvirt ]]; then
    net_virsh net-destroy "pmm-$name" >/dev/null 2>&1 || true
    net_virsh net-undefine "pmm-$name" >/dev/null 2>&1 || true
    bridge_disallow "pmm-$name"
  fi
  rm -rf "${PMM_DATA_HOME:?}/networks/$name"
}

# --- reservations -------------------------------------------------------------------------------

# A fixed address is a DHCP reservation in the network's dnsmasq, and the machine's name there
# Usage: net_reserve <add|delete> <network> <mac> <machine> <address>
net_reserve() {
  local verb="$1" name="$2" xml="<host mac='$3' name='$4' ip='$5'/>"
  local -a flags=(--config)
  [[ "$(net_status "$name")" != active ]] || flags+=(--live)
  if [[ "$verb" == add ]]; then
    net_virsh net-update "pmm-$name" delete ip-dhcp-host "<host mac='$3'/>" "${flags[@]}" >/dev/null 2>&1 || true
    net_virsh net-update "pmm-$name" add ip-dhcp-host "$xml" "${flags[@]}" >/dev/null ||
      die "could not reserve $5 for $4 on $name"
  else
    net_virsh net-update "pmm-$name" delete ip-dhcp-host "$xml" "${flags[@]}" >/dev/null 2>&1 || true
  fi
}

# The addresses machines hold on a network, from their records, one per line
net_addresses() {
  local f
  for f in "$PMM_DATA_HOME"/machines/*/state.yml; do
    [[ -f "$f" ]] || continue
    N="$1" yq -r '.interfaces[]? | select(.network == strenv(N)) | .address | select(. != null and . != "")' "$f" 2>/dev/null || true
  done
}

# The first address of an installed network nothing holds, from its second upward
net_free_address() {
  local name="$1" taken a
  subnet_parse "$(net_state_get "$name" .subnet)" || return 1
  taken=" $(net_addresses "$name" | paste -sd' ' -) "
  for (( a = SN_BASE + 2; a < SN_BASE + SN_SIZE / 2; a++ )); do
    [[ "$taken" == *" $(int_ip "$a") "* ]] || { int_ip "$a"; return 0; }
  done
  return 1
}

# --- validate -----------------------------------------------------------------------------------

# Check one network definition, printing its problems; adds to V_ERRORS / V_WARNINGS
validate_network() {
  local id="$1" yml k kind subnet iface domain other
  yml=$(net_yml "$id")
  yq -e 'true' "$yml" >/dev/null 2>&1 || { _v_err "network.yml does not parse"; return; }
  [[ "$(yq -r 'tag' "$yml")" == "!!map" ]] || { _v_err "network.yml is not a map"; return; }
  net_name_ok "${id#*/}" || _v_err "the name '${id#*/}': lowercase letters, digits, . _ - and at most 11 characters"
  while IFS= read -r k; do
    [[ " $PMM_NET_KEYS " == *" $k "* ]] || _v_err "$k: is not a network setting ($PMM_NET_KEYS)"
  done < <(yq -r 'keys | .[]' "$yml")

  kind=$(net_get "$id" .kind) subnet=$(net_get "$id" .subnet)
  iface=$(net_get "$id" .interface) domain=$(net_get "$id" .domain)
  case "$kind" in
    nat|isolated)
      if [[ -z "$subnet" ]]; then _v_err "subnet: is required for a $kind network (10.20.0.0/24)"
      elif ! subnet_parse "$subnet"; then _v_err "subnet '$subnet' is not a network address with a prefix of 16 to 28 (10.20.0.0/24)"
      else
        while IFS= read -r other; do
          [[ "$other" != "$id" && "$(net_canon "${other#*/}")" == "$other" ]] || continue
          [[ "$(net_get "$other" .subnet)" != "$subnet" ]] || _v_err "subnet $subnet is also $other's"
        done < <(net_all_ids)
      fi
      [[ -z "$iface" ]] || _v_err "interface: is for a bridged network"
      ;;
    bridged)
      [[ -n "$iface" ]] || _v_err "interface: is required for a bridged network (a bridge the host has)"
      [[ -z "$subnet" ]] || _v_err "subnet: a bridged network's addresses are the LAN's"
      [[ -z "$domain" ]] || _v_err "domain: a bridged network's names are the LAN's"
      [[ -z "$iface" || "$iface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || _v_err "interface '$iface' is not an interface name"
      ;;
    "") _v_err "kind: is required (${PMM_NET_KINDS// /, })" ;;
    *) _v_err "kind '$kind' (${PMM_NET_KINDS// /, })" ;;
  esac
  [[ -z "$domain" || "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || _v_err "domain '$domain': lowercase letters, digits, . -"
  return 0
}

validate_network_quiet() {
  local out
  V_ERRORS=0 V_WARNINGS=0
  out=$(validate_network "$1"; echo "rc:$V_ERRORS")
  [[ "${out##*rc:}" == 0 ]] && return 0
  printf '%s\n' "${out%rc:*}" | grep '  error' >&2
  return 1
}

# --- commands -----------------------------------------------------------------------------------

# `pmm network list`: NAME SOURCE KIND SUBNET STATE MACHINES. STATE: active, inactive (installed,
# not started), missing (installed, and gone from the host), defined (not installed), shadowed.
cmd_network_list() {
  local id name d
  local -A seen=()
  {
    while IFS= read -r id; do
      name="${id#*/}"
      if [[ "$(net_canon "$name")" != "$id" ]]; then
        anfs_row "$name" "${id%%/*}" "$(net_get "$id" .kind)" "$(net_get "$id" .subnet "$(net_get "$id" .interface)")" shadowed ""
        continue
      fi
      seen[$name]=1
      anfs_row "$name" "${id%%/*}" "$(net_get "$id" .kind)" "$(net_get "$id" .subnet "$(net_get "$id" .interface)")" \
        "$(net_installed "$name" && net_status "$name" || echo defined)" "$(net_machines "$name" | paste -sd, -)"
    done < <(net_all_ids)
    for d in "$PMM_DATA_HOME"/networks/*/; do
      [[ -f "${d}state.yml" ]] || continue
      name=$(basename "$d")
      [[ -z "${seen[$name]:-}" ]] || continue
      anfs_row "$name" "" "$(net_state_get "$name" .kind)" "$(net_state_get "$name" .subnet)" "$(net_status "$name")" "$(net_machines "$name" | paste -sd, -)"
    done
  } | LC_ALL=C sort -s -t$'\t' -k1,1 | anfs_table "NAME SOURCE KIND SUBNET STATE MACHINES" "name source kind subnet state machines"
}

cmd_network_show() {
  local name id kind subnet m f
  net_find "$1"
  name="$N_NAME" id="$N_ID"
  echo "$name"
  if [[ -n "$id" ]]; then
    echo "  definition  $(tilde "$(net_def_dir "$id")") (${id%%/*})"
    kind=$(net_get "$id" .kind) subnet=$(net_get "$id" .subnet)
  else
    echo "  definition  gone"
    kind=$(net_state_get "$name" .kind) subnet=$(net_state_get "$name" .subnet)
  fi
  echo "  kind        $kind"
  if [[ "$kind" == bridged ]]; then
    echo "  bridge      $([[ -n "$id" ]] && net_get "$id" .interface || net_state_get "$name" .bridge) (the host's)"
  else
    echo "  bridge      pmm-$name"
    if subnet_parse "$subnet"; then
      echo "  subnet      $subnet (host $(int_ip $((SN_BASE + 1))))"
      echo "  dhcp        $(int_ip $((SN_BASE + SN_SIZE / 2))) to $(int_ip $((SN_BASE + SN_SIZE - 2))); machines from $(int_ip $((SN_BASE + 2)))"
    fi
    m=$([[ -n "$id" ]] && net_get "$id" .domain || net_state_get "$name" .domain)
    [[ -z "$m" ]] || echo "  domain      $m"
  fi
  echo "  state       $(net_installed "$name" && net_status "$name" || echo defined)"
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    f=$(state_file "$m")
    echo "  machine     $m $(N="$name" yq -r '.interfaces[] | select(.network == strenv(N)) | .mac + " " + (.address // "")' "$f" | paste -sd' ' -)"
  done < <(net_machines "$name")
}

cmd_network_path() {
  net_find "$1"
  [[ -n "$N_ID" ]] || die "$N_NAME has no definition any more"
  net_def_dir "$N_ID"
}

# `pmm network create <network> --kind K [--subnet CIDR] [--interface IF] [--domain D]`: write a
# local definition ($PMM_NETWORKS_HOME) and install it
cmd_network_create() {
  local name="$1" dir f
  net_name_ok "$name" || die "network names are lowercase letters, digits, . _ - and at most 11 characters"
  ! net_canon "$name" >/dev/null || anfs_fail 73 "$name is already defined ($(net_canon "$name")); pmm network install $name"
  ! net_installed "$name" || anfs_fail 73 "$name is already installed (pmm network show $name)"
  [[ -n "${CLI_OPT[kind]:-}" ]] || cli_usage_err "--kind is required (${PMM_NET_KINDS// /, })"
  dir="$PMM_NETWORKS_HOME/$name" f="$PMM_NETWORKS_HOME/$name/network.yml"
  mkdir -p "$dir"
  KIND="${CLI_OPT[kind]}" SUBNET="${CLI_OPT[subnet]:-}" IFACE="${CLI_OPT[interface]:-}" DOMAIN="${CLI_OPT[domain]:-}" \
    yq -n '.kind = strenv(KIND) | .subnet = (strenv(SUBNET) | select(. != ""))
           | .interface = (strenv(IFACE) | select(. != "")) | .domain = (strenv(DOMAIN) | select(. != ""))' > "$f"
  load_networks
  # a definition that does not install is not left behind
  ( net_install "local/$name" ) || { rm -rf "$dir"; return 1; }
  anfs_result name "$name" kind "${CLI_OPT[kind]}"
}

# `pmm network install <network|source/>...`: source/ is every network that source defines
cmd_network_install() {
  local arg id src
  local -a ids=()
  for arg in "$@"; do
    if [[ "$arg" == */ ]]; then
      src="${arg%/}"
      net_source_dir "$src" >/dev/null || die "'$src' is not a source with networks (see: anfs src list)"
      while IFS= read -r id; do
        [[ "${id%%/*}" != "$src" ]] || ids+=("$id")
      done < <(net_all_ids)
    else
      net_find "$arg"
      [[ -n "$N_ID" ]] || die "$N_NAME has no definition any more"
      ids+=("$N_ID")
    fi
  done
  [[ ${#ids[@]} -gt 0 ]] || { echo "No networks to install"; return 0; }
  for id in "${ids[@]}"; do
    if [[ "$(net_canon "${id#*/}")" != "$id" ]]; then
      echo "${id#*/}: $id is shadowed by $(net_canon "${id#*/}")"
      continue
    fi
    if [[ "$PMM_INSTALL" == validate ]]; then
      validate_network_quiet "$id" && echo "$id ok" || die "$id does not validate"
    else
      net_install "$id"
    fi
  done
}

# `pmm network rm [-y] <network>...`: refused while machines are on it. A local definition goes
# too; a source's is kept, and `pmm network install` makes the network again.
cmd_network_remove() {
  local spec on i
  local -a names=() ids=()
  for spec in "$@"; do
    net_find "$spec"
    on=$(net_machines "$N_NAME" | paste -sd' ' -)
    [[ -z "$on" ]] || die "$N_NAME has machines on it ($on); pmm rm them first"
    names+=("$N_NAME") ids+=("$N_ID")
  done
  confirm "rm takes networks away from this host" "Remove ${names[*]}?"
  for i in "${!names[@]}"; do
    net_installed "${names[$i]}" && net_delete "${names[$i]}"
    if [[ "${ids[$i]}" == "$PMM_LOCAL_SOURCE/"* ]]; then
      rm -rf "${PMM_NETWORKS_HOME:?}/${names[$i]}"
      echo "Removed network ${names[$i]}"
    elif [[ -n "${ids[$i]}" ]]; then
      echo "Removed network ${names[$i]} (still defined by ${ids[$i]%%/*})"
    else
      echo "Removed network ${names[$i]}"
    fi
  done
}
