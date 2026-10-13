#!/usr/bin/env bats
# sources.sh / settings.sh: finding machines across sources, profiles, validate
load helper

setup() {
  setup_pmm
  fake_build deb
}

@test "list and path: local shadows a source; a made machine is stopped; one without a definition lists" {
  add_source acme
  machine "$T/srcs/acme/machines/web" "image: deb"
  machine "$T/srcs/acme/machines/db" "image: deb"
  machine "$PMM_MACHINES_HOME/web" "image: deb"
  load_machines
  mach_find web;      [ "$M_ID" = local/web ]
  mach_find db;       [ "$M_ID" = acme/db ]
  run mach_find acme/web
  [ "$status" -ne 0 ]
  [[ "$output" == *"acme/web is shadowed by local/web"* ]]
  state_write "$(state_file old)" local/deb arm64 qemu aaaaaaaaaaaaaaaa /x.qcow2 pim /k
  state_write "$(state_file db)" local/deb arm64 qemu aaaaaaaaaaaaaaaa /x.qcow2 pim /k
  ANFS_JSON=true run cmd_list
  echo "$output"
  [ "$(yq -p json -r '.[] | select(.name == "web" and .source == "local") | .state' <<< "$output")" = defined ]
  [ "$(yq -p json -r '.[] | select(.name == "web" and .source == "acme") | .state' <<< "$output")" = shadowed ]
  [ "$(yq -p json -r '.[] | select(.name == "db") | .state + " " + .image' <<< "$output")" = "stopped local/deb" ]
  [ "$(yq -p json -r '.[] | select(.name == "old") | .source' <<< "$output")" = null ]
  run cmd_path db
  [ "$output" = "$HOME/.local/share/anfs/sources/acme/machines/db" ]
  run cmd_path old
  [ "$status" -ne 0 ]
  run cli_call list --names
  [ "$status" -eq 64 ]
}

@test "profiles: the higher-priority source wins by name; a setting is the machine's, then the profile's" {
  add_source acme
  printf 'small: {cpus: 1, memory: 1G}\nlarge: {cpus: 8, memory: 16G, disk: 80G}\n' > "$T/srcs/acme/machines/profiles.yml"
  printf 'large: {cpus: 6, memory: 12G}\n' > "$PMM_MACHINES_HOME/profiles.yml"
  machine "$PMM_MACHINES_HOME/a" "$(printf 'image: deb\nprofile: large\nmemory: 4G')"
  machine "$PMM_MACHINES_HOME/b" "image: deb"
  load_machines
  [ "$(profile_get small cpus)" = 1 ]
  [ "$(profile_get large cpus)" = 6 ]
  [ -z "$(profile_get large disk)" ]     # the whole profile is the local one's
  [ "$(mach_setting local/a cpus)" = 6 ]
  [ "$(mach_setting local/a memory)" = 4G ]
  [ -z "$(mach_setting local/b cpus)" ]
  [ "$(size_mb 8G)" = 8192 ]; [ "$(size_mb 512M)" = 512 ]; [ "$(size_mb 2048)" = 2048 ]
  run size_mb lots
  [ "$status" -ne 0 ]
}

@test "profiles: the image names the default (image.yml machine.profile)" {
  fake_build nas cccccccccccccccc 'machine: {profile: big, min: {memory: 8G, cpus: 2}}'
  printf 'big: {cpus: 4, memory: 16G}\n' > "$PMM_MACHINES_HOME/profiles.yml"
  machine "$PMM_MACHINES_HOME/n1" "image: nas"
  machine "$PMM_MACHINES_HOME/n2" "$(printf 'image: nas\nmemory: 4G')"
  load_machines
  [ "$(mach_profile local/n1)" = big ]
  [ "$(mach_setting local/n1 memory)" = 16G ]
  run cmd_validate n1
  [ "$status" -eq 0 ]
  run cmd_validate n2
  [ "$status" -ne 0 ]
  [[ "$output" == *"memory 4G is below nas's minimum of 8G"* ]]
}

@test "validate: an unknown key, a missing image, a bad size, port and profile" {
  machine "$PMM_MACHINES_HOME/ok" "$(printf 'image: deb\ncpus: 2\nmemory: 2G\ndisk: 30G\nports: ["8080:80"]')"
  machine "$PMM_MACHINES_HOME/bad" "$(printf 'image: nope\ndisks: []\nmemory: lots\nports: [http]\nprofile: huge\ndisk: 40')"
  machine "$PMM_MACHINES_HOME/none" "cpus: 2"
  load_machines
  run cmd_validate ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"local/ok ok"* ]]
  run cmd_validate bad
  [ "$status" -ne 0 ]
  [[ "$output" == *"disks: is not a machine setting"* ]]
  [[ "$output" == *"image 'nope' not found"* ]]
  [[ "$output" == *"memory 'lots'"* ]]
  [[ "$output" == *"ports: 'http' is not host:guest"* ]]
  [[ "$output" == *"profile 'huge' not found"* ]]
  [[ "$output" == *"disk '40'"* ]]
  run cmd_validate none
  [[ "$output" == *"image: is required"* ]]
  run cmd_validate
  [[ "$output" == *"3 machine(s):"* ]]
}

@test "install: source/ is every machine of the source; PMM_INSTALL=validate only validates" {
  add_source acme
  machine "$T/srcs/acme/machines/web" "image: deb"
  machine "$T/srcs/acme/machines/db" "image: deb"
  load_machines
  PMM_INSTALL=validate run cmd_install acme/
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 machine(s): 0 error(s)"* ]]
  ! grep -q qemu "$PIM_CALLS"
  PMM_INSTALL=create run cmd_install acme/
  [ "$status" -eq 0 ]
  mach_exists web; mach_exists db
  ! grep -q qemu-system "$PIM_CALLS"
  run cmd_install nope/
  [ "$status" -ne 0 ]
}

@test "completion: machines by file name, with source/name; images and profiles" {
  add_source acme
  machine "$T/srcs/acme/machines/web" "image: deb"
  machine "$PMM_MACHINES_HOME/mine" "image: deb"
  printf 'small: {cpus: 1}\n# a comment\nlarge:\n  cpus: 8\n' > "$T/srcs/acme/machines/profiles.yml"
  run complete_machine
  [ "$output" = "$(printf 'mine\nweb\nacme/web')" ]
  run complete_machine_spec
  [[ "$output" == *"acme/"* ]]
  run complete_image
  [ "$output" = deb ]
  run complete_profile
  [ "$output" = "$(printf 'small\nlarge')" ]
}
