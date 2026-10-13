#!/usr/bin/env bats
# machine.sh / snapshot.sh: create, up, down, remove, snapshot and reset, with qemu and ssh stubbed
load helper

setup() {
  setup_pmm
  fake_build deb
  KEY=aaaaaaaaaaaaaaaa
  BASE="$PIM_DATA_HOME/images/deb/arm64/$KEY.qcow2"
}

teardown() {
  local f
  for f in "$PMM_STATE_HOME"/run/*/pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null; done
  return 0
}

@test "create --image: a local definition, an overlay on the build, the record, and pim's hold" {
  run cli_call create web1 --image deb --cpus 4 --memory 8G -p 8080:80 --share "$T:src:ro"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created web1 from local/deb ($KEY)"* ]]
  [ "$(yq -r '.image' "$PMM_MACHINES_HOME/web1/machine.yml")" = deb ]
  [ "$(yq -r '.cpus | tag' "$PMM_MACHINES_HOME/web1/machine.yml")" = '!!int' ]
  [ "$(yq -r '.memory' "$PMM_MACHINES_HOME/web1/machine.yml")" = 8G ]
  [ "$(yq -r '.ports[0]' "$PMM_MACHINES_HOME/web1/machine.yml")" = 8080:80 ]
  grep -q "pim build --arch arm64 deb" "$PIM_CALLS"
  grep -q "qemu-img create -q -f qcow2 -b $BASE -F qcow2 $PMM_DATA_HOME/machines/web1/disk.qcow2" "$PIM_CALLS"
  [ -f "$PMM_DATA_HOME/machines/web1/efivars.fd" ]
  [ "$(state_get web1 .image)" = local/deb ]
  [ "$(state_get web1 .key)" = "$KEY" ]
  [ "$(state_get web1 .user)" = pim ]
  [ "$(held deb)" = pmm:web1 ]
  ! grep -q qemu-system "$PIM_CALLS"
  load_machines
  [ "$(mach_state web1)" = stopped ]
}

@test "create: twice is 73; a defined name takes no settings; no --image for an unknown name is 64" {
  cli_call create web1 --image deb >/dev/null
  load_machines
  run cli_call create web1
  [ "$status" -eq 73 ]
  [[ "$output" == *"web1 already exists"* ]]
  run cli_call create web1 --cpus 8
  [ "$status" -eq 73 ]
  [[ "$output" == *"already defined (local/web1)"* ]]
  run cli_call create web2
  [ "$status" -eq 64 ]
  run cli_call create Web2 --image deb
  [ "$status" -ne 0 ]
  run cli_call create web3 --image nope
  [ "$status" -ne 0 ]
  [ ! -d "$PMM_MACHINES_HOME/web3" ]     # a definition that does not validate is not left behind
}

@test "create --disk grows the overlay" {
  cli_call create big --image deb --disk 40G >/dev/null
  grep -q "qemu-img resize -q $PMM_DATA_HOME/machines/big/disk.qcow2 40G" "$PIM_CALLS"
}

@test "up: several machines of one image, each with its own disk, port and settings" {
  printf 'small: {cpus: 1, memory: 1G}\n' > "$PMM_MACHINES_HOME/profiles.yml"
  machine "$PMM_MACHINES_HOME/a" "$(printf 'image: deb\nprofile: small\nports: ["8080:80"]')"
  machine "$PMM_MACHINES_HOME/b" "$(printf 'image: deb\ncpus: 4\nmemory: 4G\nuser: admin')"
  load_machines
  run cli_call up a b
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"a is up: pmm shell a"* ]]
  [[ "$output" == *"b is up: pmm shell b"*"admin@127.0.0.1"* ]]
  grep -q -- "-smp 1 -m 1024 .*file=$PMM_DATA_HOME/machines/a/disk.qcow2.*hostfwd=tcp:127.0.0.1:42300-:22,hostfwd=tcp:127.0.0.1:8080-:80" "$PIM_CALLS"
  grep -q -- "-smp 4 -m 4096 .*file=$PMM_DATA_HOME/machines/b/disk.qcow2.*hostfwd=tcp:127.0.0.1:42301-:22" "$PIM_CALLS"
  [ "$(held deb)" = "pmm:a pmm:b" ]
  ANFS_JSON=true run cmd_ps
  [ "$(yq -p json -r '.[] | .name + " " + .ssh' <<< "$output" | paste -sd, -)" = "a 127.0.0.1:42300,b 127.0.0.1:42301" ]
  ANFS_JSON=true run cmd_list
  [ "$(yq -p json -r '.[] | select(.name == "a") | .state + " " + .address' <<< "$output")" = "running 127.0.0.1:42300" ]
  run cli_call up a
  [[ "$output" == *"a is running (127.0.0.1:42300"* ]]
  run cli_call down a b
  [[ "$output" == *"Stopping a"*"Stopping b"* ]]
  [ "$(mach_state a)" = stopped ]
  [ ! -d "$PMM_STATE_HOME/run/a" ]
}

@test "up --image with no name: a machine named after the image, defined on the spot" {
  run cli_call up --image deb
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.image' "$PMM_MACHINES_HOME/deb/machine.yml")" = deb ]
  [ "$(mach_state deb)" = running ]
  run cli_call up
  [ "$status" -eq 64 ]
}

@test "shell: the command goes to the machine's port as its user, or as -u" {
  cli_call up --image deb >/dev/null
  : > "$PIM_CALLS"
  cli_call shell deb -- uname -a
  grep -qx "ssh uname -a" "$PIM_CALLS"
  cli_call down deb >/dev/null
  run cli_call shell deb -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"deb is not running (pmm up deb)"* ]]
}

@test "a machine stays on the build it was created from; show says there is a newer one; reset moves it" {
  cli_call create web1 --image deb >/dev/null
  load_machines
  fake_build deb dddddddddddddddd
  : > "$BASE"     # the superseded disk is still there (pim clean keeps what is held)
  run cli_call show web1
  echo "$output"
  [[ "$output" == *"build       $KEY (arm64, qemu); local/deb has a newer build (pmm reset web1)"* ]]
  [ "$(state_get web1 .key)" = "$KEY" ]
  run cli_call reset -y web1
  [ "$status" -eq 0 ]
  [ "$(state_get web1 .key)" = dddddddddddddddd ]
  [ "$(held deb)" = pmm:web1 ]
  [ ! -e "$PIM_DATA_HOME/images/deb/arm64/holds/$KEY" ]
}

@test "snapshot and reset: a copy with its own hold; reset to it puts the disk and the record back" {
  cli_call create web1 --image deb >/dev/null
  load_machines
  echo one > "$PMM_DATA_HOME/machines/web1/disk.qcow2"
  run cli_call snapshot web1 s1
  [ "$status" -eq 0 ]
  [ "$(cat "$PMM_DATA_HOME/snapshots/web1/s1/disk.qcow2")" = one ]
  [ "$(held deb)" = "pmm:web1 pmm:web1@s1" ]
  run cli_call snapshot web1
  [ "$output" = s1 ]
  echo two > "$PMM_DATA_HOME/machines/web1/disk.qcow2"
  run cli_call reset -y web1 nope
  [ "$status" -ne 0 ]
  run cli_call reset -y web1 s1
  [ "$status" -eq 0 ]
  [ "$(cat "$PMM_DATA_HOME/machines/web1/disk.qcow2")" = one ]
  [ "$(state_get web1 .key)" = "$KEY" ]
  run cli_call reset web1 s1 </dev/null
  [ "$status" -ne 0 ]     # asks, and there is no terminal
}

@test "remove: the disk, the snapshots and the holds go; a local definition too, a source's stays" {
  add_source acme
  machine "$T/srcs/acme/machines/db" "image: deb"
  cli_call create web1 --image deb >/dev/null
  load_machines
  cli_call create db >/dev/null
  cli_call snapshot web1 s1 >/dev/null
  [ "$(held deb)" = "pmm:db pmm:web1 pmm:web1@s1" ]
  run cli_call remove -y web1 db
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed web1"* ]]
  [[ "$output" == *"Removed db (still defined by acme)"* ]]
  [ -z "$(held deb)" ]
  [ ! -d "$PMM_DATA_HOME/machines/web1" ] && [ ! -d "$PMM_DATA_HOME/snapshots/web1" ]
  [ ! -d "$PMM_MACHINES_HOME/web1" ]
  [ -f "$T/srcs/acme/machines/db/machine.yml" ]
  run cli_call remove -y web1
  [ "$status" -ne 0 ]
}

@test "implode: every machine stopped and removed, pim's holds released, nothing of pmm's left" {
  cli_call up --image deb >/dev/null
  cli_call implode -y >/dev/null
  [ -z "$(held deb)" ]
  [ ! -e "$PMM_DATA_HOME" ] && [ ! -e "$PMM_STATE_HOME" ] && [ ! -e "$PMM_CONFIG_HOME" ]
}

@test "migrate: pim's old VM and its snapshots become a machine, on the build they were made from" {
  old="$PIM_DATA_HOME/vms/deb"
  mkdir -p "$old" "$PIM_DATA_HOME/snapshots/deb"
  echo disk > "$old/disk.qcow2"; echo vars > "$old/efivars.fd"; echo "$KEY" > "$old/base"; echo arm64 > "$old/arch"
  echo snap > "$PIM_DATA_HOME/snapshots/deb/s1.qcow2"; echo "$KEY" > "$PIM_DATA_HOME/snapshots/deb/base"
  printf 'cpus: 4\nmemory: 4096\nshares: ["/tmp:t"]\n' >> "$PIM_IMAGES_HOME/deb/image.yml"
  run cmd_migrate
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Migrated deb from pim (1 snapshots)"* ]]
  [ "$(cat "$PMM_DATA_HOME/machines/deb/disk.qcow2")" = disk ]
  [ "$(cat "$PMM_DATA_HOME/snapshots/deb/s1/disk.qcow2")" = snap ]
  [ "$(state_get deb .key)" = "$KEY" ]
  [ "$(state_get deb .base)" = "$BASE" ]
  [ "$(yq -r '.image + " " + (.cpus | tostring) + " " + .shares[0]' "$PMM_MACHINES_HOME/deb/machine.yml")" = "deb 4 /tmp:t" ]
  [ "$(held deb)" = "pmm:deb pmm:deb@s1" ]
  [ ! -d "$PIM_DATA_HOME/vms" ] && [ ! -d "$PIM_DATA_HOME/snapshots" ]
  run cmd_migrate     # again: nothing to do
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
