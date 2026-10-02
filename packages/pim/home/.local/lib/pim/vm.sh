#!/usr/bin/env bash
# pim library: running an image — up, shell, down, ps, snapshot, reset.
# Sourced by ~/.local/bin/pim; functions only.
#
# One VM per image name, like one container per pcm service. Its disk is a persistent qcow2
# overlay on the image's build ($PIM_DATA_HOME/vms/<name>/), so the build itself is never booted
# read-write and other images built on it stay valid. Runtime state is in
# $PIM_STATE_HOME/run/<name>/ (pid, port, arch, backend); the QMP socket in a short /tmp dir.

run_dir() { echo "$PIM_STATE_HOME/run/$1"; }
vm_dir()  { echo "$PIM_DATA_HOME/vms/$1"; }

# True when <name>'s VM is running (a dead record is pruned)
vm_running() {
  local r
  r=$(run_dir "$1")
  [[ -f "$r/pid" ]] || return 1
  if [[ "$(cat "$r/backend" 2>/dev/null)" == tart ]]; then
    tart_running "$1" && return 0
  elif pid_alive "$(cat "$r/pid")"; then
    return 0
  fi
  rm -rf "$r"
  return 1
}

vm_sock() { echo "$(sock_dir)/$1.qmp"; }

# Stop <name>'s VM: guest poweroff over ssh, then QMP, then kill
vm_stop() {
  local name="$1" r
  r=$(run_dir "$name")
  [[ -d "$r" ]] || return 0
  if [[ "$(cat "$r/backend" 2>/dev/null)" == tart ]]; then
    tart_stop "$name"
  else
    qemu_stop "$(cat "$r/pid")" "$(vm_sock "$name")" ssh_poweroff "$(cat "$r/key")" "$(cat "$r/port")" "$(cat "$r/user")"
  fi
  rm -rf "$r" "$(vm_sock "$name")"
}

