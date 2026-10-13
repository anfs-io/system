#!/usr/bin/env bats
# registry.sh: the image list, and what keeps a build — read from the machines' and the snapshots'
# own records, not kept anywhere
load helper

# A build as build_one leaves it, without booting anything: the disk and its meta.yml
fake_build() {
  KEY=$(build_key local/d arm64)
  mkdir -p "$PMM_DATA_HOME/images/d/arm64"
  : > "$PMM_DATA_HOME/images/d/arm64/$KEY.qcow2"
  meta_write_build local/d arm64 "$KEY" ""
}

# A qemu machine <name> on the build <key> of d, as create leaves its record; [snapshot] is a
# snapshot of it instead
on_build() {
  local f="$PMM_DATA_HOME/machines/$1/state.yml"
  [[ -z "${3:-}" ]] || f="$PMM_DATA_HOME/snapshots/$1/$3/state.yml"
  state_write "$f" local/d arm64 qemu "$2" "$PMM_DATA_HOME/images/d/arm64/$2.qcow2" pmm /k
}

setup() {
  setup_images
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  load_images
  fake_build
}

@test "list: a row per built arch with every key; unbuilt is one row with no arch" {
  image "$PMM_IMAGES_HOME/e" "$(deb_yml)"
  ANFS_JSON=true run cli_call "image list"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(yq -p json -r '.[0] | keys | join(" ")' <<< "$output")" = "name source arch state key disk backend user sshkey held built tested" ]
  [ "$(yq -p json -r 'length' <<< "$output")" = 2 ]
  [ "$(yq -p json -r '.[0].name' <<< "$output")" = d ]
  [ "$(yq -p json -r '.[0].source' <<< "$output")" = local ]
  [ "$(yq -p json -r '.[0].arch' <<< "$output")" = arm64 ]
  [ "$(yq -p json -r '.[0].state' <<< "$output")" = built ]
  [ "$(yq -p json -r '.[0].backend' <<< "$output")" = qemu ]
  [ "$(yq -p json -r '.[0].key' <<< "$output")" = "$KEY" ]
  [ "$(yq -p json -r '.[0].disk' <<< "$output")" = "$PMM_DATA_HOME/images/d/arm64/$KEY.qcow2" ]
  [ "$(yq -p json -r '.[0].user' <<< "$output")" = pmm ]
  [ "$(yq -p json -r '.[0].sshkey' <<< "$output")" = "$PMM_DATA_HOME/keys/d/id_ed25519" ]
  [ "$(yq -p json -r '.[0].held | length' <<< "$output")" = 0 ]
  [ "$(yq -p json -r '.[0].built' <<< "$output")" = "$(meta_get d arm64 .built_at)" ]
  [ "$(yq -p json -r '.[0].tested' <<< "$output")" = false ]
  [ "$(yq -p json -r '.[1] | .name + " " + .state + " " + (.arch | tag) + " " + (.key | tag)' <<< "$output")" = "e unbuilt !!null !!null" ]
  ANFS_JSON=true run cli_call "image list" e
  [ "$(yq -p json -r 'length' <<< "$output")" = 1 ]
  ANFS_JSON=true run cli_call "image list" nothing
  [ "$(yq -p json -r 'length' <<< "$output")" = 0 ]
}

@test "list: a second arch is a second row; a changed definition is stale; tested once test passed" {
  mkdir -p "$PMM_DATA_HOME/images/d/amd64"
  k2=$(build_key local/d amd64)
  : > "$PMM_DATA_HOME/images/d/amd64/$k2.qcow2"
  meta_write_build local/d amd64 "$k2" ""
  meta_set d arm64 '.tested_key = strenv(v)' "$KEY"
  ANFS_JSON=true run cli_call "image list" d
  [ "$(yq -p json -r '[.[] | .arch + ":" + .state + ":" + .tested] | join(" ")' <<< "$output")" = "arm64:built:true amd64:built:false" ]
  mkdir -p "$PMM_IMAGES_HOME/d/scripts"; echo 'echo new' > "$PMM_IMAGES_HOME/d/scripts/50-new.sh"
  ANFS_JSON=true run cli_call "image list" d
  [ "$(yq -p json -r '[.[] | .state + ":" + .tested] | join(" ")' <<< "$output")" = "stale:true stale:false" ]
  run cli_call "image show" d
  [[ "$output" == *"stale     the definition changed since (pmm image build d)"* ]]
}

