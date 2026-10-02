#!/usr/bin/env bash
# pim library: building images; the build command. Sourced by ~/.local/bin/pim; functions only.
#
# A root image (no from:) is installed from its ISO: the kernel and initrd are read out of the ISO,
# the rendered answer file (and the image's public key) are appended to the initrd as one more
# cpio archive — the kernel unpacks every archive it is given — and the installer runs unattended
# until it powers the VM off. A child image (from:) starts as a qcow2 overlay on its parent's
# build instead. Both then boot from disk, run their scripts over ssh, run pim's finalize step,
# shut down, and are registered under a key hashing everything that went into them.

PIM_BUILD_VERSION=pim-build-v1

# The cache key of <id>'s build for <arch> (its parent must be built: its key is part of this one)
build_key() {
  local id="$1" arch="$2" dir parent pkey s f
  dir=$(img_dir "$id")
  parent=$(img_parent "$id" 2>/dev/null) || parent=""
  if [[ -n "$parent" ]]; then
    pkey=$(meta_get "$(img_name "$parent")" "$arch" .cache_key)
    [[ -n "$pkey" ]] || return 1
  fi
  {
    echo "$PIM_BUILD_VERSION"
    yq -o=json -I0 'del(.description) | sort_keys(..)' "$dir/image.yml"
    echo "arch $arch"
    if [[ -z "$parent" ]]; then
      echo "iso $(img_get "$id" ".iso.$arch.sha256" | tr '[:upper:]' '[:lower:]')"
      f=$(img_answer_file "$id") && echo "answer $(_sha256 < "$f")"
    else
      echo "parent $pkey"
    fi
    while IFS= read -r s; do echo "script $(basename "$s") $(_sha256 < "$s")"; done < <(img_scripts "$id")
    if [[ -d "$dir/files" ]]; then
      (cd "$dir/files" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do echo "file $f $(_sha256 < "$f")"; done)
    fi
    echo "finalize $(_sha256 < "$(pim_defaults)/finalize.sh")"
    if img_has_anfs "$id" && [[ "$(img_get "$id" .anfs.sources pushed)" == host ]]; then
      anfs_host_fingerprint
    fi
  } | _sha256 | cut -c1-16
}

# The kernel and initrd inside an installer ISO, and the kernel command line
# Usage: installer_paths <distro> <arch>   (sets INST_KERNEL, INST_INITRD)
installer_paths() {
  case "$1:$2" in
    debian:arm64) INST_KERNEL=install.a64/vmlinuz INST_INITRD=install.a64/initrd.gz ;;
    debian:amd64) INST_KERNEL=install.amd/vmlinuz INST_INITRD=install.amd/initrd.gz ;;
    fedora:*)     INST_KERNEL=images/pxeboot/vmlinuz INST_INITRD=images/pxeboot/initrd.img ;;
    *) die "no installer for distro '$1' on $2" ;;
  esac
}

# The ISO's volume label (the ISO 9660 primary descriptor, sector 16, offset 40), escaped for
# Anaconda's inst.stage2=hd:LABEL=
iso_label() {
  dd if="$1" bs=1 skip=$((16 * 2048 + 40)) count=32 2>/dev/null | sed 's/ *$//; s/ /\\x20/g'
}

installer_append() {
  local distro="$1" arch="$2" iso="$3" con
  con=$(qemu_console "$arch")
  case "$distro" in
    debian) echo "auto=true priority=critical preseed/file=/preseed.cfg console=$con,115200n8 ---" ;;
    fedora) echo "inst.ks=file:/ks.cfg inst.stage2=hd:LABEL=$(iso_label "$iso") inst.text console=$con" ;;
  esac
}

# Settings of an image's VM: its own value, else its root's, else the default
img_setting() {
  local id="$1" path="$2" def="$3" v
  v=$(img_get "$id" "$path")
  [[ -n "$v" ]] || v=$(img_get "$(img_root "$id")" "$path" "$def")
  echo "$v"
}

# --- the build ----------------------------------------------------------------------------------

BUILD_PID="" BUILD_W="" BUILD_PART=""

_build_cleanup() {
  [[ -n "$BUILD_PID" ]] && pid_alive "$BUILD_PID" && { kill "$BUILD_PID" 2>/dev/null; sleep 1; kill -9 "$BUILD_PID" 2>/dev/null; }
  [[ -n "$BUILD_PART" ]] && rm -f "$BUILD_PART"
  [[ -n "$BUILD_W" ]] && rm -rf "$BUILD_W"
  BUILD_PID="" BUILD_W="" BUILD_PART=""
}

