#!/usr/bin/env bats
# registry.sh: the builds list, and the holds another tool puts on a build
load helper

# A build as build_one leaves it, without booting anything: the disk and its meta.yml
fake_build() {
  KEY=$(build_key local/d arm64)
  mkdir -p "$PIM_DATA_HOME/images/d/arm64"
  : > "$PIM_DATA_HOME/images/d/arm64/$KEY.qcow2"
  meta_write_build local/d arm64 "$KEY" ""
}

setup() {
  setup_pim
  image "$PIM_IMAGES_HOME/d" "$(deb_yml)"
  load_sources
  fake_build
}

@test "builds: one row per built image and arch, with the disk, the user and the key" {
  ANFS_JSON=true run cli_call builds
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(yq -p json -r '.[0].name' <<< "$output")" = d ]
  [ "$(yq -p json -r '.[0].source' <<< "$output")" = local ]
  [ "$(yq -p json -r '.[0].arch' <<< "$output")" = arm64 ]
  [ "$(yq -p json -r '.[0].backend' <<< "$output")" = qemu ]
  [ "$(yq -p json -r '.[0].key' <<< "$output")" = "$KEY" ]
  [ "$(yq -p json -r '.[0].disk' <<< "$output")" = "$PIM_DATA_HOME/images/d/arm64/$KEY.qcow2" ]
  [ "$(yq -p json -r '.[0].user' <<< "$output")" = pim ]
  [ "$(yq -p json -r '.[0].sshkey' <<< "$output")" = "$PIM_DATA_HOME/keys/d/id_ed25519" ]
  [ "$(yq -p json -r '.[0].held | length' <<< "$output")" = 0 ]
  ANFS_JSON=true run cli_call builds nothing
  [ "$(yq -p json -r 'length' <<< "$output")" = 0 ]
}

@test "hold and release: a file beside the build, listed by builds and show" {
  cmd_hold d arm64 "$KEY" pmm:web1
  cmd_hold d arm64 "$KEY" pmm:web1@s1
  [ -f "$PIM_DATA_HOME/images/d/arm64/holds/$KEY/pmm:web1" ]
  ANFS_JSON=true run cli_call builds d
  [ "$(yq -p json -r '.[0].held | join(",")' <<< "$output")" = "pmm:web1,pmm:web1@s1" ]
  run cli_call show d
  [[ "$output" == *"held by   pmm:web1 pmm:web1@s1"* ]]
  cmd_release d arm64 "$KEY" pmm:web1
  cmd_release d arm64 "$KEY" pmm:web1@s1
  cmd_release d arm64 "$KEY" pmm:web1@s1   # one that is not there is not an error
  [ ! -d "$PIM_DATA_HOME/images/d/arm64/holds" ]
}

@test "hold: refused for a build that is not there, and for a holder that is not a plain name" {
  run cmd_hold d arm64 0000000000000000 pmm:x
  [ "$status" -ne 0 ]
  [[ "$output" == *"no arm64 build"* ]]
  run cmd_hold d arm64 "$KEY" ../x
  [ "$status" -ne 0 ]
}

@test "remove: refuses a held image without -f" {
  cmd_hold d arm64 "$KEY" pmm:web1
  run cli_call remove -y d
  [ "$status" -ne 0 ]
  [[ "$output" == *"d (arm64) is held by pmm:web1"* ]]
  [ -f "$PIM_DATA_HOME/images/d/arm64/$KEY.qcow2" ]
  run cli_call remove -y -f d
  [ "$status" -eq 0 ]
  [ ! -d "$PIM_DATA_HOME/images/d" ]
}

@test "clean: a superseded build stays while it is held, and goes once released" {
  cmd_hold d arm64 "$KEY" pmm:web1
  old="$KEY"
  mkdir -p "$PIM_IMAGES_HOME/d/scripts"; echo 'echo new' > "$PIM_IMAGES_HOME/d/scripts/50-new.sh"
  fake_build
  [ "$KEY" != "$old" ]
  KEY="$old"
  run cli_call clean
  [[ "$output" == *"(0 superseded disks)"* ]]
  [ -f "$PIM_DATA_HOME/images/d/arm64/$KEY.qcow2" ]
  cmd_release d arm64 "$KEY" pmm:web1
  run cli_call clean
  [[ "$output" == *"(1 superseded disks)"* ]]
  [ ! -f "$PIM_DATA_HOME/images/d/arm64/$KEY.qcow2" ]
}

@test "the commands that went to pmm say so and exit 64" {
  run cmd_up d
  [ "$status" -eq 64 ]
  [[ "$output" == *"'pim up' is now 'pmm up'"* ]]
}

@test "the cache key ignores machine:, which is pmm's" {
  image "$PIM_IMAGES_HOME/d" "$(deb_yml 'machine: {profile: large}')"
  [ "$(build_key local/d arm64)" = "$KEY" ]
}
