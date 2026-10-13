#!/usr/bin/env bash
# pmm library: a machine's life — create, up, shell, down, ps, show, remove.
# Sourced by ~/.local/bin/pmm; functions only.
#
# A qemu machine's disk is a qcow2 overlay on the build it was created from
# ($PMM_DATA_HOME/machines/<name>/), so the build is never booted read-write and any number of
# machines share it. That keeps the build: `pmm image prune` and `image remove` read every
# machine's record for the build it is on (holders_of, registry.sh). A tart machine is a clone of
# the build in tart's own store, pmm-<name>. Runtime state is in $PMM_STATE_HOME/run/<name>/
# (pid, port, arch, backend, user, key); the QMP socket is in a short /tmp dir.

mach_sock() { echo "$(sock_dir)/$1.qmp"; }

# True when <name> is running (a dead record is pruned)
mach_running() {
  local r
  r=$(run_dir "$1")
  [[ -f "$r/pid" ]] || return 1
  pid_alive "$(cat "$r/pid")" && return 0
  rm -rf "$r"
  return 1
}

# running | stopped | defined (not made yet)
mach_state() {
  if mach_running "$1"; then echo running
  elif mach_exists "$1"; then echo stopped
  else echo defined
  fi
}

# Where a running machine's ssh is: 127.0.0.1:<port> (qemu, no network), or its address (qemu on
# a network, tart)
mach_address() {
  local r
  r=$(run_dir "$1")
  mach_running "$1" || return 0
  if [[ "$(cat "$r/backend" 2>/dev/null)" == tart ]]; then cat "$r/ip" 2>/dev/null || true
  elif [[ -f "$r/host" ]]; then cat "$r/host"
  else echo "127.0.0.1:$(cat "$r/port" 2>/dev/null)"
  fi
}

# Stop <name>: guest poweroff over ssh, then QMP, then kill (qemu); from inside, then tart (tart)
mach_stop() {
  local name="$1" r ip
  r=$(run_dir "$name")
  [[ -d "$r" ]] || return 0
  if [[ "$(cat "$r/backend" 2>/dev/null)" == tart ]]; then
    BOOT_USER=$(state_get "$name" .boot.user) BOOT_PW=$(state_get "$name" .boot.password)
    ip=$(tart ip "$(tart_vm "$name")" --wait 10 2>/dev/null || cat "$r/ip")
    _tart_shutdown "$(tart_vm "$name")" "$(cat "$r/pid")" "$(cat "$r/key")" "$ip"
  else
    PMM_SSH_HOST=$(mach_ssh_host "$name") qemu_stop "$(cat "$r/pid")" "$(mach_sock "$name")" ssh_poweroff "$(cat "$r/key")" "$(cat "$r/port")" "$(cat "$r/user")"
  fi
  rm -rf "$r" "$(mach_sock "$name")" "$(sock_dir)/$name.ga"
  ssh_config_write
}

# --- create -------------------------------------------------------------------------------------

