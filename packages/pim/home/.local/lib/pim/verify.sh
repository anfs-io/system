#!/usr/bin/env bash
# pim library: verifying a build — boot a throwaway copy, run verify.sh. Sourced by
# ~/.local/bin/pim; functions only.

cmd_verify() {
  local arch="" spec=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch) arch="${2:?--arch needs a value}"; shift ;;
      -*) die "verify: unknown option '$1'" ;;
      *) spec="$1" ;;
    esac
    shift
  done
  [[ -n "$spec" ]] || die "Usage: pim verify [--arch A] <image>"
  local id
  id=$(canon_or_die "$spec")
  verify_one "$id" "$(img_pick_arch "$id" "$arch")"
}

# Boot <id>'s <arch> build with -snapshot (nothing it does is kept), wait for ssh, run its
# verify.sh as root; records the build as verified when it passes
verify_one() {
  local id="$1" arch="$2" name disk key script user sshkey port sock w pid rc=0
  name=$(img_name "$id")
  [[ "$(img_backend "$id")" == tart ]] && { tart_verify "$id"; return; }
  disk=$(build_disk "$name" "$arch") || die "$id has no $arch build (pim build $id)"
  key=$(meta_get "$name" "$arch" .cache_key)
  script=$(img_verify_script "$id") || true
  [[ -n "$script" ]] || { echo "$id has no verify.sh; nothing to verify"; return 0; }
  user=$(img_user "$id")
  sshkey=$(pim_key "$id")
  w="$PIM_STATE_HOME/build/verify-$name-$arch"
  rm -rf "$w"; mkdir -p "$w"
  port=$(free_port)
  echo "$port" > "$w/port"
  sock="$(sock_dir)/verify-$name-$arch.qmp"
  [[ "$arch" == arm64 ]] && { cp "${disk%.qcow2}-efivars.fd" "$w/efivars.fd"; chmod u+w "$w/efivars.fd"; }
  qemu_argv "$arch" "$(img_setting "$id" .cpus 2)" "$(img_setting "$id" .memory 2048)" "$disk" "$w/efivars.fd" "$port"
  QEMU_ARGV+=(-snapshot)
  qemu_argv_io false "$w/serial.log" "$sock"
  echo "== verify $id ($arch, $key) with $(tilde "$script")"
  "${QEMU_ARGV[@]}" &
  pid=$!
  if wait_ssh "$sshkey" "$port" "$user" "$(img_get "$id" .timeouts.ssh "$PIM_SSH_TIMEOUT")" "$pid"; then
    run_script "$sshkey" "$port" "$user" "$script" PIM_IMAGE="$name" PIM_ARCH="$arch" PIM_USER="$user" || rc=$?
  else
    rc=1
  fi
  qmp "$sock" quit >/dev/null || true
  wait_exit "$pid" 10 || kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$w" "$sock"
  if [[ $rc -eq 0 ]]; then
    meta_set "$name" "$arch" '.verified_key = strenv(v)' "$key"
    echo "Verified $id ($arch)"
  else
    echo "Verification of $id ($arch) FAILED"
  fi
  return $rc
}
