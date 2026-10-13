#!/usr/bin/env bats
# network.sh / interfaces.sh: networks across sources, installing them into libvirt (stubbed),
# a machine's interfaces, reservations, and the ssh config fragment
load helper

setup() {
  setup_pmm
  setup_net
  fake_build deb
}

teardown() {
  local f
  for f in "$PMM_STATE_HOME"/run/*/pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null; done
  return 0
}

lab() { network "$PMM_NETWORKS_HOME/lab" "$(printf 'kind: nat\nsubnet: 10.20.0.0/24\ndomain: lab')"; }

@test "subnet_parse: the host, the mask, and what is not a subnet" {
  subnet_parse 10.20.0.0/24
  [ "$(int_ip "$SN_BASE")" = 10.20.0.0 ]
  [ "$SN_SIZE" -eq 256 ]
  [ "$SN_MASK" = 255.255.255.0 ]
  subnet_parse 172.16.8.0/22
  [ "$SN_MASK" = 255.255.252.0 ]
  ! subnet_parse 10.20.0.1/24        # not the network's address
  ! subnet_parse 10.20.0.0/30
  ! subnet_parse 10.20.0.0
  ! subnet_parse 10.20.300.0/24
  subnet_has 10.20.0.0/24 10.20.0.11
  ! subnet_has 10.20.0.0/24 10.20.0.1     # the host's
  ! subnet_has 10.20.0.0/24 10.20.0.255
  ! subnet_has 10.20.0.0/24 10.21.0.11
}

@test "validate: kinds, what each needs, a subnet two networks share, a name too long for a bridge" {
  lab
  network "$PMM_NETWORKS_HOME/lan" "$(printf 'kind: bridged\ninterface: br0')"
  network "$PMM_NETWORKS_HOME/bad" "$(printf 'kind: routed\nvlan: 3')"
  network "$PMM_NETWORKS_HOME/dup" "$(printf 'kind: isolated\nsubnet: 10.20.0.0/24')"
  network "$PMM_NETWORKS_HOME/nosub" "kind: nat"
  network "$PMM_NETWORKS_HOME/brsub" "$(printf 'kind: bridged\nsubnet: 10.9.0.0/24')"
  network "$PMM_NETWORKS_HOME/averylongname" "$(printf 'kind: isolated\nsubnet: 10.99.0.0/24')"
  load_machines
  run cmd_validate
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"network local/lan ok"* ]]
  [[ "$output" == *"kind 'routed'"* ]]
  [[ "$output" == *"vlan: is not a network setting"* ]]
  [[ "$output" == *"subnet 10.20.0.0/24 is also local/lab's"* ]]
  [[ "$output" == *"subnet: is required for a nat network"* ]]
  [[ "$output" == *"interface: is required for a bridged network"* ]]
  [[ "$output" == *"subnet: a bridged network's addresses are the LAN's"* ]]
  [[ "$output" == *"at most 11 characters"* ]]
  [[ "$output" == *"0 machine(s), 7 network(s)"* ]]
}

@test "install: a nat network is defined in libvirt, started, set to autostart, and its bridge allowed" {
  lab
  load_machines
  run cli_call "network install" lab
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed network lab (nat, 10.20.0.0/24)"* ]]
  grep -q "<forward mode='nat'/>" "$VIRSH_STUB/pmm-lab.xml"
  grep -q "<bridge name='pmm-lab'" "$VIRSH_STUB/pmm-lab.xml"
  grep -q "<domain name='lab' localOnly='yes'/>" "$VIRSH_STUB/pmm-lab.xml"
  grep -q "<ip address='10.20.0.1' netmask='255.255.255.0'>" "$VIRSH_STUB/pmm-lab.xml"
  grep -q "<range start='10.20.0.128' end='10.20.0.254'/>" "$VIRSH_STUB/pmm-lab.xml"
  grep -q "virsh -c qemu:///system net-autostart pmm-lab" "$PMM_CALLS"
  [ "$(cat "$VIRSH_STUB/pmm-lab.state")" = active ]
  grep -qx "allow pmm-lab" "$PMM_BRIDGE_CONF"
  [ "$(net_state_get lab .kind)" = nat ]
  ANFS_JSON=true run cmd_network_list
  [ "$(yq -p json -r '.[] | .name + " " + .kind + " " + .subnet + " " + .state' <<< "$output")" = "lab nat 10.20.0.0/24 active" ]
  # again: nothing new, and a stopped one is started
  echo inactive > "$VIRSH_STUB/pmm-lab.state"
  run cli_call "network install" lab
  [[ "$output" == *"lab is installed (nat, active)"* ]]
  [ "$(grep -c net-define "$PMM_CALLS")" -eq 1 ]
  # changed underneath an installed one
  network "$PMM_NETWORKS_HOME/lab" "$(printf 'kind: nat\nsubnet: 10.21.0.0/24')"
  run cli_call "network install" lab
  [ "$status" -ne 0 ]
  [[ "$output" == *"installed with other settings"* ]]
}

@test "install: isolated has no forward; bridged defines nothing and needs the host's bridge" {
  network "$PMM_NETWORKS_HOME/iso" "$(printf 'kind: isolated\nsubnet: 10.30.0.0/24')"
  network "$PMM_NETWORKS_HOME/lan" "$(printf 'kind: bridged\ninterface: br0')"
  load_machines
  cli_call "network install" iso >/dev/null
  ! grep -q "<forward" "$VIRSH_STUB/pmm-iso.xml"
  ! grep -q "<domain" "$VIRSH_STUB/pmm-iso.xml"
  run cli_call "network install" lan
  [ "$status" -ne 0 ]
  [[ "$output" == *"the host has no bridge 'br0'"* ]]
  host_bridge br0
  run cli_call "network install" lan
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -f "$VIRSH_STUB/pmm-lan.xml" ]
  grep -qx "allow br0" "$PMM_BRIDGE_CONF"
  [ "$(net_status lan)" = active ]
}

@test "a host that is not set up: install says what is missing; with no backend, that" {
  lab
  load_machines
  chmod u-s "$PMM_BRIDGE_HELPER"
  rm -f "$PMM_BRIDGE_CONF"
  run cli_call "network install" lab
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bridge helper is not setuid"* ]]
  [[ "$output" == *"pmm-bridge.conf is missing or not writable"* ]]
  [[ "$output" == *"ppm install core/pmm-network"* ]]
  PMM_NET_BACKEND=none
  run cli_call "network install" lab
  [[ "$output" == *"Linux only so far"* ]]
}

@test "create: a local definition, installed; one that does not install is not left behind" {
  run cli_call "network create" lab --kind nat --subnet 10.20.0.0/24 --domain lab
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.kind + " " + .subnet + " " + .domain' "$PMM_NETWORKS_HOME/lab/network.yml")" = "nat 10.20.0.0/24 lab" ]
  [ "$(net_status lab)" = active ]
  run cli_call "network create" lab --kind nat --subnet 10.40.0.0/24
  [ "$status" -eq 73 ]
  run cli_call "network create" bad --kind nat
  [ "$status" -ne 0 ]
  [ ! -d "$PMM_NETWORKS_HOME/bad" ]
  run cli_call "network create" x
  [ "$status" -eq 64 ]
}

@test "a machine's interfaces: a MAC each, an address kept, reserved under its name, its networks installed" {
  lab
  network "$PMM_NETWORKS_HOME/lan" "$(printf 'kind: bridged\ninterface: br0')"
  host_bridge br0
  machine "$PMM_MACHINES_HOME/web1" "$(printf 'image: deb\ninterfaces:\n  - network: lab\n    address: 10.20.0.11\n  - network: lan\n    mac: 52:54:00:aa:bb:cc')"
  machine "$PMM_MACHINES_HOME/web2" "$(printf 'image: deb\ninterfaces: [{network: lab}]')"
  load_machines
  run cli_call create web1
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(net_status lab)" = active ]                     # installed on the way
  [ "$(state_get web1 '.interfaces | length')" -eq 2 ]
  [ "$(state_get web1 '.interfaces[0].address')" = 10.20.0.11 ]
  [ "$(state_get web1 '.interfaces[0].bridge')" = pmm-lab ]
  mac1=$(state_get web1 '.interfaces[0].mac')
  mac_ok "$mac1"
  [ "$(state_get web1 '.interfaces[1].mac')" = 52:54:00:aa:bb:cc ]
  [ "$(state_get web1 '.interfaces[1].bridge')" = br0 ]
  [ -z "$(state_get web1 '.interfaces[1].address')" ]
  grep -q "net-update pmm-lab add ip-dhcp-host <host mac='$mac1' name='web1' ip='10.20.0.11'/> --config --live" "$PMM_CALLS"
  # no address of its own: the first one free
  cli_call create web2 >/dev/null
  [ "$(state_get web2 '.interfaces[0].address')" = 10.20.0.2 ]
  [ "$(net_machines lab | paste -sd' ' -)" = "web1 web2" ]
  run cli_call "network remove" -y lab
  [ "$status" -ne 0 ]
  [[ "$output" == *"lab has machines on it (web1 web2)"* ]]
  # reset keeps the MAC and the address; remove gives the reservation back
  cli_call reset -y web2 >/dev/null
  [ "$(state_get web2 '.interfaces[0].address')" = 10.20.0.2 ]
  mac2=$(state_get web2 '.interfaces[0].mac')
  cli_call reset -y web1 >/dev/null
  [ "$(state_get web1 '.interfaces[0].mac')" = "$mac1" ]
  : > "$PMM_CALLS"
  cli_call remove -y web1 web2 >/dev/null
  grep -q "net-update pmm-lab delete ip-dhcp-host <host mac='$mac2' name='web2' ip='10.20.0.2'/>" "$PMM_CALLS"
  run cli_call "network remove" -y lab lan
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -f "$VIRSH_STUB/pmm-lab.state" ]
  ! grep -qx "allow pmm-lab" "$PMM_BRIDGE_CONF"
  grep -qx "allow br0" "$PMM_BRIDGE_CONF"            # the host's bridge is not pmm's to forget
  [ ! -d "$PMM_NETWORKS_HOME/lab" ]
}

@test "validate: an interface's network, address and mac; an address another machine holds" {
  lab
  network "$PMM_NETWORKS_HOME/lan" "$(printf 'kind: bridged\ninterface: br0')"
  machine "$PMM_MACHINES_HOME/bad" "$(printf 'image: deb\ninterfaces:\n  - network: nope\n  - network: lab\n    address: 10.21.0.5\n    mac: XX\n    vlan: 3\n  - network: lan\n    address: 10.0.0.9\n  - {}\n  - network: lab')"
  machine "$PMM_MACHINES_HOME/a" "$(printf 'image: deb\ninterfaces: [{network: lab, address: 10.20.0.11}]')"
  machine "$PMM_MACHINES_HOME/b" "$(printf 'image: deb\ninterfaces: [{network: lab, address: 10.20.0.11}]')"
  load_machines
  run cmd_validate bad
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"network 'nope' not found"* ]]
  [[ "$output" == *"10.21.0.5 is not an address in lab"* ]]
  [[ "$output" == *"mac 'XX'"* ]]
  [[ "$output" == *"interfaces[1].vlan: is not an interface setting"* ]]
  [[ "$output" == *"lan is bridged"* ]]
  [[ "$output" == *"interfaces[3]: network: is required"* ]]
  [[ "$output" == *"lab is listed twice"* ]]
  cli_call create a >/dev/null
  run cli_call create b
  [ "$status" -ne 0 ]
  [[ "$output" == *"10.20.0.11 on lab is another machine's"* ]]
  # with no backend, a machine on a network does not validate
  PMM_NET_BACKEND=none
  run cmd_validate a
  [ "$status" -ne 0 ]
  [[ "$output" == *"Linux only so far"* ]]
}

@test "up: on a network there is no user-mode nic, ssh goes to the address, and ssh <machine> works" {
  lab
  network "$PMM_NETWORKS_HOME/lan" "$(printf 'kind: bridged\ninterface: br0')"
  host_bridge br0
  machine "$PMM_MACHINES_HOME/web1" "$(printf 'image: deb\ninterfaces: [{network: lab, address: 10.20.0.11}, {network: lan}]')"
  machine "$PMM_MACHINES_HOME/edge" "$(printf 'image: deb\ninterfaces: [{network: lan}]')"
  machine "$PMM_MACHINES_HOME/plain" "image: deb"
  load_machines
  run cli_call up web1 edge plain
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"web1 is up: pmm shell web1  (ssh pmm@10.20.0.11 "* ]]
  m0=$(state_get web1 '.interfaces[0].mac') m1=$(state_get web1 '.interfaces[1].mac')
  line=$(grep "machines/web1/disk.qcow2" "$PMM_CALLS" | grep qemu-system)
  [[ "$line" != *"-netdev user"* ]]
  [[ "$line" == *"-netdev bridge,id=net1,br=pmm-lab -device virtio-net-pci,netdev=net1,mac=$m0 -netdev bridge,id=net2,br=br0 -device virtio-net-pci,netdev=net2,mac=$m1"* ]]
  # all bridged: the address is the LAN's, so the forwarded port stays, with a MAC of its own
  line=$(grep "machines/edge/disk.qcow2" "$PMM_CALLS" | grep qemu-system)
  [[ "$line" == *"hostfwd=tcp:127.0.0.1:42300-:22 -device virtio-net-pci,netdev=net0,mac=$(state_get edge .mac) -netdev bridge,id=net1,br=br0"* ]]
  line=$(grep "machines/plain/disk.qcow2" "$PMM_CALLS" | grep qemu-system)
  [[ "$line" == *"netdev=net0,mac=$(state_get plain .mac) -display none"* ]]
  [ "$(state_get plain .mac)" != "$(state_get edge .mac)" ]
  ANFS_JSON=true run cmd_list
  [ "$(yq -p json -r '.[] | select(.name == "web1") | .address' <<< "$output")" = 10.20.0.11 ]
  [ "$(yq -p json -r '.[] | select(.name == "edge") | .address' <<< "$output")" = 127.0.0.1:42300 ]
  run cmd_show web1
  [[ "$output" == *"interface   lab 10.20.0.11 $m0"* ]]
  [[ "$output" == *"interface   lan (from the LAN) $m1"* ]]
  grep -A2 -x "Host web1" "$PMM_SSH_CONFIG" | grep -qx "  HostName 10.20.0.11"
  grep -A2 -x "Host web1" "$PMM_SSH_CONFIG" | grep -qx "  Port 22"
  grep -A2 -x "Host edge" "$PMM_SSH_CONFIG" | grep -qx "  Port 42300"
  cli_call down web1 >/dev/null
  ! grep -qx "Host web1" "$PMM_SSH_CONFIG"
  grep -qx "Host plain" "$PMM_SSH_CONFIG"
}

@test "install source/: its networks, then its machines; a source with only networks" {
  add_source acme
  network "$T/srcs/acme/machines/networks/lab" "$(printf 'kind: nat\nsubnet: 10.20.0.0/24')"
  machine "$T/srcs/acme/machines/web" "$(printf 'image: deb\ninterfaces: [{network: lab}]')"
  mkdir -p "$T/srcs/nets/machines/networks"
  ln -sfn "$T/srcs/nets" "$HOME/.local/share/anfs/sources/nets"
  printf '%s  %s\n' "$T/srcs/nets" nets >> "$HOME/.config/anfs/user.list"
  network "$T/srcs/nets/machines/networks/iso" "$(printf 'kind: isolated\nsubnet: 10.30.0.0/24')"
  load_machines
  PMM_INSTALL=validate run cli_call install acme/ nets/
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme/lab ok"*"nets/iso ok"* ]]
  [ ! -f "$VIRSH_STUB/pmm-lab.state" ]
  PMM_INSTALL=create run cli_call install acme/ nets/
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(net_status lab)" = active ]
  [ "$(net_status iso)" = active ]
  [ "$(state_get web '.interfaces[0].address')" = 10.20.0.2 ]
  ANFS_JSON=true run cmd_network_list
  [ "$(yq -p json -r '.[] | select(.name == "lab") | .source + " " + .machines' <<< "$output")" = "acme web" ]
}

@test "implode takes the networks with it" {
  cli_call "network create" lab --kind nat --subnet 10.20.0.0/24 >/dev/null
  cli_call up w --image deb >/dev/null
  run cli_call implode -y
  [ "$status" -eq 0 ]
  [ ! -f "$VIRSH_STUB/pmm-lab.state" ]
  [ ! -f "$PMM_SSH_CONFIG" ]
  ! grep -qx "allow pmm-lab" "$PMM_BRIDGE_CONF"
}
