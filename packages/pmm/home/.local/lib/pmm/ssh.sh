#!/usr/bin/env bash
# pmm library: reaching a guest over ssh. Sourced by ~/.local/bin/pmm; functions only.
#
# Every guest is reached on 127.0.0.1:<port> with the root image's key, as the image's user, who
# has passwordless sudo. Host keys are not recorded: a VM's key changes with every fresh build,
# and known_hosts is not pmm's to write. PMM_SSH_HOST, when set, is the address instead of
# 127.0.0.1 (a machine on a network).

PMM_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
              -o ConnectTimeout=10 -o BatchMode=yes -o IdentitiesOnly=yes)

# Usage: pmm_ssh <key> <port> <user> [ssh args / remote command...]
pmm_ssh() {
  local key="$1" port="$2" user="$3"
  shift 3
  ssh "${PMM_SSH_OPTS[@]}" -i "$key" -p "$port" "$user@${PMM_SSH_HOST:-127.0.0.1}" "$@"
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
    if { exec 3<>"/dev/tcp/${PMM_SSH_HOST:-127.0.0.1}/$port"; } 2>/dev/null; then
      IFS= read -r -t 5 banner <&3 || true
      exec 3<&- 3>&-
    fi
    if [[ "$banner" == SSH-* ]] && pmm_ssh "$key" "$port" "$user" true 2>/dev/null; then
      return 0
    fi
    sleep 3
  done
}

# How a provisioner reaches a guest over ssh (provision.sh): two scripts in <dir>, and GUEST_ENV,
# the ANFS_IMAGE_GUEST_* it is told them by. exec runs its arguments as root in the guest, each
# quoted for the shell at the other end of ssh, which parses the command line again; push copies
# a file, or a directory's contents, to a guest path through it. <sudo> is how the user becomes
# root there, and the rest is the ssh command line up to the remote command.
# Usage: guest_ssh <dir> <sudo> <host> <port> <user> <key> <ssh argv...>
guest_ssh() {
  local dir="$1" sudo="$2" host="$3" port="$4" user="$5" key="$6"
  shift 6
  [[ "$dir" != *[[:space:]]* ]] || die "$dir has a space in it: a provisioner is given the path as a command line"
  mkdir -p "$dir"
  {
    printf '#!%s\n# pmm: run the arguments as root in the guest being built\n' "$BASH"
    printf 'SSH=(%s)\nSUDO=%q\n' "$(printf '%q ' "$@")" "$sudo"
    cat <<'EXEC'
q=""
for a in "$@"; do q+=" '${a//\'/\'\\\'\'}'"; done
exec "${SSH[@]}" "$SUDO --$q"
EXEC
  } > "$dir/exec"
  {
    printf '#!%s\n# pmm: copy a local path to a path in the guest being built, as root\n' "$BASH"
    cat <<'PUSH'
x="$(dirname "$0")/exec"
[[ $# -eq 2 && -e "$1" ]] || { echo "usage: push <local path> <guest path>" >&2; exit 64; }
if [[ -d "$1" ]]; then
  tar -C "$1" -cf - . | "$x" sh -c 'mkdir -p "$1" && tar -C "$1" --no-same-owner -xf -' sh "$2"
else
  "$x" sh -c 'mkdir -p "$(dirname "$1")" && cat > "$1"' sh "$2" < "$1"
fi
PUSH
  } > "$dir/push"
  chmod 700 "$dir/exec" "$dir/push"
  GUEST_DIR="$dir"
  GUEST_ENV=("ANFS_IMAGE_GUEST_EXEC=$dir/exec" "ANFS_IMAGE_GUEST_PUSH=$dir/push" ANFS_IMAGE_GUEST_TRANSPORT=ssh
             "ANFS_IMAGE_GUEST_HOST=$host" "ANFS_IMAGE_GUEST_PORT=$port" "ANFS_IMAGE_GUEST_USER=$user"
             "ANFS_IMAGE_GUEST_KEY=$key" "ANFS_IMAGE_SSH_PUBKEY=$(cat "$key.pub" 2>/dev/null || true)")
}

# A qemu guest: the image's user on the forwarded port, who has passwordless sudo
# Usage: guest_ssh_qemu <dir> <key> <port> <user>
guest_ssh_qemu() {
  local host="${PMM_SSH_HOST:-127.0.0.1}"
  guest_ssh "$1" "sudo -n" "$host" "$3" "$4" "$2" ssh "${PMM_SSH_OPTS[@]}" -i "$2" -p "$3" "$4@$host"
}

# The guest's own poweroff (for qemu_stop); the connection drops, so its status is ignored
ssh_poweroff() {
  pmm_ssh "$1" "$2" "$3" 'sudo -n systemctl poweroff || sudo -n poweroff || sudo -n shutdown -h now' || true
}