@test "list: a build whose definition is gone lists with no source" {
  rm -rf "$PMM_IMAGES_HOME/d"
  load_images
  ANFS_JSON=true run cli_call "image list"
  [ "$(yq -p json -r '.[0] | .name + " " + (.source | tag) + " " + .state + " " + .key' <<< "$output")" = "d !!null stale $KEY" ]
}

@test "held: the machines and snapshots on a build, by what their records say; no file is kept" {
  on_build web1 "$KEY"
  on_build web1 "$KEY" s1
  on_build db 0000000000000000
  state_write "$PMM_DATA_HOME/machines/blank/state.yml" "" arm64 qemu "" "" "" ""
  state_write "$PMM_DATA_HOME/machines/mac/state.yml" local/d arm64 tart "$KEY" x owner /k
  state_write "$PMM_DATA_HOME/machines/other/state.yml" local/dd arm64 qemu "$KEY" x pmm /k
  [ "$(holders_of d arm64 "$KEY" | paste -sd' ' -)" = "web1 web1@s1" ]
  [ "$(holders_of d arm64 | paste -sd' ' -)" = "db web1 web1@s1" ]
  [ -z "$(holders_of d amd64)" ]
  ANFS_JSON=true run cli_call "image list" d
  [ "$(yq -p json -r '.[0].held | join(",")' <<< "$output")" = "web1,web1@s1" ]
  run cli_call "image show" d
  [[ "$output" == *"held by   db web1 web1@s1"* ]]
  [ ! -e "$PMM_DATA_HOME/images/d/arm64/holds" ]
  rm -rf "$PMM_DATA_HOME/machines" "$PMM_DATA_HOME/snapshots"
  [ -z "$(holders_of d arm64)" ]
}

@test "remove: refuses an image a machine is on, and one a snapshot is on; -f removes it" {
  on_build web1 "$KEY"
  run cli_call "image remove" -y d
  [ "$status" -ne 0 ]
  [[ "$output" == *"d (arm64) has machines on it: web1"* ]]
  rm -rf "$PMM_DATA_HOME/machines/web1"
  on_build web1 "$KEY" s1
  run cli_call "image remove" -y d
  [ "$status" -ne 0 ]
  [[ "$output" == *"d (arm64) has machines on it: web1@s1"* ]]
  [ -f "$PMM_DATA_HOME/images/d/arm64/$KEY.qcow2" ]
  run cli_call "image remove" -y -f d
  [ "$status" -eq 0 ]
  [ ! -d "$PMM_DATA_HOME/images/d" ]
}

@test "prune: a superseded build stays while a machine is on it, and goes once the machine has" {
  on_build web1 "$KEY"
  old="$KEY"
  mkdir -p "$PMM_IMAGES_HOME/d/scripts"; echo 'echo new' > "$PMM_IMAGES_HOME/d/scripts/50-new.sh"
  fake_build
  [ "$KEY" != "$old" ]
  run cli_call "image prune"
  [[ "$output" == *"(0 superseded disks)"* ]]
  [ -f "$PMM_DATA_HOME/images/d/arm64/$old.qcow2" ]
  rm -rf "$PMM_DATA_HOME/machines/web1"
  run cli_call "image prune"
  [[ "$output" == *"(1 superseded disks)"* ]]
  [ ! -f "$PMM_DATA_HOME/images/d/arm64/$old.qcow2" ]
  [ -f "$PMM_DATA_HOME/images/d/arm64/$KEY.qcow2" ]
}

@test "hold, release, builds, the old names: none is a command any more" {
  for c in hold release builds migrate "image hold" "image builds" "image verify" "image publish" "image clean"; do
    run "$PMM" $c d
    [ "$status" -eq 64 ]
  done
}

@test "the cache key ignores machine:, which a build never reads" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml 'machine: {profile: large}')"
  [ "$(build_key local/d arm64)" = "$KEY" ]
}