# Apple allows PMM_MACOS_LIMIT (2) macOS guests running at once, whoever started them. Refuse
# before anything is cloned or booted, naming what is up.
macos_limit() {
  local name="$1" vm
  local -a up=()
  while IFS= read -r vm; do
    [[ -n "$vm" && "$vm" != "$(tart_vm "$name")" ]] || continue
    [[ "$(tart get "$vm" --format json 2>/dev/null | yq -p json -r '.OS // "darwin"' 2>/dev/null || echo darwin)" == darwin ]] || continue
    up+=("${vm#pmm-}")
  done < <(tart list --format json 2>/dev/null | yq -p json -r '.[] | select(.Source == "local" and .Running == true) | .Name' 2>/dev/null)
  (( ${#up[@]} < PMM_MACOS_LIMIT )) ||
    die "macOS runs $PMM_MACOS_LIMIT macOS guests at once and ${#up[@]} are up (${up[*]}); pmm down one first"
}

# What the image asks of its machines (image.yml machine.min), against this definition's settings
# Usage: min_problems <id>   (prints one line per setting that is below the minimum)
min_problems() {
  local id="$1" image k want have
  image=$(mach_get "$id" .image)
  for k in cpus memory disk; do
    want=$(image_machine_get "$image" ".min.$k")
    have=$(mach_setting "$id" "$k")
    [[ -n "$want" && -n "$have" ]] || continue
    if [[ "$k" == cpus ]]; then (( have >= want )) || echo "cpus $have is below $image's minimum of $want"
    else (( $(size_mb "$have") >= $(size_mb "$want") )) || echo "$k $have is below $image's minimum of $want"
    fi
  done
}

# Make <name> from its definition <id>: its disk on the image's current build, and its record.
# The image is built first unless its build is current (image build is a no-op then).
machine_create() {
  local name="$1" id="$2" image arch disk cpus mem d old old_mac
  image=$(mach_get "$id" .image)
  arch=$(arch_norm "$(mach_get "$id" .arch "$(host_arch)")")
  d=$(mdir "$name")
  disk=$(mach_setting "$id" disk) cpus=$(mach_setting "$id" cpus) mem=$(mach_setting "$id" memory)
  # a machine made again (reset) keeps its MACs; what it reserved is given back and reserved anew
  old=$(mach_ifaces "$name") old_mac=$(state_get "$name" .mac)
  if [[ -z "$image" ]]; then
    # a blank machine: an empty disk for what its media install (media.sh)
    ifaces_release "$name"
    rm -rf "$d"
    mkdir -p "$d"
    disk_create "$d/disk.qcow2" "${disk:-$PMM_BLANK_DISK}"
    efivars_new "$arch" "$d/efivars.fd"
    state_write "$(state_file "$name")" "" "$arch" qemu "" "" "$(mach_get "$id" .user)" ""
    ifaces_record "$name" "$id" "$old" "$old_mac"
    return 0
  fi
  qemu_accel_warn "$arch"
  # not in an || list: errexit must stay on inside the build
  image_ensure_built "$image" "$arch" >&2
  [[ $? -eq 0 ]] || die "$image did not build (pmm image build $image)"
  image_build "$image" "$arch" || die "$image has no $arch build (pmm image build $image)"
  ifaces_release "$name"
  if [[ "$B_BACKEND" == tart ]]; then
    anfs_require tart "ppm install core/pmm"
    tart delete "$(tart_vm "$name")" >/dev/null 2>&1 || true
    tart clone "$B_DISK" "$(tart_vm "$name")" || die "tart clone $B_DISK failed"
    [[ -z "$cpus$mem$disk" ]] ||
      tart set "$(tart_vm "$name")" ${cpus:+--cpu "$cpus"} ${mem:+--memory "$(size_mb "$mem")"} ${disk:+--disk-size "${disk%G}"}
  else
    rm -rf "$d"
    mkdir -p "$d"
    disk_overlay "$d/disk.qcow2" "$B_DISK"
    [[ "$arch" == arm64 ]] && { cp "${B_DISK%.qcow2}-efivars.fd" "$d/efivars.fd"; chmod u+w "$d/efivars.fd"; }
    [[ -z "$disk" ]] || qemu-img resize -q "$d/disk.qcow2" "$disk" || die "could not grow $name's disk to $disk"
  fi
  state_write "$(state_file "$name")" "$B_SOURCE/$B_NAME" "$arch" "$B_BACKEND" "$B_KEY" "$B_DISK" "$B_USER" "$B_SSHKEY" "$B_BOOT_USER" "$B_BOOT_PW"
  [[ "$B_BACKEND" == tart ]] || ifaces_record "$name" "$id" "$old" "$old_mac"
}

# `pmm create <machine> [--image I ...]`: with --image and a name nothing defines, write the
# definition ($PMM_MACHINES_HOME) first; then make the machine, without starting it
cmd_create() {
  local name="$1" image="${CLI_OPT[image]:-}" id made=false k
  local -a args=()
  mach_name_ok "$name" || die "machine names are $PMM_NAME_RULE"
  if id=$(canon "$name"); then
    for k in image media profile cpus memory disk share publish user arch; do
      [[ -z "${CLI_OPT[$k]:-}" ]] || anfs_fail 73 "$name is already defined ($id); its settings are in $(tilde "$(mach_yml "$id")")"
    done
  else
    [[ -n "$image${CLI_OPT[media]:-}" ]] || cli_usage_err "$name is not defined: --image is required (or --media, for a blank machine)"
    args=(image "$image" profile "${CLI_OPT[profile]:-}" cpus "${CLI_OPT[cpus]:-}" memory "${CLI_OPT[memory]:-}"
          disk "${CLI_OPT[disk]:-}" user "${CLI_OPT[user]:-}" arch "${CLI_OPT[arch]:-}")
    while IFS= read -r k; do [[ -z "$k" ]] || args+=("shares[]" "$k"); done <<< "${CLI_OPT[share]:-}"
    while IFS= read -r k; do [[ -z "$k" ]] || args+=("ports[]" "$k"); done <<< "${CLI_OPT[publish]:-}"
    while IFS= read -r k; do [[ -z "$k" ]] || args+=("media[]" "$k"); done <<< "${CLI_OPT[media]:-}"
    def_write "$name" "${args[@]}"
    made=true
    load_machines
    id=$(canon "$name")
  fi
  mach_exists "$name" && anfs_fail 73 "$name already exists (pmm show $name)"
  if ! validate_quiet "$id"; then
    $made && rm -rf "${PMM_MACHINES_HOME:?}/$name"
    die "$id does not validate"
  fi
  machine_create "$name" "$id"
  if [[ -z "$(state_get "$name" .image)" ]]; then
    echo "Created $name, blank ($(mach_setting "$id" disk | grep . || echo "$PMM_BLANK_DISK") disk); pmm up --display $name"
  else
    echo "Created $name from $(state_get "$name" .image) ($(state_get "$name" .key)); pmm up $name"
  fi
  anfs_result name "$name" image "$(state_get "$name" .image)" key "$(state_get "$name" .key)"
}

# --- up -----------------------------------------------------------------------------------------

# `pmm up [--image I] [--console] [--share P]... [-p H:G]... [machine...]`
cmd_up() {
  local image="${CLI_OPT[image]:-}" console=${CLI_OPT[console]:-false} spec
  local -a specs=("$@") shares=() ports=()
  # what _up_qemu reads for this run: the media to boot first, and whether to show a screen
  UP_MEDIA=() UP_DISPLAY=${CLI_OPT[display]:-false}
  [[ -z "${CLI_OPT[media]:-}" ]] || mapfile -t UP_MEDIA <<< "${CLI_OPT[media]}"
  ! $UP_DISPLAY || ! $console || cli_usage_err "--console or --display, not both"
  [[ -z "${CLI_OPT[share]:-}" ]] || mapfile -t shares <<< "${CLI_OPT[share]}"
  [[ -z "${CLI_OPT[publish]:-}" ]] || mapfile -t ports <<< "${CLI_OPT[publish]}"
  if [[ -n "$image" ]]; then
    [[ ${#specs[@]} -le 1 ]] || cli_usage_err "--image takes one machine"
    [[ ${#specs[@]} -eq 1 ]] || specs=("${image#*/}")
    if ! canon "${specs[0]}" >/dev/null && ! mach_exists "${specs[0]}"; then
      mach_name_ok "${specs[0]}" || die "machine names are $PMM_NAME_RULE"
      def_write "${specs[0]}" image "$image"
      load_machines
    fi
  fi
  [[ ${#specs[@]} -gt 0 ]] || cli_usage_err "a machine, or --image"
  ! $console || [[ ${#specs[@]} -eq 1 ]] || cli_usage_err "--console takes one machine"
  [[ ${#UP_MEDIA[@]} -eq 0 ]] || [[ ${#specs[@]} -eq 1 ]] || cli_usage_err "--media takes one machine"
  ! $UP_DISPLAY || [[ ${#specs[@]} -eq 1 ]] || cli_usage_err "--display takes one machine"

  for spec in "${specs[@]}"; do
    mach_find "$spec"
    if mach_running "$M_NAME"; then
      echo "$M_NAME is running ($(mach_address "$M_NAME"); pmm shell $M_NAME)"
      continue
    fi
    [[ -n "$M_ID" ]] || die "$M_NAME's definition is gone: there is nothing to read its settings from"
    validate_quiet "$M_ID" || die "$M_ID does not validate (pmm validate $M_NAME)"
    # the limit is checked before a machine that is not made yet is cloned
    if ! mach_exists "$M_NAME"; then
      [[ "$(_def_backend "$M_ID")" != tart ]] || macos_limit "$M_NAME"
      machine_create "$M_NAME" "$M_ID"
    fi
    case "$(state_get "$M_NAME" .backend)" in
      tart) [[ ${#UP_MEDIA[@]} -eq 0 ]] && ! $UP_DISPLAY || die "$M_NAME is a tart machine: it takes no media and has tart's own window"
            macos_limit "$M_NAME"; _up_tart "$M_NAME" "$M_ID" ${shares[@]+"${shares[@]}"} ;;
      *) _up_qemu "$M_NAME" "$M_ID" "$console" "${#shares[@]}" ${shares[@]+"${shares[@]}"} ${ports[@]+"${ports[@]}"} ;;
    esac
  done
}

# The backend of the image a definition names, when it has a build; nothing otherwise
_def_backend() {
  image_build "$(mach_get "$1" .image)" "$(arch_norm "$(mach_get "$1" .arch "$(host_arch)")")" 2>/dev/null || return 0
  echo "$B_BACKEND"
}

# Usage: _up_qemu <name> <id> <console> <n shares> [share...] [port...]
_up_qemu() {
  local name="$1" id="$2" console="$3" n="$4"
  shift 4
  local -a shares=("${@:1:$n}") ports=("${@:$((n + 1))}")
  local d arch user sshkey cpus mem port sock r p s tag vars host m kind="" blank=false vnc
  local -a first=() later=()
  d=$(mdir "$name")
  [[ -f "$d/disk.qcow2" ]] || die "$name has no disk (pmm reset $name)"
  arch=$(state_get "$name" .arch)
  qemu_accel_warn "$arch"
  sshkey=$(state_get "$name" .sshkey)
  user=$(mach_get "$id" .user "$(state_get "$name" .user)")
  cpus=$(mach_setting "$id" cpus); cpus="${cpus:-2}"
  mem=$(mach_setting "$id" memory); mem=$(size_mb "${mem:-2048}")
  while IFS= read -r p; do [[ -n "$p" ]] && ports+=("$p"); done < <(mach_list "$id" .ports)
  while IFS= read -r s; do [[ -n "$s" ]] && shares+=("$s"); done < <(mach_list "$id" .shares)

  # On a network with an address pmm knows, ssh goes there and there is no user-mode nic
  ifaces_argv "$name"
  host="$IFACE_SSH"
  r=$(run_dir "$name")
  mkdir -p "$r"
  sock=$(mach_sock "$name")
  rm -f "$sock"
  vars="$d/efivars.fd"
  if [[ -n "$host" ]]; then
    [[ ${#ports[@]} -eq 0 ]] || warn "$name is reached at $host: its ports are not forwarded"
    port=22
    QEMU_MAC="" qemu_argv "$arch" "$cpus" "$mem" "$d/disk.qcow2" "$vars" ""
    printf '%s\n' "$host" > "$r/host"
  else
    port=$(free_port)
    QEMU_MAC=$(state_get "$name" .mac) qemu_argv "$arch" "$cpus" "$mem" "$d/disk.qcow2" "$vars" "$port" ${ports[@]+"${ports[@]}"}
  fi
  QEMU_NICS=()
  SHARE_TAGS=()
  [[ -n "$(state_get "$name" .image)" ]] || blank=true
  for m in ${UP_MEDIA[@]+"${UP_MEDIA[@]}"}; do first+=("$(media_file "$m")"); done
  while IFS= read -r m; do [[ -z "$m" ]] || later+=("$(media_file "$m")"); done < <(mach_list "$id" .media)
  qemu_argv_media "$d/disk.qcow2" "${#first[@]}" "${first[@]}" "${later[@]}"
  if ${UP_DISPLAY:-false}; then
    kind=$(display_kind)
    qemu_argv_display "$arch" "$kind"
  fi
  for s in ${shares[@]+"${shares[@]}"}; do qemu_argv_share "$(share_expand "$s")"; done
  # The guest agent channel, for a later pmm that asks the guest for its addresses
  QEMU_ARGV+=(-device virtio-serial-pci
              -chardev "socket,path=$(sock_dir)/$name.ga,server=on,wait=off,id=ga0"
              -device virtserialport,chardev=ga0,name=org.qemu.guest_agent.0)

  printf '%s\n' "$port" > "$r/port"
  printf '%s\n' "$arch" > "$r/arch"
  printf '%s\n' qemu > "$r/backend"
  printf '%s\n' "$user" > "$r/user"
  printf '%s\n' "$sshkey" > "$r/key"
  printf '%s\n' "${QEMU_ARGV[*]}" > "$r/argv"

  if [[ "$console" == true ]]; then
    qemu_argv_io true "" "$sock"
    echo "Starting $name on the console (power the guest off to return)"
    "${QEMU_ARGV[@]}" &
    echo $! > "$r/pid"
    wait "$(cat "$r/pid")" || true
    rm -rf "$r"
    return 0
  fi
  qemu_argv_io false "$r/serial.log" "$sock"
  if [[ "$kind" == window ]]; then
    # a window is qemu's own, in the foreground: closing it, or the guest powering off, ends the run
    echo "Starting $name in a window (close it, or power the guest off, to return)"
    "${QEMU_ARGV[@]}" &
    echo $! > "$r/pid"
    wait "$(cat "$r/pid")" || true
    rm -rf "$r"
    return 0
  fi
  "${QEMU_ARGV[@]}" -daemonize -pidfile "$r/pid" || { rm -rf "$r"; die "qemu failed to start"; }
  if [[ "$kind" == vnc ]]; then
    vnc=$(vnc_port "$sock")
    echo "$name's screen: VNC at 127.0.0.1:${vnc:-5900} (from another host: ssh -L ${vnc:-5900}:127.0.0.1:${vnc:-5900} <this host>)"
  fi
  # Nothing to wait for where pmm has no login (a blank machine) or the disk is not what boots
  if $blank || [[ ${#first[@]} -gt 0 ]]; then
    ssh_config_write
    echo "Started $name ($arch, $(qemu_accel "$arch")), booting $([[ ${#first[@]} -gt 0 ]] && basename "${first[0]}" || echo "its disk, then its media"); serial: $(tilde "$r/serial.log"); pmm down $name"
    return 0
  fi
  echo "Started $name ($arch, $(qemu_accel "$arch")); waiting for ssh${host:+ at $host}"
  PMM_SSH_HOST="${host:-127.0.0.1}" wait_ssh "$sshkey" "$port" "$user" "$PMM_SSH_TIMEOUT" "$(cat "$r/pid")" ||
    die "no ssh; see $(tilde "$r/serial.log")"
  for tag in ${SHARE_TAGS[@]+"${SHARE_TAGS[@]}"}; do
    PMM_SSH_HOST="${host:-127.0.0.1}" pmm_ssh "$sshkey" "$port" "$user" "sudo -n mkdir -p /mnt/$tag && sudo -n mount -t 9p -o trans=virtio,version=9p2000.L,msize=512000 $tag /mnt/$tag" ||
      warn "could not mount share $tag at /mnt/$tag"
  done
  ssh_config_write
  if [[ -n "$host" ]]; then echo "$name is up: pmm shell $name  (ssh $user@$host -i $(tilde "$sshkey"))"
  else echo "$name is up: pmm shell $name  (ssh -p $port $user@127.0.0.1 -i $(tilde "$sshkey"))"
  fi
}

# Usage: _up_tart <name> <id> [share...]   (shares given for this run win over the definition's)
_up_tart() {
  local name="$1" id="$2" vm r pid ip sshkey user s
  shift 2
  local -a shares=("$@")
  vm=$(tart_vm "$name")
  tart_exists "$vm" || die "$name has no tart VM (pmm reset $name)"
  sshkey=$(state_get "$name" .sshkey)
  user=$(mach_get "$id" .user "$(state_get "$name" .user)")
  while IFS= read -r s; do [[ -n "$s" ]] && shares+=("$(share_expand "$s")"); done < <(mach_list "$id" .shares)
  _tart_dirs ${shares[@]+"${shares[@]}"}
  r=$(run_dir "$name")
  mkdir -p "$r"
  pid=$(_tart_run "$vm" "$r/tart.log" ${TART_DIRS[@]+"${TART_DIRS[@]}"})
  printf '%s\n' "$pid" > "$r/pid"
  printf '%s\n' tart > "$r/backend"
  printf '%s\n' arm64 > "$r/arch"
  printf '%s\n' "$user" > "$r/user"
  printf '%s\n' "$sshkey" > "$r/key"
  ip=$(tart ip "$vm" --wait 180 2>/dev/null) || die "$vm got no address; see $(tilde "$r/tart.log")"
  printf '%s\n' "$ip" > "$r/ip"
  printf '%s\n' 22 > "$r/port"
  _tart_wait "$PMM_SSH_TIMEOUT" _tart_ssh "$sshkey" "$ip" "$user" true || die "no ssh to $user@$ip"
  ssh_config_write
  echo "$name is up: pmm shell $name  (ssh $user@$ip -i $(tilde "$sshkey"))"
}

# --- shell, down, ps ----------------------------------------------------------------------------

cmd_shell() {
  local name r user cmd="" ip
  mach_find "$1"
  name="$M_NAME"
  shift
  mach_running "$name" || die "$name is not running (pmm up $name)"
  r=$(run_dir "$name")
  [[ -n "$(cat "$r/key" 2>/dev/null)" ]] || die "$name has no image, so pmm has no login for it: use its screen (pmm up --display) or its own ssh"
  user=$(cat "$r/user")
  [[ -z "${CLI_OPT[user]:-}" ]] || user="${CLI_OPT[user]}"
  [[ "${1:-}" == "--" ]] && shift
  # Like ssh itself: the words are joined and the guest's shell parses them, so both
  # `pmm shell x -- ls -l /tmp` and `pmm shell x -- 'cd /tmp && ls'` work
  cmd="$*"
  if [[ "$(cat "$r/backend")" == tart ]]; then
    ip=$(tart ip "$(tart_vm "$name")" --wait 30 2>/dev/null) || die "$name has no address"
    if [[ -n "$cmd" ]]; then _tart_ssh "$(cat "$r/key")" "$ip" "$user" "$cmd"
    elif [[ -t 0 ]]; then _tart_ssh "$(cat "$r/key")" "$ip" "$user" -t
    else _tart_ssh "$(cat "$r/key")" "$ip" "$user" bash -s
    fi
    return
  fi
  local -x PMM_SSH_HOST
  PMM_SSH_HOST=$(mach_ssh_host "$name")
  if [[ -n "$cmd" ]]; then
    pmm_ssh "$(cat "$r/key")" "$(cat "$r/port")" "$user" "$cmd"
  elif [[ -t 0 ]]; then
    pmm_ssh "$(cat "$r/key")" "$(cat "$r/port")" "$user" -t
  else
    pmm_ssh "$(cat "$r/key")" "$(cat "$r/port")" "$user" bash -s
  fi
}

cmd_down() {
  local spec
  for spec in "$@"; do
    mach_find "$spec"
    if mach_running "$M_NAME"; then
      echo "Stopping $M_NAME"
      mach_stop "$M_NAME"
    else
      echo "$M_NAME is not running"
    fi
  done
}

cmd_ps() {
  local d name
  for d in "$PMM_STATE_HOME"/run/*/; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    mach_running "$name" || continue
    anfs_row "$name" "$(cat "$d/arch" 2>/dev/null)" "$(cat "$d/backend" 2>/dev/null)" "$(cat "$d/pid")" "$(mach_address "$name")"
  done | anfs_table "NAME ARCH BACKEND PID SSH" "name arch backend pid ssh"
}

# --- show, remove -------------------------------------------------------------------------------

cmd_show() {
  local name id v key image snaps backend
  mach_find "$1"
  name="$M_NAME" id="$M_ID"
  echo "$name"
  if [[ -n "$id" ]]; then
    echo "  definition  $(tilde "$(mach_def_dir "$id")") ($(mach_src "$id"))"
    v=$(mach_profile "$id"); [[ -z "$v" ]] || echo "  profile     $v$(profile_file "$v" >/dev/null || echo " (not found)")"
    # With nothing set a qemu machine gets 2 cpus and 2048 MB, a tart one what its build has
    backend=$(state_get "$name" .backend); [[ -n "$backend" ]] || backend=$(_def_backend "$id")
    v=$(mach_setting "$id" cpus); echo "  cpus        ${v:-$([[ "$backend" == tart ]] && echo "the build's" || echo 2)}"
    v=$(mach_setting "$id" memory); echo "  memory      ${v:-$([[ "$backend" == tart ]] && echo "the build's" || echo 2048)}"
    v=$(mach_setting "$id" disk); [[ -z "$v" ]] || echo "  disk size   $v"
    v=$(mach_list "$id" .shares | paste -sd' ' -); [[ -z "$v" ]] || echo "  shares      $v"
    v=$(mach_list "$id" .ports | paste -sd' ' -); [[ -z "$v" ]] || echo "  ports       $v"
    v=$(mach_list "$id" .media | paste -sd' ' -); [[ -z "$v" ]] || echo "  media       $v"
    mach_exists "$name" || { v=$(yq -r '[.interfaces[]?.network] | join(" ")' "$(mach_yml "$id")" 2>/dev/null) || v=""
                             [[ -z "$v" ]] || echo "  networks    $v"; }
  else
    echo "  definition  gone"
  fi
  image=$(mach_image "$name" "$id")
  echo "  image       ${image:-none (a blank machine: what its media install)}"
  echo "  state       $(mach_state "$name")$(mach_running "$name" && echo " (ssh $(mach_address "$name"))")"
  mach_exists "$name" || return 0
  key=$(state_get "$name" .key)
  v=""
  if [[ -n "$image" ]] && image_build "${image#*/}" "$(state_get "$name" .arch)" && [[ "$B_KEY" != "$key" ]]; then
    v="; $image has a newer build (pmm reset $name)"
  fi
  if [[ -n "$image" ]]; then echo "  build       $key ($(state_get "$name" .arch), $(state_get "$name" .backend))$v"
  else echo "  arch        $(state_get "$name" .arch) ($(state_get "$name" .backend))"
  fi
  if [[ "$(state_get "$name" .backend)" == tart ]]; then
    echo "  vm          $(tart_vm "$name") (tart)"
  else
    echo "  disk        $(tilde "$(mdir "$name")/disk.qcow2") ($(file_size "$(mdir "$name")/disk.qcow2"))"
  fi
  while IFS= read -r v; do [[ -z "$v" ]] || echo "  interface   $v"; done < <(ifaces_show "$name")
  echo "  created     $(state_get "$name" .created_at)"
  snaps=$(mach_snapshots "$name" | paste -sd' ' -)
  [[ -z "$snaps" ]] || echo "  snapshots   $snaps"
}

# Delete what pmm made for <name>: its disk or tart VM, its snapshots, its record. With them goes
# what kept its image's build (holders_of)
mach_delete() {
  local name="$1" vm
  mach_running "$name" && mach_stop "$name"
  if [[ "$(state_get "$name" .backend)" == tart ]]; then
    if command -v tart >/dev/null 2>&1; then
      _tart_names | grep -E "^$(tart_vm "$name")(-snap-.*)?\$" | while read -r vm; do tart delete "$vm" >/dev/null 2>&1 || true; done || true
    fi
  else
    ifaces_release "$name"
  fi
  rm -rf "$(mdir "$name")" "$(snap_dir "$name")" "$(run_dir "$name")"
}

# `pmm rm [-y] <machine>...`: stop and delete machines and their snapshots. A local definition
# is the machine's own and goes with it; a source's stays, and `pmm up` makes the machine again.
cmd_remove() {
  local spec
  local -a names=() ids=()
  for spec in "$@"; do
    mach_find "$spec"
    names+=("$M_NAME") ids+=("$M_ID")
  done
  confirm "rm deletes machines' disks and snapshots" "Delete ${names[*]}?"
  local i name id
  for i in "${!names[@]}"; do
    name="${names[$i]}" id="${ids[$i]}"
    mach_exists "$name" && mach_delete "$name"
    if [[ "$id" == "$PMM_LOCAL_SOURCE/"* ]]; then
      rm -rf "${PMM_MACHINES_HOME:?}/$name"
      echo "Removed $name"
    elif [[ -n "$id" ]]; then
      echo "Removed $name (still defined by $(mach_src "$id"))"
    else
      echo "Removed $name"
    fi
  done
}
