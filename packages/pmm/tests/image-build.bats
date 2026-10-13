#!/usr/bin/env bats
# build.sh: the cache key, and the pipeline with qemu and ssh stubbed
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

@test "cache key: stable under key order and description, changes with scripts, iso, parent" {
  load_images
  k1=$(build_key local/d arm64)
  image "$PMM_IMAGES_HOME/d" "$(printf 'description: two\n%s' "$(deb_yml | awk 'NR>1' ; deb_yml | head -n1)")"
  [ "$(build_key local/d arm64)" = "$k1" ]
  [ "$(build_key local/d amd64)" != "$k1" ]
  mkdir -p "$PMM_IMAGES_HOME/d/scripts"; echo 'echo x' > "$PMM_IMAGES_HOME/d/scripts/50-x.sh"
  k2=$(build_key local/d arm64)
  [ "$k2" != "$k1" ]
  echo 'echo y' > "$PMM_IMAGES_HOME/d/scripts/50-x.sh"
  [ "$(build_key local/d arm64)" != "$k2" ]
  image "$PMM_IMAGES_HOME/c" "from: d"
  load_images
  run build_key local/c arm64
  [ "$status" -ne 0 ]   # the parent is not built yet
}

@test "build: install, boot, scripts in order, finalize, poweroff; registered; then a cache hit" {
  load_images
  mkdir -p "$PMM_IMAGES_HOME/d/scripts"; echo 'echo app' > "$PMM_IMAGES_HOME/d/scripts/50-app.sh"
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
  [ ! -d "$PMM_STATE_HOME/build/d-arm64" ]
  : > "$PMM_CALLS"
  run cmd_image_build d
  [[ "$output" == *"is up to date ($key)"* ]]
  ! grep -q qemu-system "$PMM_CALLS"
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
  mkdir -p "$PMM_IMAGES_HOME/d/scripts"; echo 'echo new' > "$PMM_IMAGES_HOME/d/scripts/50-new.sh"
  PMM_STUB_INSTALL_RC=3 run cmd_image_build d
  [ "$status" -ne 0 ]
  [[ "$output" == *"the installer failed (exit 3)"* ]]
  [ "$(meta_get d arm64 .cache_key)" = "$key" ]
  [ -f "$PMM_DATA_HOME/images/d/arm64/$key.qcow2" ]
  ! ls "$PMM_DATA_HOME"/images/d/arm64/*.part 2>/dev/null
}

@test "from: a child is an overlay on its parent's build, built after it" {
  image "$PMM_IMAGES_HOME/c" "from: d"
  mkdir -p "$PMM_IMAGES_HOME/c/scripts"; echo 'echo c' > "$PMM_IMAGES_HOME/c/scripts/10-c.sh"
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
