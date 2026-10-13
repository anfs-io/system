#!/usr/bin/env bats
# build.sh: the cache key, and the pipeline with qemu and ssh stubbed; a from: of its own name
load helper

setup() {
  setup_images
  image "$PMM_IMAGES_HOME/d" "$(deb_yml 'description: one')"
  # the ISO, already cached and verified
  mkdir -p "$ANFS_ISO_HOME"
  echo iso > "$ANFS_ISO_HOME/a.iso"
  sleep 1; echo "$SHA" > "$ANFS_ISO_HOME/a.iso.sha256"
  wait_ssh() { return 0; }
}

@test "cache key: stable under key order, description, machine: and README.md" {
  load_images
  k1=$(build_key local/d arm64)
  image "$PMM_IMAGES_HOME/d" "$(printf 'description: two\nmachine: {profile: large}\n%s' "$(deb_yml | awk 'NR>1' ; deb_yml | head -n1)")"
  echo "# d" > "$PMM_IMAGES_HOME/d/README.md"
  [ "$(build_key local/d arm64)" = "$k1" ]
  [ "$(build_key local/d amd64)" != "$k1" ]
  # nor what another arch installs from, the arch list, a timeout, an ISO id of the same sum
  printf -- '- {id: t-other, url: https://x/a.iso, checksum: "sha256:%s"}\n' "$SHA" >> "$HOME/.config/anfs/isos.yml"
  image "$PMM_IMAGES_HOME/d" "$(printf 'distro: debian\narch: [arm64]\niso: {arm64: t-other, amd64: nosuch}\ntimeouts: {ssh: 9}')"
  [ "$(build_key local/d arm64)" = "$k1" ]
  # what the build runs with is in it
  echo 'build: {cpus: 8}' >> "$PMM_IMAGES_HOME/d/image.yml"
  [ "$(build_key local/d arm64)" != "$k1" ]
  image "$PMM_IMAGES_HOME/c" "from: d"
  load_images
  run build_key local/c arm64
  [ "$status" -ne 0 ]   # the parent is not built yet
}

@test "cache key: changes with the answer file, a vars: value, a step, a file, the ISO's pinned sum" {
  local -a keys=()
  d="$PMM_IMAGES_HOME/d"
  image "$d" "$(deb_yml 'vars: {TIMEZONE: UTC}')"
  load_images
  k() { keys+=("$(build_key local/d arm64)"); }
  k
  echo '# changed' >> "$d/preseed.cfg"; k
  printf '%s\n' "$(deb_yml 'vars: {TIMEZONE: Asia/Singapore}')" > "$d/image.yml"; k
  mkdir -p "$d/provision"; echo 'echo x' > "$d/provision/50-x.sh"; k
  echo 'echo y' > "$d/provision/50-x.sh"; k
  mkdir -p "$d/files/etc"; echo a > "$d/files/etc/f"; k
  echo b > "$d/files/etc/f"; k
  # the catalogue entry's hash: the same id, another file
  SHA=${SHA/6e93/0000} iso_catalog; k
  printf '%s\n' "${keys[@]}"
  [ "$(printf '%s\n' "${keys[@]}" | sort -u | wc -l)" -eq 8 ]
  # scripts/ is not where steps are any more: nothing there is in the key
  mkdir -p "$d/scripts"; echo 'echo x' > "$d/scripts/50-x.sh"
  [ "$(build_key local/d arm64)" = "${keys[7]}" ]
}

