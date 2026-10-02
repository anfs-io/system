#!/usr/bin/env bash
# pim library: small helpers shared by every pim lib
# Sourced by ~/.local/bin/pim; defines functions only. bash 3.2-safe.

die()  { echo "pim: $*" >&2; exit 1; }
warn() { echo "pim: $*" >&2; }
info() { echo "$*"; }

tilde() { echo "${1/#$HOME/~}"; }

# sha256 of stdin, hex only
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1
  fi
}

# Quote a string for a POSIX shell (the remote end of ssh re-parses the command line)
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# The host: darwin|linux, and arm64|amd64 (PIM_HOST_OS/PIM_HOST_ARCH override, for tests)
host_os() {
  if [[ -n "${PIM_HOST_OS:-}" ]]; then echo "$PIM_HOST_OS"; return; fi
  case "$(uname -s)" in Darwin) echo darwin ;; *) echo linux ;; esac
}
host_arch() {
  if [[ -n "${PIM_HOST_ARCH:-}" ]]; then echo "$PIM_HOST_ARCH"; return; fi
  arch_norm "$(uname -m)"
}

# arm64|aarch64 -> arm64, amd64|x86_64 -> amd64; anything else is returned unchanged
arch_norm() {
  case "$1" in
    arm64|aarch64) echo arm64 ;;
    amd64|x86_64) echo amd64 ;;
    *) echo "$1" ;;
  esac
}

# The qemu name of an arch: arm64 -> aarch64, amd64 -> x86_64
arch_qemu() {
  case "$1" in arm64) echo aarch64 ;; amd64) echo x86_64 ;; *) return 1 ;; esac
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# A short directory for UNIX sockets: macOS caps socket paths at 104 bytes, and $PIM_STATE_HOME
# (or a test's tmp dir) can be longer than that
sock_dir() {
  local d="/tmp/pim-$(id -u)"
  mkdir -p "$d" && chmod 700 "$d"
  echo "$d"
}

# True if something accepts TCP connections on 127.0.0.1:<port>
port_open() {
  { exec 3<>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null || return 1
  exec 3<&- 3>&-
  return 0
}

# A free localhost port from PIM_SSH_PORT_BASE up, skipping ports recorded for running VMs
free_port() {
  local p="$PIM_SSH_PORT_BASE" taken=" " f
  for f in "$PIM_STATE_HOME"/run/*/port "$PIM_STATE_HOME"/build/*/port; do
    [[ -f "$f" ]] && taken+="$(cat "$f") "
  done
  while [[ "$taken" == *" $p "* ]] || port_open "$p"; do
    p=$((p + 1))
    [[ $p -lt $((PIM_SSH_PORT_BASE + 1000)) ]] || die "no free port from $PIM_SSH_PORT_BASE"
  done
  echo "$p"
}

# True if <pid> is a running process
pid_alive() {
  [[ -n "${1:-}" ]] && kill -0 "$1" 2>/dev/null
}

# Human-readable size of a file
file_size() {
  [[ -e "$1" ]] || { echo "-"; return; }
  du -h "$1" 2>/dev/null | cut -f1 | tr -d ' '
}

# Ask unless yes; dies without a terminal
confirm() {
  local answer
  [[ -t 0 ]] || die "$1; pass -y to confirm without a terminal"
  read -r -p "$2 [y/N] " answer
  [[ "$answer" == [yY]* ]] || die "nothing done"
}