cmd_build() {
  local force=false arch="" console=false verify=false arg
  PIM_VERBOSE=false
  local -a specs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--force) force=true ;;
      --arch) arch="${2:?--arch needs a value}"; shift ;;
      --console) console=true ;;
      --verify) verify=true ;;
      -v|--verbose) PIM_VERBOSE=true ;;
      -*) die "build: unknown option '$1'" ;;
      *) specs+=("$1") ;;
    esac
    shift
  done
  [[ ${#specs[@]} -gt 0 ]] || die "Usage: pim build [-f] [-v] [--arch A] [--console] [--verify] <image>..."
  local id a
  for arg in "${specs[@]}"; do
    id=$(canon_or_die "$arg")
    validate_quiet "$id" || die "$id does not validate (pim validate $id)"
    a=$(img_pick_arch "$id" "$arch")
    build_one "$id" "$a" "$force" "$console"
    $verify && verify_one "$id" "$a"
  done
  return 0
}

# Build <id> for <arch> unless its build is current; parents first
# Usage: build_one <id> <arch> <force> <console>
build_one() {
  local id="$1" arch="$2" force="$3" console="$4"
  local name parent key dir
  name=$(img_name "$id")
  parent=$(img_parent "$id") || parent=""
  [[ -z "$parent" ]] || build_one "$parent" "$arch" false "$console"

  key=$(build_key "$id" "$arch") || die "$id: its parent has no $arch build"
  dir=$(meta_dir "$name" "$arch")
  if ! $force && [[ "$(meta_get "$name" "$arch" .cache_key)" == "$key" && "$(meta_get "$name" "$arch" .id)" == "$id" ]] &&
     build_present "$name" "$arch" "$key" "$(img_backend "$id")"; then
    echo "$id ($arch) is up to date ($key)"
    return 0
  fi

  case "$(img_backend "$id")" in
    qemu) _build_qemu "$id" "$arch" "$key" "$parent" "$console" ;;
    tart) tart_build "$id" "$arch" "$key" ;;
  esac
}

_build_qemu() {
  local id="$1" arch="$2" key="$3" parent="$4" console="$5"
  local name user sshkey cpus mem size dir logs port sock vars start rc=0 distro iso s timeout
  name=$(img_name "$id")
  user=$(img_user "$id")
  sshkey=$(pim_key "$id")
  cpus=$(img_setting "$id" .cpus 2)
  mem=$(img_setting "$id" .memory 2048)
  size=$(img_setting "$id" .disk 20G)
  dir=$(meta_dir "$name" "$arch")
  logs="$PIM_STATE_HOME/logs/$name-$arch"
  mkdir -p "$dir" "$logs" "$PIM_STATE_HOME/build"

  BUILD_W="$PIM_STATE_HOME/build/$name-$arch"
  if [[ -f "$BUILD_W/pid" ]] && pid_alive "$(cat "$BUILD_W/pid")"; then
    BUILD_W=""
    die "$name ($arch) is already being built"
  fi
  rm -rf "$BUILD_W"
  mkdir -p "$BUILD_W"
  BUILD_PART="$dir/$key.qcow2.part"
  trap _build_cleanup EXIT
  trap 'exit 130' INT TERM
  port=$(free_port)
  echo "$port" > "$BUILD_W/port"
  sock="$(sock_dir)/build-$name-$arch.qmp"
  vars="$BUILD_W/efivars.fd"
  start=$(date +%s)

  echo "== build $id ($arch) -> $key"
  if [[ -z "$parent" ]]; then
    distro=$(img_distro "$id")
    iso=$(iso_fetch "$id" "$arch")
    installer_paths "$distro" "$arch"
    bsdtar -xf "$iso" -C "$BUILD_W" "$INST_KERNEL" "$INST_INITRD"
    chmod -R u+w "$BUILD_W"
    mkdir -p "$BUILD_W/inject/pim"
    tpl_load "$id" "$arch" "$sshkey.pub"
    case "$distro" in
      debian) render "$(img_answer_file "$id")" > "$BUILD_W/inject/preseed.cfg" ;;
      fedora) render "$(img_answer_file "$id")" > "$BUILD_W/inject/ks.cfg" ;;
    esac
    cp "$sshkey.pub" "$BUILD_W/inject/pim/authorized_keys"
    ( cd "$BUILD_W/inject" && find . -mindepth 1 |
        bsdtar --format newc --uid 0 --gid 0 --uname root --gname root -cf - -T - ) | gzip -9n > "$BUILD_W/inject.cpio.gz"
    cat "$BUILD_W/$INST_INITRD" "$BUILD_W/inject.cpio.gz" > "$BUILD_W/initrd"

    disk_create "$BUILD_PART" "$size"
    efivars_new "$arch" "$vars"
    qemu_argv "$arch" "$cpus" "$mem" "$BUILD_PART" "$vars" "$port"
    qemu_argv_installer "$iso" "$BUILD_W/$INST_KERNEL" "$BUILD_W/initrd" "$(installer_append "$distro" "$arch" "$iso")"
    qemu_argv_io "$console" "$logs/install.log" "$sock"
    timeout=$(img_get "$id" .timeouts.install "$PIM_INSTALL_TIMEOUT")
    echo "Installing $distro ($(qemu_accel "$arch")); log: $(tilde "$logs/install.log")"
    "${QEMU_ARGV[@]}" &
    BUILD_PID=$!
    echo "$BUILD_PID" > "$BUILD_W/pid"
    _wait_installer "$BUILD_PID" "$timeout" "$logs/install.log" "$console" || rc=$?
    BUILD_PID=""
    [[ $rc -eq 0 ]] || die "the installer failed (exit $rc); see $(tilde "$logs/install.log")"
    echo "Installed in $(( $(date +%s) - start ))s"
  else
    local pdisk
    pdisk=$(build_disk "$(img_name "$parent")" "$arch") || die "$parent has no $arch build"
    disk_overlay "$BUILD_PART" "$pdisk"
    [[ "$arch" == arm64 ]] && { cp "${pdisk%.qcow2}-efivars.fd" "$vars"; chmod u+w "$vars"; }
  fi

  # Boot the installed disk and provision it
  qemu_argv "$arch" "$cpus" "$mem" "$BUILD_PART" "$vars" "$port"
  qemu_argv_io false "$logs/boot.log" "$sock"
  "${QEMU_ARGV[@]}" &
  BUILD_PID=$!
  echo "$BUILD_PID" > "$BUILD_W/pid"
  echo "Booting; waiting for ssh"
  wait_ssh "$sshkey" "$port" "$user" "$(img_get "$id" .timeouts.ssh "$PIM_SSH_TIMEOUT")" "$BUILD_PID" ||
    die "no ssh; see $(tilde "$logs/boot.log")"

  if [[ -z "$parent" ]]; then
    local extra
    extra=$(img_list "$id" .user.authorized_keys)
    [[ -z "$extra" ]] || printf '%s\n' "$extra" | pim_ssh "$sshkey" "$port" "$user" 'cat >> ~/.ssh/authorized_keys'
  fi
  local files=""
  if [[ -d "$(img_dir "$id")/files" ]]; then
    files=/tmp/pim-files
    push_dir "$sshkey" "$port" "$user" "$(img_dir "$id")/files" "$files"
  fi
  : > "$logs/provision.log"
  while IFS= read -r s; do
    _provision "$logs/provision.log" "$(basename "$s")" run_script "$sshkey" "$port" "$user" "$s" \
      PIM_IMAGE="$name" PIM_ARCH="$arch" PIM_USER="$user" PIM_FILES="$files"
  done < <(img_scripts "$id")
  if declare -F build_anfs_step >/dev/null; then
    build_anfs_step "$id" "$sshkey" "$port" "$user" "$logs/provision.log"
  fi
  _provision "$logs/provision.log" finalize run_script "$sshkey" "$port" "$user" "$(pim_defaults)/finalize.sh" \
    PIM_IMAGE="$name" PIM_ARCH="$arch"

  echo "Shutting down"
  qemu_stop "$BUILD_PID" "$sock" ssh_poweroff "$sshkey" "$port" "$user"
  wait "$BUILD_PID" 2>/dev/null || true
  BUILD_PID=""

  mv "$BUILD_PART" "$dir/$key.qcow2"
  BUILD_PART=""
  [[ -f "$vars" ]] && mv "$vars" "$dir/$key-efivars.fd"
  meta_write_build "$id" "$arch" "$key" "$parent"
  _build_cleanup
  trap - EXIT INT TERM
  rm -f "$sock"
  echo "Built $id ($arch) in $(( $(date +%s) - start ))s: $(tilde "$dir/$key.qcow2")"
}