@test "build: install, boot, its own steps in order, finalize, poweroff; registered; then a cache hit" {
  load_images
  mkdir -p "$PMM_IMAGES_HOME/d/provision"
  echo 'echo app' > "$PMM_IMAGES_HOME/d/provision/50-app.sh"; echo 'echo base' > "$PMM_IMAGES_HOME/d/provision/10-base.sh"
  run cmd_image_build d
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"== 10-base.sh"*"== 50-app.sh"*"== finalize"* ]]
  grep -q -- '-kernel .*install.a64/vmlinuz -initrd .*/initrd -append auto=true priority=critical preseed/file=/preseed.cfg console=ttyAMA0' "$PMM_CALLS"
  grep -q 'ssh .*poweroff' "$PMM_CALLS"
  key=$(meta_get d arm64 .cache_key)
  [ -f "$PMM_DATA_HOME/images/d/arm64/$key.qcow2" ]
  [ -f "$PMM_DATA_HOME/images/d/arm64/$key-efivars.fd" ]
  [ "$(meta_get d arm64 .id)" = local/d ]
  [ "$(meta_get d arm64 .iso)" = t-arm64 ]
  [ ! -d "$PMM_STATE_HOME/build/d-arm64" ]
  : > "$PMM_CALLS"
  run cmd_image_build d
  [[ "$output" == *"is up to date ($key)"* ]]
  ! grep -q qemu-system "$PMM_CALLS"
}

@test "build: a root image with no steps runs none but finalize; nothing comes from pmm's library" {
  load_images
  run cmd_image_build d
  [ "$status" -eq 0 ]
  [[ "$output" == *"== finalize"* ]]
  [[ "$output" != *"10-base.sh"* ]]
  [ "$(cd "$PMM_LIB_DIR/defaults" && find . -type f)" = ./finalize.sh ]
}

@test "build: the answer file and the key are injected into the initrd" {
  load_images
  real=$(type -ap bsdtar | grep -v /stubs/ | head -n1)
  [ -n "$real" ] || skip "no bsdtar"
  # keep the workspace to inspect it
  _build_cleanup() { :; }
  cmd_image_build d >/dev/null
  w="$PMM_STATE_HOME/build/d-arm64"
  gzip -dc "$w/inject.cpio.gz" | "$real" -tf - | sort > "$T/members"
  grep -qx './preseed.cfg' "$T/members"
  grep -qx './pmm/authorized_keys' "$T/members"
  grep -q 'passwd/username string pmm' "$w/inject/preseed.cfg"
}

