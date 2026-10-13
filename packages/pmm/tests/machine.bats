#!/usr/bin/env bats
# machine.sh / snapshot.sh: run, up, down, exec, remove, snapshots and reset, with qemu and ssh stubbed
load helper

setup() {
  setup_pmm
  fake_build deb
  KEY=aaaaaaaaaaaaaaaa
  BASE="$PMM_DATA_HOME/images/deb/arm64/$KEY.qcow2"
}

teardown() {
  local f
  for f in "$PMM_STATE_HOME"/run/*/pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null; done
  return 0
}

@test "run --no-start: an overlay on the build and the record; no definition is written" {
  before=$(find "$PMM_CONFIG_HOME" | sort)
  run cli_call run deb --name web1 --no-start --cpus 4 --memory 8G -p 8080:80 --share "$T:src:ro"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created web1 from local/deb ($KEY)"* ]]
  [ "$(find "$PMM_CONFIG_HOME" | sort)" = "$before" ]
  [ "$(state_get web1 .settings.image)" = deb ]
  [ "$(state_get web1 '.settings.cpus | tag')" = '!!int' ]
  [ "$(state_get web1 .settings.memory)" = 8G ]
  [ "$(state_get web1 '.settings.ports[0]')" = 8080:80 ]
  [ ! -e "$PMM_STATE_HOME/draft/web1.yml" ]
  grep -qx "image build --arch arm64 deb" "$PMM_CALLS"
  grep -q "qemu-img create -q -f qcow2 -b $BASE -F qcow2 $PMM_DATA_HOME/machines/web1/disk.qcow2" "$PMM_CALLS"
  [ -f "$PMM_DATA_HOME/machines/web1/efivars.fd" ]
  [ "$(state_get web1 .image)" = local/deb ]
  [ "$(state_get web1 .key)" = "$KEY" ]
  [ "$(state_get web1 .user)" = pmm ]
  # a boot account is the stock image's (tart): this build has none
  ! grep -q '^boot:' "$(state_file web1)"
  [ "$(held deb)" = web1 ]
  ! grep -q qemu-system "$PMM_CALLS"
  [ "$(mach_state web1)" = stopped ]
  ANFS_JSON=true run cmd_list
  [ "$(yq -p json -r '.[] | select(.name == "web1") | (.source // "null") + " " + .image + " " + .state' <<< "$output")" = "null local/deb stopped" ]
  run cli_call path web1
  [ "$status" -ne 0 ]
  [[ "$output" == *"web1 has no definition"* ]]
}

@test "run: the image's name, then -2; --name; a name that exists or is defined is 73; up takes no --image" {
  run cli_call run deb
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(mach_state deb)" = running ]
  run cli_call run local/deb
  [ "$status" -eq 0 ]
  [ "$(mach_state deb-2)" = running ]
  run cli_call run deb --name web1 --no-start
  [ "$status" -eq 0 ]
  mach_exists web1
  run cli_call run deb --name web1
  [ "$status" -eq 73 ]
  [[ "$output" == *"web1 already exists"* ]]
  machine "$PMM_MACHINES_HOME/mine" "image: deb"
  load_machines
  run cli_call run deb --name mine
  [ "$status" -eq 73 ]
  [[ "$output" == *"mine is defined (local/mine): pmm up mine"* ]]
  run cli_call up --image deb
  [ "$status" -eq 64 ]
  [[ "$output" == *"unknown option '--image'"* ]]
  run cli_call create web9 --image deb
  [ "$status" -ne 0 ]
  run cli_call run
  [ "$status" -eq 64 ]
  run cli_call run deb --name Web2
  [ "$status" -ne 0 ]
  run cli_call run deb --rm --no-start
  [ "$status" -eq 64 ]
  run cli_call run nope --name web3
  [ "$status" -ne 0 ]
  [[ "$output" == *"image 'nope' not found"* ]]
  ! mach_exists web3
  [ ! -e "$PMM_STATE_HOME/draft" ]
  # settings that do not validate, and a making that dies part way: no draft is left either
  run cli_call run deb --name web3 --memory bogus
  [ "$status" -ne 0 ]
  [ ! -e "$PMM_STATE_HOME/draft" ]
  image_ensure_built() { die "the build failed"; }
  run cli_call run deb --name web3
  [ "$status" -ne 0 ]
  [[ "$output" == *"the build failed"* ]]
  ! mach_exists web3
  [ ! -e "$PMM_STATE_HOME/draft" ]
}

@test "run: the settings live with the disk: down, then up, starts it with them; remove leaves no trace" {
  mkdir -p "$T/x"
  before=$(find "$PMM_CONFIG_HOME" | sort)
  run cli_call run --cpus 4 --share "$T/x" deb
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"deb is up: pmm shell deb"* ]]
  [ "$(find "$PMM_CONFIG_HOME" | sort)" = "$before" ]
  cli_call down deb >/dev/null
  [ "$(mach_state deb)" = stopped ]
  : > "$PMM_CALLS"
  run cli_call up deb
  [ "$status" -eq 0 ]
  grep -q -- "-smp 4 .*file=$PMM_DATA_HOME/machines/deb/disk.qcow2.*path=$T/x,security_model=none" "$PMM_CALLS"
  # show prints them as the YAML a definition holds
  run cli_call show deb
  echo "$output"
  [[ "$output" == *"definition  none: it was run from an image"* ]]
  [ "$(sed -n '/^# machines\/deb\/machine.yml$/,$p' <<< "$output" | yq -r '.image + " " + (.cpus | tostring) + " " + .shares[0]')" = "deb 4 $T/x" ]
  # reset keeps them: they are nowhere else
  cli_call reset -y deb >/dev/null
  [ "$(state_get deb .settings.cpus)" = 4 ]
  run cli_call remove -y deb
  [ "$status" -eq 0 ]
  [ "$output" = "Removed deb" ]
  [ ! -e "$PMM_DATA_HOME/machines/deb" ] && [ ! -e "$PMM_STATE_HOME/run/deb" ]
  [ ! -e "$PMM_STATE_HOME/draft" ]
  [ "$(find "$PMM_CONFIG_HOME" | sort)" = "$before" ]
  [ -z "$(held deb)" ]
  ANFS_JSON=true run cmd_list
  [ "$(yq -p json -r 'length' <<< "$output")" = 0 ]
}

@test "run --rm: the machine goes when it is shut down" {
  run cli_call run --rm deb
  [ "$status" -eq 0 ]
  [ "$(state_get deb .rm)" = true ]
  run cli_call down deb
  echo "$output"
  [[ "$output" == *"Stopping deb"*"Removed deb"* ]]
  ! mach_exists deb
  [ ! -e "$PMM_DATA_HOME/machines/deb" ]
  # one run without it stays
  cli_call run deb >/dev/null
  cli_call down deb >/dev/null
  mach_exists deb
}

@test "run --disk grows the overlay" {
  cli_call run deb --name big --no-start --disk 40G >/dev/null
  grep -q "qemu-img resize -q $PMM_DATA_HOME/machines/big/disk.qcow2 40G" "$PMM_CALLS"
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
  grep -q -- "-smp 1 -m 1024 .*file=$PMM_DATA_HOME/machines/a/disk.qcow2.*hostfwd=tcp:127.0.0.1:42300-:22,hostfwd=tcp:127.0.0.1:8080-:80" "$PMM_CALLS"
  grep -q -- "-smp 4 -m 4096 .*file=$PMM_DATA_HOME/machines/b/disk.qcow2.*hostfwd=tcp:127.0.0.1:42301-:22" "$PMM_CALLS"
  [ "$(held deb)" = "a b" ]
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

@test "up: a machine is named; none is 64" {
  run cli_call up
  [ "$status" -eq 64 ]
  run cli_call up nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"machine 'nope' not found"* ]]
}

@test "shell and exec: the command goes to the machine's port as its user, or as -u" {
  cli_call run deb >/dev/null
  : > "$PMM_CALLS"
  cli_call exec deb -- uname -a
  grep -qx "ssh uname -a" "$PMM_CALLS"
  : > "$PMM_CALLS"
  cli_call shell deb -- ls -l /tmp     # shell with a command is exec
  grep -qx "ssh ls -l /tmp" "$PMM_CALLS"
  run cli_call exec deb
  [ "$status" -eq 64 ]
  run cli_call exec deb --
  [ "$status" -eq 64 ]
  cli_call down deb >/dev/null
  run cli_call exec deb -- true
  [ "$status" -ne 0 ]
  [[ "$output" == *"deb is not running (pmm up deb)"* ]]
}

@test "a machine stays on the build it was created from; show says there is a newer one; reset moves it" {
  cli_call run deb --name web1 --no-start >/dev/null
  fake_build deb dddddddddddddddd
  : > "$BASE"     # the superseded disk is still there (image prune keeps what a machine is on)
  run cli_call show web1
  echo "$output"
  [[ "$output" == *"build       $KEY (arm64, qemu); local/deb has a newer build (pmm reset web1)"* ]]
  [ "$(state_get web1 .key)" = "$KEY" ]
  run cli_call reset -y web1
  [ "$status" -eq 0 ]
  [ "$(state_get web1 .key)" = dddddddddddddddd ]
  [ "$(held deb)" = web1 ]
  (load_images; [ -z "$(holders_of deb arm64 "$KEY")" ] && [ "$(holders_of deb arm64 dddddddddddddddd)" = web1 ])
}

@test "snapshot and reset: a copy that holds the build too; reset to it puts the disk and the record back" {
  cli_call run deb --name web1 --no-start >/dev/null
  echo one > "$PMM_DATA_HOME/machines/web1/disk.qcow2"
  run cli_call "snapshot create" web1 s1
  [ "$status" -eq 0 ]
  [ "$(cat "$PMM_DATA_HOME/snapshots/web1/s1/disk.qcow2")" = one ]
  [ "$(held deb)" = "web1 web1@s1" ]
  ANFS_JSON=true run cli_call "snapshot list" web1
  [ "$(yq -p json -r '.[] | .name + " " + .build' <<< "$output")" = "s1 $KEY" ]
  echo two > "$PMM_DATA_HOME/machines/web1/disk.qcow2"
  run cli_call reset -y web1 nope
  [ "$status" -ne 0 ]
  run cli_call reset -y web1 s1
  [ "$status" -eq 0 ]
  [ "$(cat "$PMM_DATA_HOME/machines/web1/disk.qcow2")" = one ]
  [ "$(state_get web1 .key)" = "$KEY" ]
  run cli_call reset web1 s1 </dev/null
  [ "$status" -ne 0 ]     # asks, and there is no terminal
  run cli_call snapshot web1 s2
  [ "$status" -ne 0 ]     # a group: the old `snapshot <machine> [name]` is no command
}

@test "snapshot: with no name it is named for the time; remove deletes one, and what it held" {
  cli_call run deb --name web1 --no-start >/dev/null
  run cli_call "snapshot create" web1
  [ "$status" -eq 0 ]
  [[ "$(mach_snapshots web1)" =~ ^[0-9]{8}-[0-9]{6}$ ]]
  cli_call "snapshot create" web1 s1 >/dev/null
  # tab completes the snapshots of the machine on the line
  run "$PMM" __complete snapshot remove web1 ""
  [[ "$(sort <<< "$output" | tail -n 1)" == s1 ]] && [ "${#lines[@]}" -eq 2 ]
  run "$PMM" __complete reset -y web1 ""
  [ "${#lines[@]}" -eq 2 ]
  run "$PMM" __complete reset other ""
  [ -z "$output" ]
  run cli_call "snapshot remove" web1 s1 </dev/null
  [ "$status" -ne 0 ]     # asks
  run cli_call "snapshot remove" -y web1 nope
  [ "$status" -ne 0 ]
  run cli_call "snapshot remove" -y web1 s1
  [ "$status" -eq 0 ]
  [ ! -e "$PMM_DATA_HOME/snapshots/web1/s1" ]
  [[ "$(held deb)" != *"web1@s1"* ]]
  cli_call "snapshot remove" -y web1 "$(mach_snapshots web1)" >/dev/null
  [ "$(held deb)" = web1 ]
  [ ! -e "$PMM_DATA_HOME/snapshots/web1" ]
}

@test "remove: the disk and the snapshots go, and nothing holds the build; a definition is never touched" {
  add_source acme
  machine "$T/srcs/acme/machines/db" "image: deb"
  machine "$PMM_MACHINES_HOME/mine" "image: deb"
  load_machines
  cli_call run deb --name web1 --no-start >/dev/null
  PMM_INSTALL=create cli_call install db mine >/dev/null
  cli_call "snapshot create" web1 s1 >/dev/null
  [ "$(held deb)" = "db mine web1 web1@s1" ]
  run cli_call remove -y web1 db mine
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed web1"* ]]
  [[ "$output" == *"Removed db (still defined by acme)"* ]]
  [[ "$output" == *"Removed mine (still defined by local)"* ]]
  [ -z "$(held deb)" ]
  [ ! -d "$PMM_DATA_HOME/machines/web1" ] && [ ! -d "$PMM_DATA_HOME/snapshots/web1" ]
  [ -f "$T/srcs/acme/machines/db/machine.yml" ]
  [ -f "$PMM_MACHINES_HOME/mine/machine.yml" ]     # a person's own definition is theirs to delete
  run cli_call remove -y web1
  [ "$status" -ne 0 ]
}

@test "implode: every machine stopped and removed, the builds too, nothing of pmm's left" {
  cli_call run deb >/dev/null
  cli_call implode -y >/dev/null
  [ ! -e "$PMM_DATA_HOME" ] && [ ! -e "$PMM_STATE_HOME" ] && [ ! -e "$PMM_CONFIG_HOME" ]
}

@test "up on Linux without /dev/kvm: says once why the machine is emulated" {
  PMM_HOST_OS=linux PMM_KVM_DEV="$T/no-kvm"
  run cli_call run deb --no-start
  [ "$status" -eq 0 ]
  [ "$(grep -c 'emulated (tcg)' <<< "$output")" = 1 ]
  run cli_call up deb
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'emulated (tcg)' <<< "$output")" = 1 ]
  [[ "$output" == *"$T/no-kvm is missing"* ]]
  [[ "$output" == *"Started deb (arm64, tcg)"* ]]
}
