#!/usr/bin/env bash
# pim library: reaching a guest over ssh. Sourced by ~/.local/bin/pim; functions only.
#
# Every guest is reached on 127.0.0.1:<port> with the root image's key, as the image's user, who
# has passwordless sudo. Host keys are not recorded: a VM's key changes with every fresh build,
# and ~/.ssh is not pim's to write.

PIM_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
              -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes)

# Usage: pim_ssh <key> <port> <user> [ssh args / remote command...]
pim_ssh() {
  local key="$1" port="$2" user="$3"
  shift 3
  ssh "${PIM_SSH_OPTS[@]}" -i "$key" -p "$port" "$user@127.0.0.1" "$@"
}

# Wait until sshd answers with its banner (a TCP connect alone is not enough: user-mode
# networking accepts on the forwarded port before the guest listens), then until a login works.
# Fails after <timeout> seconds, or as soon as <pid> (the VM) exits.
# Usage: wait_ssh <key> <port> <user> <timeout> [pid]
wait_ssh() {
  local key="$1" port="$2" user="$3" timeout="$4" pid="${5:-}" start banner
  start=$(date +%s)
  while :; do
    [[ -z "$pid" ]] || pid_alive "$pid" || { warn "the VM exited while waiting for ssh"; return 1; }
    (( $(date +%s) - start < timeout )) || { warn "no ssh on port $port after ${timeout}s"; return 1; }
    banner=""
    if { exec 3<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null; then
      IFS= read -r -t 5 banner <&3 || true
      exec 3<&- 3>&-
    fi
    if [[ "$banner" == SSH-* ]] && pim_ssh "$key" "$port" "$user" true 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
}

# Run a local script as root in the guest, its output prefixed; env is NAME=value pairs
# Usage: run_script <key> <port> <user> <script> [NAME=value...]
run_script() {
  local key="$1" port="$2" user="$3" script="$4" env="" kv
  shift 4
  for kv in "$@"; do env+=" $(shq "$kv")"; done
  pim_ssh "$key" "$port" "$user" "sudo -n env$env bash -s" < "$script" 2>&1 | sed 's/^/  | /'
  return "${PIPESTATUS[0]}"
}

# Copy a local directory into the guest at <dest> (tar over ssh)
# Usage: push_dir <key> <port> <user> <dir> <dest>
push_dir() {
  local key="$1" port="$2" user="$3" dir="$4" dest="$5"
  tar -C "$dir" -cf - . | pim_ssh "$key" "$port" "$user" "mkdir -p $(shq "$dest") && tar -C $(shq "$dest") -xf -"
}

# The guest's own poweroff (for qemu_stop); the connection drops, so its status is ignored
ssh_poweroff() {
  pim_ssh "$1" "$2" "$3" 'sudo -n systemctl poweroff || sudo -n poweroff || sudo -n shutdown -h now' || true
}
