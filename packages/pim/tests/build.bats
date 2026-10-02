#!/usr/bin/env bats
# build.sh: the cache key, and the pipeline with qemu and ssh stubbed
load helper

setup() {
  setup_pim
  mkdir -p "$T/fw"; : > "$T/fw/code.fd"; : > "$T/fw/vars.fd"
  export PIM_FW_CODE="$T/fw/code.fd" PIM_FW_VARS="$T/fw/vars.fd"
  image "$PIM_IMAGES_HOME/d" "$(deb_yml 'description: one')"
  # the ISO, already cached and verified
  mkdir -p "$PIM_CACHE_HOME/isos"
  echo iso > "$PIM_CACHE_HOME/isos/a.iso"
  sleep 1; echo "$SHA" > "$PIM_CACHE_HOME/isos/a.iso.sha256"
  wait_ssh() { return 0; }
}

@test "cache key: stable under key order and description, changes with scripts, iso, parent" {
  load_sources
  k1=$(build_key local/d arm64)
  image "$PIM_IMAGES_HOME/d" "$(printf 'description: two\n%s' "$(deb_yml | awk 'NR>1' ; deb_yml | head -n1)")"
  [ "$(build_key local/d arm64)" = "$k1" ]
  [ "$(build_key local/d amd64)" != "$k1" ]
  mkdir -p "$PIM_IMAGES_HOME/d/scripts"; echo 'echo x' > "$PIM_IMAGES_HOME/d/scripts/50-x.sh"
  k2=$(build_key local/d arm64)
  [ "$k2" != "$k1" ]
  echo 'echo y' > "$PIM_IMAGES_HOME/d/scripts/50-x.sh"
  [ "$(build_key local/d arm64)" != "$k2" ]
  image "$PIM_IMAGES_HOME/c" "from: d"
  load_sources
  run build_key local/c arm64
  [ "$status" -ne 0 ]   # the parent is not built yet
}

@test "build: install, boot, scripts in order, finalize, poweroff; registered; then a cache hit" {
  load_sources
  mkdir -p "$PIM_IMAGES_HOME/d/scripts"; echo 'echo app' > "$PIM_IMAGES_HOME/d/scripts/50-app.sh"
  run cmd_build d
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"== 10-base.sh"*"== 50-app.sh"*"== finalize"* ]]
  grep -q -- '-kernel .*install.a64/vmlinuz -initrd .*/initrd -append auto=true priority=critical preseed/file=/preseed.cfg console=ttyAMA0' "$PIM_CALLS"
  grep -q 'ssh .*poweroff' "$PIM_CALLS"
  key=$(meta_get d arm64 .cache_key)
  [ -f "$PIM_DATA_HOME/images/d/arm64/$key.qcow2" ]
  [ -f "$PIM_DATA_HOME/images/d/arm64/$key-efivars.fd" ]
  [ "$(meta_get d arm64 .id)" = local/d ]
  [ ! -d "$PIM_STATE_HOME/build/d-arm64" ]
  : > "$PIM_CALLS"
  run cmd_build d
  [[ "$output" == *"is up to date ($key)"* ]]
  ! grep -q qemu-system "$PIM_CALLS"
}

@test "build: the answer file and the key are injected into the initrd" {
  load_sources
  real=$(type -ap bsdtar | grep -v /stubs/ | head -n1)
  [ -n "$real" ] || skip "no bsdtar"
  # keep the workspace to inspect it
  _build_cleanup() { :; }
  cmd_build d >/dev/null
  w="$PIM_STATE_HOME/build/d-arm64"
  gzip -dc "$w/inject.cpio.gz" | "$real" -tf - | sort > "$T/members"
  grep -qx './preseed.cfg' "$T/members"
  grep -qx './pim/authorized_keys' "$T/members"
  grep -q 'passwd/username string pim' "$w/inject/preseed.cfg"
}

@test "build: a failing installer keeps the previous build and leaves no partial disk" {
  load_sources
  cmd_build d >/dev/null
  key=$(meta_get d arm64 .cache_key)
  mkdir -p "$PIM_IMAGES_HOME/d/scripts"; echo 'echo new' > "$PIM_IMAGES_HOME/d/scripts/50-new.sh"
  PIM_STUB_INSTALL_RC=3 run cmd_build d
  [ "$status" -ne 0 ]
  [[ "$output" == *"the installer failed (exit 3)"* ]]
  [ "$(meta_get d arm64 .cache_key)" = "$key" ]
  [ -f "$PIM_DATA_HOME/images/d/arm64/$key.qcow2" ]
  ! ls "$PIM_DATA_HOME"/images/d/arm64/*.part 2>/dev/null
}

@test "from: a child is an overlay on its parent's build, built after it" {
  image "$PIM_IMAGES_HOME/c" "from: d"
  mkdir -p "$PIM_IMAGES_HOME/c/scripts"; echo 'echo c' > "$PIM_IMAGES_HOME/c/scripts/10-c.sh"
  load_sources
  run cmd_build c
  [ "$status" -eq 0 ]
  pkey=$(meta_get d arm64 .cache_key)
  grep -q "qemu-img create -q -f qcow2 -b $PIM_DATA_HOME/images/d/arm64/$pkey.qcow2 -F qcow2" "$PIM_CALLS"
  [ "$(meta_get c arm64 .parent.id)" = local/d ]
  [ -n "$(dependents_of_disk "$PIM_DATA_HOME/images/d/arm64/$pkey.qcow2")" ]
  run cmd_rm -y d
  [ "$status" -ne 0 ]
  [[ "$output" == *"c/arm64 is built on d"* ]]
}