cmd_up() {
  local fresh=false snapshot=false console=false arch="" spec=""
  local -a shares=() ports=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fresh) fresh=true ;;
      --snapshot) snapshot=true ;;
      --console) console=true ;;
      --arch) arch="${2:?--arch needs a value}"; shift ;;
      --share) shares+=("${2:?--share needs a path}"); shift ;;
      -p) ports+=("${2:?-p needs host:guest}"); shift ;;
      -*) die "up: unknown option '$1'" ;;
      *) spec="$1" ;;
    esac
    shift
  done
  [[ -n "$spec" ]] || die "Usage: pim up [--fresh|--snapshot] [--console] [--share P] [-p H:G] <image>"
  local id name
  id=$(canon_or_die "$spec")
  name=$(img_name "$id")
  if vm_running "$name"; then
    echo "$name is running (ssh 127.0.0.1:$(cat "$(run_dir "$name")/port"); pim shell $name)"
    return 0
  fi
  arch=$(img_pick_arch "$id" "$arch")
  validate_quiet "$id" || die "$id does not validate (pim validate $id)"
  build_one "$id" "$arch" false false
  if [[ "$(img_backend "$id")" == tart ]]; then
    tart_up "$id" "$fresh" ${shares[@]+"${shares[@]}"}
    return
  fi

  local disk key vdir user sshkey cpus mem port sock r p
  disk=$(build_disk "$name" "$arch") || die "$id has no $arch build"
  key=$(meta_get "$name" "$arch" .cache_key)
  vdir=$(vm_dir "$name")
  $fresh && rm -rf "$vdir"
  if [[ ! -f "$vdir/disk.qcow2" ]]; then
    mkdir -p "$vdir"
    disk_overlay "$vdir/disk.qcow2" "$disk"
    [[ "$arch" == arm64 ]] && { cp "${disk%.qcow2}-efivars.fd" "$vdir/efivars.fd"; chmod u+w "$vdir/efivars.fd"; }
    echo "$key" > "$vdir/base"
    echo "$arch" > "$vdir/arch"
  elif [[ "$(cat "$vdir/base" 2>/dev/null)" != "$key" ]]; then
    warn "$name's VM disk is from an older build of $name; pim up --fresh $name to start from the current one"
  fi
  arch=$(cat "$vdir/arch" 2>/dev/null || echo "$arch")

  user=$(img_user "$id")
  sshkey=$(pim_key "$id")
  cpus=$(img_setting "$id" .cpus 2)
  mem=$(img_setting "$id" .memory 2048)
  r=$(run_dir "$name")
  mkdir -p "$r"
  port=$(free_port)
  sock=$(vm_sock "$name")
  rm -f "$sock"
  while IFS= read -r p; do [[ -n "$p" ]] && ports+=("$p"); done < <(img_list "$id" .ports)

  local vars="$vdir/efivars.fd"
  if $snapshot; then
    cp "$vdir/efivars.fd" "$r/efivars.fd" 2>/dev/null && vars="$r/efivars.fd"
  fi
  qemu_argv "$arch" "$cpus" "$mem" "$vdir/disk.qcow2" "$vars" "$port" ${ports[@]+"${ports[@]}"}
  $snapshot && QEMU_ARGV+=(-snapshot)
  SHARE_TAGS=()
  local s
  for s in ${shares[@]+"${shares[@]}"}; do qemu_argv_share "$s"; done
  while IFS= read -r s; do [[ -n "$s" ]] && qemu_argv_share "${s/\$\{ANFS_SOURCES_HOME\}/$ANFS_SOURCES_HOME}"; done < <(img_list "$id" .shares)
  # The guest agent channel, for a later `pim` that asks the guest for its address
  QEMU_ARGV+=(-device virtio-serial-pci
              -chardev "socket,path=$(sock_dir)/$name.ga,server=on,wait=off,id=ga0"
              -device virtserialport,chardev=ga0,name=org.qemu.guest_agent.0)

  printf '%s\n' "$port" > "$r/port"
  printf '%s\n' "$arch" > "$r/arch"
  printf '%s\n' qemu > "$r/backend"
  printf '%s\n' "$user" > "$r/user"
  printf '%s\n' "$sshkey" > "$r/key"
  printf '%s\n' "${QEMU_ARGV[*]}" > "$r/argv"

  if $console; then
    qemu_argv_io true "" "$sock"
    echo "Starting $name on the console (power the guest off to return)"
    "${QEMU_ARGV[@]}" &
    echo $! > "$r/pid"
    wait "$(cat "$r/pid")" || true
    rm -rf "$r"
    return 0
  fi
  qemu_argv_io false "$r/serial.log" "$sock"
  "${QEMU_ARGV[@]}" -daemonize -pidfile "$r/pid" || { rm -rf "$r"; die "qemu failed to start"; }
  echo "Started $name ($arch, $(qemu_accel "$arch")); waiting for ssh"
  wait_ssh "$sshkey" "$port" "$user" "$(img_get "$id" .timeouts.ssh "$PIM_SSH_TIMEOUT")" "$(cat "$r/pid")" ||
    die "no ssh; see $(tilde "$r/serial.log")"
  local tag
  for tag in ${SHARE_TAGS[@]+"${SHARE_TAGS[@]}"}; do
    pim_ssh "$sshkey" "$port" "$user" "sudo -n mkdir -p /mnt/$tag && sudo -n mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 $tag /mnt/$tag" ||
      warn "could not mount share $tag at /mnt/$tag"
  done
  echo "$name is up: pim shell $name  (ssh -p $port $user@127.0.0.1 -i $(tilde "$sshkey"))"
}