@test "build: a failing installer keeps the previous build and leaves no partial disk" {
  load_images
  cmd_image_build d >/dev/null
  key=$(meta_get d arm64 .cache_key)
  mkdir -p "$PMM_IMAGES_HOME/d/provision"; echo 'echo new' > "$PMM_IMAGES_HOME/d/provision/50-new.sh"
  PMM_STUB_INSTALL_RC=3 run cmd_image_build d
  [ "$status" -ne 0 ]
  [[ "$output" == *"the installer failed (exit 3)"* ]]
  [ "$(meta_get d arm64 .cache_key)" = "$key" ]
  [ -f "$PMM_DATA_HOME/images/d/arm64/$key.qcow2" ]
  ! ls "$PMM_DATA_HOME"/images/d/arm64/*.part 2>/dev/null
}

@test "from: a child is an overlay on its parent's build, built after it" {
  image "$PMM_IMAGES_HOME/c" "from: d"
  mkdir -p "$PMM_IMAGES_HOME/c/provision"; echo 'echo c' > "$PMM_IMAGES_HOME/c/provision/10-c.sh"
  load_images
  run cmd_image_build c
  [ "$status" -eq 0 ]
  pkey=$(meta_get d arm64 .cache_key)
  grep -q "qemu-img create -q -f qcow2 -b $PMM_DATA_HOME/images/d/arm64/$pkey.qcow2 -F qcow2" "$PMM_CALLS"
  [ "$(meta_get c arm64 .parent.id)" = local/d ]
  [ -n "$(dependents_of_disk "$PMM_DATA_HOME/images/d/arm64/$pkey.qcow2")" ]
  run cli_call "image remove" -y d
  [ "$status" -ne 0 ]
  [[ "$output" == *"c/arm64 is built on d"* ]]
  # -f would put a new disk where the one c is an overlay on is
  echo MARK > "$PMM_DATA_HOME/images/d/arm64/$pkey.qcow2"
  run cli_call "image build" -f d
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"local/d (arm64): c/arm64 built on, or running from, its build $pkey"* ]]
  [ "$(cat "$PMM_DATA_HOME/images/d/arm64/$pkey.qcow2")" = MARK ]
  run cli_call "image build" -f c
  [ "$status" -eq 0 ]
  [[ "$output" == *"== build local/c"* ]]
}

@test "a build that is there is never built again: an earlier build the definition is back at is taken as it is" {
  cmd_image_build d >/dev/null
  k1=$(meta_get d arm64 .cache_key)
  at=$(meta_get d arm64 .built_at)
  echo MARK > "$PMM_DATA_HOME/images/d/arm64/$k1.qcow2"
  cp "$PMM_IMAGES_HOME/d/image.yml" "$T/was.yml"
  echo 'vars: {TIMEZONE: UTC}' >> "$PMM_IMAGES_HOME/d/image.yml"
  cmd_image_build d >/dev/null
  [ "$(meta_get d arm64 .cache_key)" != "$k1" ]
  cp "$T/was.yml" "$PMM_IMAGES_HOME/d/image.yml"
  : > "$PMM_CALLS"
  run cmd_image_build d
  echo "$output"
  [[ "$output" == *"local/d (arm64) is up to date ($k1)"* ]]
  ! grep -q qemu-system "$PMM_CALLS"
  [ "$(meta_get d arm64 .cache_key)" = "$k1" ]
  [ "$(cat "$PMM_DATA_HOME/images/d/arm64/$k1.qcow2")" = MARK ]
}

@test "from: its own name: adding the override, and removing it, never rebuilds the root under what is on it" {
  add_source user
  add_source core
  image "$T/srcs/core/machines/images/debian-13" "$(deb_yml)"
  load_images
  cmd_image_build debian-13 >/dev/null
  d="$PMM_DATA_HOME/images/debian-13/arm64"
  pkey=$(meta_get debian-13 arm64 .cache_key)
  at=$(meta_get debian-13 arm64 .built_at)
  meta_set debian-13 arm64 '.tested_key = strenv(v)' "$pkey"
  echo MARK > "$d/$pkey.qcow2"
  # a higher source overrides it: core's is the same build, now under its own record
  image "$T/srcs/user/machines/images/debian-13" "from: debian-13"
  load_images
  : > "$PMM_CALLS"
  run cmd_image_build debian-13
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"core/debian-13 (arm64) is up to date ($pkey)"*"== build user/debian-13"* ]]
  [[ "$output" != *"== build core/debian-13"* ]]
  [ "$(cat "$d/$pkey.qcow2")" = MARK ]
  [ "$(meta_get debian-13@core arm64 .cache_key)" = "$pkey" ]
  [ "$(meta_get debian-13@core arm64 .built_at)" = "$at" ]
  [ "$(meta_get debian-13@core arm64 .tested_key)" = "$pkey" ]
  key=$(meta_get debian-13 arm64 .cache_key)
  [ "$(meta_get debian-13 arm64 .id)" = user/debian-13 ]

  # a machine made from core's definition is on core's build, by the image's name
  image_build core/debian-13 arm64
  [ "$B_SOURCE/$B_NAME $B_KEY" = "core/debian-13 $pkey" ]
  state_write "$PMM_DATA_HOME/machines/m1/state.yml" "$B_SOURCE/$B_NAME" arm64 "$B_BACKEND" "$B_KEY" "$B_DISK" "$B_USER" "$B_SSHKEY"
  [ "$(holders_of debian-13 arm64 "$pkey")" = m1 ]
  [ -z "$(holders_of debian-13 arm64 "$key")" ]
  run cli_call "image remove" -y debian-13
  [ "$status" -ne 0 ]
  [[ "$output" == *"debian-13 (arm64) has machines on it: m1"* ]]
  run cli_call "image build" -f core/debian-13
  [ "$status" -ne 0 ]
  [[ "$output" == *"m1 debian-13/arm64 built on, or running from, its build $pkey"* ]]

  # the override goes: core's is the name's build again, the same disk, and one record
  rm -rf "$T/srcs/user/machines/images/debian-13"
  load_images
  : > "$PMM_CALLS"
  run cmd_image_build debian-13
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"core/debian-13 (arm64) is up to date ($pkey)"* ]]
  ! grep -q qemu-system "$PMM_CALLS"
  [ "$(cat "$d/$pkey.qcow2")" = MARK ]
  [ "$(meta_get debian-13 arm64 .id) $(meta_get debian-13 arm64 .cache_key)" = "core/debian-13 $pkey" ]
  [ "$(meta_get debian-13 arm64 .tested_key)" = "$pkey" ]
  [ ! -e "$d/meta@core.yml" ]
  # the override's build is superseded: prune takes it, and keeps what m1 is on
  run cmd_image_prune
  [[ "$output" == *"Pruned (1 superseded disks)"* ]]
  [ ! -e "$d/$key.qcow2" ] && [ -f "$d/$pkey.qcow2" ]
}

@test "prune: the record of a shadowed definition that is gone goes" {
  add_source user
  add_source core
  image "$T/srcs/core/machines/images/debian-13" "$(deb_yml)"
  image "$T/srcs/user/machines/images/debian-13" "from: debian-13"
  load_images
  cmd_image_build debian-13 >/dev/null
  d="$PMM_DATA_HOME/images/debian-13/arm64"
  [ -f "$d/meta@core.yml" ]
  run cmd_image_prune
  [ -f "$d/meta@core.yml" ]
  rm -rf "$T/srcs/core/machines/images/debian-13"
  load_images
  run cmd_image_prune
  [ ! -e "$d/meta@core.yml" ]
  # its disk stays: the other build is an overlay on it
  [ "$(ls "$d"/*.qcow2 | wc -l)" -eq 2 ]
}

@test "from: its own name: a user source's debian-13 with one step builds on core's, and both builds stay" {
  add_source user
  add_source core
  image "$T/srcs/core/machines/images/debian-13" "$(deb_yml)"
  mkdir -p "$T/srcs/core/machines/images/debian-13/provision"; echo 'echo base' > "$T/srcs/core/machines/images/debian-13/provision/10-base.sh"
  image "$T/srcs/user/machines/images/debian-13" "from: debian-13"
  mkdir -p "$T/srcs/user/machines/images/debian-13/provision"; echo 'echo mine' > "$T/srcs/user/machines/images/debian-13/provision/50-mine.sh"
  load_images
  [ "$(canon debian-13)" = user/debian-13 ]
  run cmd_image_build debian-13
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"== build core/debian-13"*"== 10-base.sh"*"== build user/debian-13"*"== 50-mine.sh"* ]]
  d="$PMM_DATA_HOME/images/debian-13/arm64"
  key=$(meta_get debian-13 arm64 .cache_key)
  pkey=$(meta_get debian-13@core arm64 .cache_key)
  [ -n "$pkey" ] && [ "$pkey" != "$key" ]
  [ "$(meta_get debian-13 arm64 .id)" = user/debian-13 ]
  [ "$(meta_get debian-13 arm64 .parent.disk)" = "$d/$pkey.qcow2" ]
  [ "$(yq -r .id "$d/meta@core.yml")" = core/debian-13 ]
  grep -q "qemu-img create -q -f qcow2 -b $d/$pkey.qcow2 -F qcow2" "$PMM_CALLS"
  # again: neither is rebuilt (the two records do not replace each other)
  : > "$PMM_CALLS"
  run cmd_image_build debian-13
  [[ "$output" == *"core/debian-13 (arm64) is up to date ($pkey)"*"user/debian-13 (arm64) is up to date ($key)"* ]]
  ! grep -q qemu-system "$PMM_CALLS"
  # prune keeps the disk the effective build is an overlay on; list shows one built row
  run cmd_image_prune
  [[ "$output" == *"Pruned (0 superseded disks)"* ]]
  [ -f "$d/$pkey.qcow2" ] && [ -f "$d/$key.qcow2" ]
  ANFS_JSON=true run cmd_image_list debian-13
  [ "$(yq -p json -r '[.[] | .source + ":" + .state] | join(" ")' <<< "$output")" = "user:built core:shadowed" ]
}
