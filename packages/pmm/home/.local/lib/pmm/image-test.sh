#!/usr/bin/env bash
# pmm library: testing a build — boot a throwaway copy, run the image's test.sh. Sourced by
# ~/.local/bin/pmm; functions only.

cmd_image_test() {
  local arch="${CLI_OPT[arch]:-}" id
  id=$(img_canon_or_die "$1")
  test_one "$id" "$(img_pick_arch "$id" "$arch")"
}

# Boot <id>'s <arch> build with -snapshot (nothing it does is kept), wait for ssh, run its
# test.sh as root; records the build as tested when it passes
test_one() {
  local id="$1" arch="$2" name disk key script user sshkey port sock w pid rc=0
  name=$(img_name "$id")
  [[ "$(img_backend "$id")" == tart ]] && { tart_test "$id"; return; }
  disk=$(build_disk "$name" "$arch") || die "$id has no $arch build (pmm image build $id)"
  key=$(meta_get "$name" "$arch" .cache_key)
  script=$(img_test_script "$id") || true
  [[ -n "$script" ]] || { echo "$id has no test.sh; nothing to test"; return 0; }
  user=$(img_user "$id")
  sshkey=$(img_key "$id")
  w="$PMM_STATE_HOME/build/test-$name-$arch"
  rm -rf "$w"; mkdir -p "$w"
  port=$(free_port)
  echo "$port" > "$w/port"
  sock="$(sock_dir)/.test-$name-$arch.qmp"
  [[ "$arch" == arm64 ]] && { cp "${disk%.qcow2}-efivars.fd" "$w/efivars.fd"; chmod u+w "$w/efivars.fd"; }
  qemu_argv "$arch" "$(img_setting "$id" .cpus 2)" "$(img_setting "$id" .memory 2048)" "$disk" "$w/efivars.fd" "$port"
  QEMU_ARGV+=(-snapshot)
  qemu_argv_io false "$w/serial.log" "$sock"
  echo "== test $id ($arch, $key) with $(tilde "$script")"
  "${QEMU_ARGV[@]}" &
  pid=$!
  if wait_ssh "$sshkey" "$port" "$user" "$(img_get "$id" .timeouts.ssh "$PMM_IMAGE_SSH_TIMEOUT")" "$pid"; then
    run_script "$sshkey" "$port" "$user" "$script" PIM_IMAGE="$name" PIM_ARCH="$arch" PIM_USER="$user" || rc=$?
  else
    rc=1
  fi
  qmp "$sock" quit >/dev/null || true
  wait_exit "$pid" 10 || kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$w" "$sock"
  if [[ $rc -eq 0 ]]; then
    meta_set "$name" "$arch" '.tested_key = strenv(v)' "$key"
    echo "Tested $id ($arch)"
  else
    echo "The test of $id ($arch) FAILED"
  fi
  return $rc
}