# Run one provisioning step (a command that runs a script in the guest): its output goes to <log>
# (and the terminal with -v); on failure the end of the log is shown and the build stops
# Usage: _provision <log> <label> <command...>
_provision() {
  local log="$1" label="$2" start rc=0
  shift 2
  start=$(date +%s)
  printf '== %s' "$label"
  echo "== $label" >> "$log"
  if [[ "${PIM_VERBOSE:-false}" == true ]]; then
    echo
    set +e; "$@" | tee -a "$log"; rc=${PIPESTATUS[0]}; set -e
  else
    "$@" >> "$log" 2>&1 || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    echo " FAILED (exit $rc)"
    tail -n 20 "$log" >&2
    die "$label failed; the whole output is in $(tilde "$log")"
  fi
  [[ "${PIM_VERBOSE:-false}" == true ]] || echo " ($(( $(date +%s) - start ))s)"
}

# Wait for the installer VM to power off; progress every minute. 124 on timeout.
_wait_installer() {
  local pid="$1" timeout="$2" log="$3" console="$4" start elapsed last=0 rc=0
  start=$(date +%s)
  while pid_alive "$pid"; do
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed >= timeout )); then
      warn "the installer is still running after ${timeout}s; stopping it"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    if [[ "$console" != true ]] && (( elapsed - last >= 60 )); then
      last=$elapsed
      # the installer draws with cursor movements: each escape sequence starts a new line
      (( elapsed > 0 )) && echo "  installing, $((elapsed / 60))m: $(tail -c 4000 "$log" 2>/dev/null | tr '\033\r' '\n\n' |
        sed -E 's/^\[[0-9;?]*[A-Za-z]//' | tr -cd '[:print:]\n' | sed 's/^ *//; s/ *$//' | grep -E '[A-Za-z]{3,}.{9,}' | tail -n1 | cut -c1-70)"
    fi
    sleep 5
  done
  wait "$pid" || rc=$?
  return $rc
}