cmd_shell() {
  [[ $# -gt 0 ]] || die "Usage: pim shell <image> [-u user] [-- cmd...]"
  local name r user cmd=""
  name=$(img_name "$(canon "$1" || echo "x/$1")")
  shift
  vm_running "$name" || die "$name is not running (pim up $name)"
  r=$(run_dir "$name")
  user=$(cat "$r/user")
  [[ "${1:-}" == "-u" ]] && { user="${2:?-u needs a user}"; shift 2; }
  [[ "${1:-}" == "--" ]] && shift
  if [[ "$(cat "$r/backend")" == tart ]]; then
    tart_shell "$name" "$user" "$@"
    return
  fi
  # Like ssh itself: the words are joined and the guest's shell parses them, so both
  # `pim shell x -- ls -l /tmp` and `pim shell x -- 'cd /tmp && ls'` work
  cmd="$*"
  if [[ -n "$cmd" ]]; then
    pim_ssh "$(cat "$r/key")" "$(cat "$r/port")" "$user" "$cmd"
  elif [[ -t 0 ]]; then
    pim_ssh "$(cat "$r/key")" "$(cat "$r/port")" "$user" -t
  else
    pim_ssh "$(cat "$r/key")" "$(cat "$r/port")" "$user" bash -s
  fi
}

cmd_down() {
  [[ $# -gt 0 ]] || die "Usage: pim down <image>..."
  local spec name
  for spec in "$@"; do
    name=$(img_name "$(canon "$spec" || echo "x/$spec")")
    if vm_running "$name"; then
      echo "Stopping $name"
      vm_stop "$name"
    else
      echo "$name is not running"
    fi
  done
}

cmd_ps() {
  local d name rows=""
  for d in "$PIM_STATE_HOME"/run/*/; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    vm_running "$name" || continue
    rows+="$name|$(cat "$d/arch" 2>/dev/null)|$(cat "$d/backend" 2>/dev/null)|$(cat "$d/pid")|127.0.0.1:$(cat "$d/port" 2>/dev/null)"$'\n'
  done
  printf '%-20s %-6s %-7s %-8s %s\n' NAME ARCH BACKEND PID SSH
  printf '%s' "$rows" | while IFS='|' read -r n a b p s; do
    [[ -n "$n" ]] && printf '%-20s %-6s %-7s %-8s %s\n' "$n" "$a" "$b" "$p" "$s"
  done
  return 0
}

snap_dir() { echo "$PIM_DATA_HOME/snapshots/$1"; }

# `pim snapshot <image> [name]`: save the VM's disk (shut down first, restarted after); no name
# lists the snapshots
cmd_snapshot() {
  [[ $# -gt 0 ]] || die "Usage: pim snapshot <image> [name]"
  local id name snap="${2:-}" was=false
  id=$(canon_or_die "$1")
  name=$(img_name "$id")
  if [[ -z "$snap" ]]; then
    if [[ "$(img_backend "$id")" == tart ]]; then tart_snapshots "$name"
    else ls "$(snap_dir "$name")" 2>/dev/null | sed -n 's/\.qcow2$//p'
    fi
    return 0
  fi
  [[ "$snap" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die "snapshot names are lowercase letters, digits, . _ -"
  if [[ "$(img_backend "$id")" == tart ]]; then tart_snapshot "$id" "$snap"; return; fi
  [[ -f "$(vm_dir "$name")/disk.qcow2" ]] || die "$name has no VM yet (pim up $name)"
  vm_running "$name" && { was=true; vm_stop "$name"; }
  mkdir -p "$(snap_dir "$name")"
  cp "$(vm_dir "$name")/disk.qcow2" "$(snap_dir "$name")/$snap.qcow2"
  [[ -f "$(vm_dir "$name")/efivars.fd" ]] && cp "$(vm_dir "$name")/efivars.fd" "$(snap_dir "$name")/$snap-efivars.fd"
  cp "$(vm_dir "$name")/base" "$(vm_dir "$name")/arch" "$(snap_dir "$name")/" 2>/dev/null || true
  echo "Saved snapshot $snap of $name (pim reset $name $snap)"
  $was && cmd_up "$id"
  return 0
}

# `pim reset [-y] <image> [snapshot]`: recreate the VM from a snapshot, or from its build
cmd_reset() {
  local yes=false spec="" snap="" arg was=false
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) yes=true ;;
      -*) die "reset: unknown option '$arg'" ;;
      *) [[ -z "$spec" ]] && spec="$arg" || snap="$arg" ;;
    esac
  done
  [[ -n "$spec" ]] || die "Usage: pim reset [-y] <image> [snapshot]"
  local id name vdir
  id=$(canon_or_die "$spec")
  name=$(img_name "$id")
  if [[ "$(img_backend "$id")" == tart ]]; then tart_reset "$id" "$snap"; return; fi
  [[ -z "$snap" || -f "$(snap_dir "$name")/$snap.qcow2" ]] || die "$name has no snapshot '$snap' (pim snapshot $name)"
  $yes || confirm "reset replaces the VM's disk" "Reset $name${snap:+ to $snap}?"
  vm_running "$name" && { was=true; vm_stop "$name"; }
  vdir=$(vm_dir "$name")
  rm -rf "$vdir"
  if [[ -n "$snap" ]]; then
    mkdir -p "$vdir"
    cp "$(snap_dir "$name")/$snap.qcow2" "$vdir/disk.qcow2"
    [[ -f "$(snap_dir "$name")/$snap-efivars.fd" ]] && cp "$(snap_dir "$name")/$snap-efivars.fd" "$vdir/efivars.fd"
    cp "$(snap_dir "$name")/base" "$(snap_dir "$name")/arch" "$vdir/" 2>/dev/null || true
  fi
  echo "Reset $name${snap:+ to $snap}"
  $was && cmd_up "$id"
  return 0
}
