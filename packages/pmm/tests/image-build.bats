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
