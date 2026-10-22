#!/usr/bin/env bash
# pmm library: a machine's interfaces on pmm networks, and the ssh config fragment.
# Sourced by ~/.local/bin/pmm; functions only.
#
# machine.yml lists them: interfaces: [{network: lab, address: 10.20.0.11, mac: 52:54:...}].
# At create each gets a MAC, minted once and kept in the machine's record (state.yml), so a lease
# and a reservation survive down, up and reset. On a nat or isolated network each also gets an
# address to keep (its own, or the first one free), reserved in the network's DHCP under the
# machine's name; nothing is configured inside the guest. On a bridged network the address is
# whatever the LAN gives.
#
# ssh goes to the first interface with an address pmm knows, and such a machine has no user-mode
# nic. One whose interfaces are all bridged keeps it, and its forwarded port.

PMM_IFACE_KEYS="network address mac"

mac_ok()   { [[ "$1" =~ ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$ ]]; }
# qemu's own prefix, and three random bytes
mac_mint() { printf '52:54:00:%02x:%02x:%02x\n' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)); }

# How many interfaces a definition lists
iface_count() {
  local n
  n=$(mach_q "$1" '.interfaces | length' 2>/dev/null) || n=0
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# Usage: iface_def <id> <index> <network|address|mac>
iface_def() { mach_get "$1" ".interfaces[$2].$3"; }

# A machine's interfaces as made, one per line: network<TAB>bridge<TAB>mac<TAB>address (- for none)
mach_ifaces() {
  local f="${2:-$(state_file "$1")}"
  [[ -f "$f" ]] || return 0
  yq -r '.interfaces[]? | [.network, .bridge, .mac, .address // "-"] | @tsv' "$f" 2>/dev/null || true
}

# Check a definition's interfaces, printing its problems; adds to V_ERRORS / V_WARNINGS
validate_interfaces() {
  local id="$1" n i k net nid kind addr mac line
  local -A seen=()
  n=$(iface_count "$id")
  [[ "$(mach_q "$id" '.interfaces | tag' 2>/dev/null)" =~ ^(!!seq|!!null)$ ]] ||
    { _v_err "interfaces: is a list of {network, address, mac}"; return 0; }
  (( n > 0 )) || return 0
  for (( i = 0; i < n; i++ )); do
    while IFS= read -r k; do
      [[ " $PMM_IFACE_KEYS " == *" $k "* ]] || _v_err "interfaces[$i].$k: is not an interface setting ($PMM_IFACE_KEYS)"
    done < <(mach_q "$id" ".interfaces[$i] | keys | .[]" 2>/dev/null)
    net=$(iface_def "$id" "$i" network) addr=$(iface_def "$id" "$i" address) mac=$(iface_def "$id" "$i" mac)
    if [[ -z "$net" ]]; then _v_err "interfaces[$i]: network: is required"; continue; fi
    [[ -z "${seen[$net]:-}" ]] || _v_err "interfaces[$i]: $net is listed twice"
    seen[$net]=1
    [[ -z "$mac" ]] || mac_ok "$mac" || _v_err "interfaces[$i]: mac '$mac' (52:54:00:12:34:56, lowercase)"
    if ! net_known "$net"; then
      _v_err "interfaces[$i]: network '$net' not found (pmm network list)"
      continue
    fi
    kind=$(net_setting "$net" kind)
    [[ -z "$addr" ]] && continue
    if [[ "$kind" == bridged ]]; then _v_err "interfaces[$i]: address: $net is bridged, and its addresses are the LAN's"
    elif ! subnet_has "$(net_setting "$net" subnet)" "$addr"; then _v_err "interfaces[$i]: $addr is not an address in $net ($(net_setting "$net" subnet))"
    fi
  done
  [[ -z "$(mach_list "$id" .ports)" ]] || ! iface_known_address "$id" ||
    _v_warn "ports: are forwards on 127.0.0.1 for a machine with no network; this one is reached at its address"
  while IFS= read -r line; do [[ -z "$line" ]] || _v_err "$line"; done < <(net_host_problems)
  return 0
}

# True when a definition has an interface on a nat or isolated network: pmm will know its address
iface_known_address() {
  local id="$1" n i net
  n=$(iface_count "$id")
  for (( i = 0; i < n; i++ )); do
    net=$(iface_def "$id" "$i" network)
    net_known "$net" || continue
    [[ "$(net_setting "$net" kind)" == bridged ]] || return 0
  done
  return 1
}

# Give back what a machine holds on its networks: its reservations
# Usage: ifaces_release <name> [state file]
ifaces_release() {
  local name="$1" net bridge mac addr
  while IFS=$'\t' read -r net bridge mac addr; do
    [[ -n "$net" && "$addr" != - ]] || continue
    net_installed "$net" || continue
    net_reserve delete "$net" "$mac" "$name" "$addr"
  done < <(mach_ifaces "$name" "${2:-}")
}

# Record a machine's interfaces from its definition, and reserve their addresses. Its networks
# are installed first, as its image is built first. <old> is what mach_ifaces said before the
# record was rewritten (a reset): a network it was already on keeps its MAC, and its address
# unless the definition now names one.
# <old mac> is the user-mode nic's.
# Usage: ifaces_record <name> <id> <old> <old mac>
ifaces_record() {
  local name="$1" id="$2" old="$3" f n i net nid kind bridge mac addr was
  f=$(state_file "$name")
  # the user-mode nic's own MAC: qemu's default is the same on every machine
  mac="${4:-}"; [[ -n "$mac" ]] || mac=$(mac_mint)
  MAC="$mac" yq -i '.mac = strenv(MAC)' "$f"
  n=$(iface_count "$id")
  (( n > 0 )) || return 0
  for (( i = 0; i < n; i++ )); do
    net=$(iface_def "$id" "$i" network)
    # one `pmm network create` made is there already, and has no definition to install it from
    if ! net_installed "$net"; then
      nid=$(net_canon "$net") || die "$name: network '$net' not found (pmm network list)"
      net_install "$nid" >&2
    fi
    net_up "$net"
    kind=$(net_state_get "$net" .kind) bridge=$(net_state_get "$net" .bridge)
    was=$(awk -F'\t' -v n="$net" '$1 == n { print $3 "\t" $4; exit }' <<< "$old")
    mac=$(iface_def "$id" "$i" mac); [[ -n "$mac" ]] || mac="${was%%$'\t'*}"; [[ -n "$mac" ]] || mac=$(mac_mint)
    addr=""
    if [[ "$kind" != bridged ]]; then
      addr=$(iface_def "$id" "$i" address)
      [[ -n "$addr" || -z "$was" || "${was#*$'\t'}" == - ]] || addr="${was#*$'\t'}"
      if [[ -z "$addr" ]]; then
        addr=$(net_free_address "$net") || die "$net has no address left for $name"
      elif grep -qx "$addr" <<< "$(net_addresses "$net")"; then
        die "$addr on $net is another machine's (pmm network show $net)"
      fi
      net_reserve add "$net" "$mac" "$name" "$addr"
    fi
    NET="$net" BRIDGE="$bridge" MAC="$mac" \
      yq -i '.interfaces += [{"network": strenv(NET), "bridge": strenv(BRIDGE), "mac": strenv(MAC)}]' "$f"
    [[ -z "$addr" ]] || ADDR="$addr" yq -i '.interfaces[-1].address = strenv(ADDR)' "$f"
  done
}

# Fill QEMU_NICS with a machine's interfaces, in order, and set IFACE_SSH to the address ssh
# goes to (nothing when no interface has one pmm knows). Each network is started if it is not.
ifaces_argv() {
  local name="$1" net bridge mac addr
  QEMU_NICS=() IFACE_SSH=""
  while IFS=$'\t' read -r net bridge mac addr; do
    [[ -n "$net" ]] || continue
    net_require
    net_up "$net"
    qemu_nic_bridge "$bridge" "$mac"
    [[ -n "$IFACE_SSH" || "$addr" == - ]] || IFACE_SSH="$addr"
  done < <(mach_ifaces "$name")
}

# The address the guest has on the interface with <mac>, asked of its agent; nothing when the
# agent does not answer (a bridged interface, whose address is the LAN's to give)
ga_address() {
  local sock="$(sock_dir pmm)/$1.ga"
  [[ -S "$sock" ]] && command -v socat >/dev/null 2>&1 || return 0
  # the agent answers a moment after it is asked, and only while the channel is held open; a
  # reply nobody waited for is still queued, so the last line is this one's
  { printf '{"execute":"guest-network-get-interfaces"}\n'; sleep 1; } | socat - "UNIX-CONNECT:$sock" 2>/dev/null | tail -n1 |
    MAC="$2" yq -p json -r '.return[]? | select(."hardware-address" == strenv(MAC)) | ."ip-addresses"[]?
                            | select(."ip-address-type" == "ipv4") | ."ip-address"' 2>/dev/null | head -n1 || true
}

# A machine's interfaces for a person: network, mac, and the address it has or will have
# Usage: ifaces_show <name>   (one line per interface)
ifaces_show() {
  local name="$1" net bridge mac addr
  while IFS=$'\t' read -r net bridge mac addr; do
    [[ -n "$net" ]] || continue
    if [[ "$addr" == - ]]; then
      addr=""
      ! mach_running "$name" || addr=$(ga_address "$name" "$mac")
      [[ -n "$addr" ]] || addr="(from the LAN)"
    fi
    echo "$net $addr $mac"
  done < <(mach_ifaces "$name")
}

# --- ssh by name --------------------------------------------------------------------------------

# Where a running machine's ssh is: the address and the port
mach_ssh_host() { cat "$(run_dir "$1")/host" 2>/dev/null || echo 127.0.0.1; }

# Rewrite $PMM_SSH_CONFIG ($PMM_STATE_HOME/ssh_config: STATE, never ~/.ssh): a Host entry per
# running machine, so `ssh <machine>` works wherever ~/.ssh/config includes config.d/*.conf
# (stack/ssh), where core/pmm's 05-pmm.conf includes this file. ssh takes the first value it reads
# for a setting, so that fragment sorts ahead of a person's own (05-). Host keys are not
# recorded, as with pmm shell: a machine's key changes whenever it is recreated.
ssh_config_write() {
  local d name r
  [[ -n "$PMM_SSH_CONFIG" ]] || return 0
  mkdir -p "$(dirname "$PMM_SSH_CONFIG")" 2>/dev/null || return 0
  {
    echo "# pmm's running machines: rewritten by pmm up and down, not to be edited"
    for d in "$PMM_STATE_HOME"/run/*/; do
      [[ -d "$d" ]] || continue
      name=$(basename "$d") r="${d%/}"
      mach_running "$name" || continue
      [[ -f "$r/port" && -f "$r/user" && -f "$r/key" ]] || continue
      echo
      echo "Host $name"
      if [[ "$(cat "$r/backend" 2>/dev/null)" == tart ]]; then echo "  HostName $(cat "$r/ip" 2>/dev/null)"
      else echo "  HostName $(mach_ssh_host "$name")"
      fi
      echo "  Port $(cat "$r/port")"
      # a blank machine has no login of pmm's: the entry still says where its ssh is forwarded
      if [[ -n "$(cat "$r/user")" ]]; then echo "  User $(cat "$r/user")"; fi
      if [[ -n "$(cat "$r/key")" ]]; then
        echo "  IdentityFile $(cat "$r/key")"
        echo "  IdentitiesOnly yes"
      fi
      echo "  StrictHostKeyChecking no"
      echo "  UserKnownHostsFile /dev/null"
      echo "  LogLevel ERROR"
    done
  } > "$PMM_SSH_CONFIG.tmp" 2>/dev/null && mv "$PMM_SSH_CONFIG.tmp" "$PMM_SSH_CONFIG" || true
}
