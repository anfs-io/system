#!/usr/bin/env bash
# pmm library: small helpers shared by every pmm lib
# Sourced by ~/.local/bin/pmm; defines functions only. Runs on the bash floor (5.2).

# Messages and the log are anfs's (lib/anfs/log.sh)
die()  { anfs_die "$@"; }
warn() { anfs_warn "$@"; }
info() { anfs_info "$@"; }

tilde() { anfs_display "$1"; }

# sha256 of stdin, hex only
_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1
  fi
}

# Quote a string for a POSIX shell (the remote end of ssh re-parses the command line)
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# The host: darwin|linux, and arm64|amd64 (PMM_HOST_OS/PMM_HOST_ARCH override, for tests)
host_os() {
  if [[ -n "${PMM_HOST_OS:-}" ]]; then echo "$PMM_HOST_OS"; return; fi
  case "$(uname -s)" in Darwin) echo darwin ;; *) echo linux ;; esac
}
host_arch() {
  if [[ -n "${PMM_HOST_ARCH:-}" ]]; then echo "$PMM_HOST_ARCH"; return; fi
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

# A short directory for UNIX sockets (RUNTIME: they die with the machines): macOS caps socket
# paths at 104 bytes, and $PMM_STATE_HOME (or a test's tmp dir) can be longer than that. A
# machine's sockets are <name>.qmp and <name>.ga; a build's start with a dot, which no machine's
# name does. PMM_SOCK_DIR is somewhere else: the tests and the e2e set it, because the default is
# where a real pmm on the same host keeps the sockets of its running machines, and implode deletes
# the directory.
sock_dir() {
  local d
  d=$(sock_dir_path) || return 1
  mkdir -p "$d" && chmod 700 "$d"
  echo "$d"
}

# The default: on Linux $XDG_RUNTIME_DIR/pmm when that is a directory (per user, short, cleared at
# logout and boot, as a qemu's sockets should be); otherwise, and on macOS (no XDG_RUNTIME_DIR,
# and a $TMPDIR too long for a socket's path), /tmp/pmm-<uid>
sock_dir_default() {
  if [[ "$(host_os)" == linux && -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" ]]; then
    echo "${XDG_RUNTIME_DIR%/}/pmm"
  else
    echo "/tmp/pmm-$(id -u)"
  fi
}

# PMM_SOCK_DIR, else the default. Under bats (BATS_TEST_TMPDIR) a live directory is refused, set
# or defaulted, /tmp/pmm-<uid> and $XDG_RUNTIME_DIR/pmm alike: a suite that forgot to set
# PMM_SOCK_DIR would otherwise reach the sockets of the machines running on the host, which no
# grep of the tests can see.
sock_dir_path() {
  local d="${PMM_SOCK_DIR:-}" live
  d="${d:-$(sock_dir_default)}"
  if [[ -n "${BATS_TEST_TMPDIR:-}" ]]; then
    for live in "/tmp/pmm-$(id -u)" ${XDG_RUNTIME_DIR:+"${XDG_RUNTIME_DIR%/}/pmm"}; do
      [[ "${d%/}" != "$live" ]] && continue
      anfs_warn "refusing $live under a test: set PMM_SOCK_DIR to a directory of the test's"
      return 1
    done
  fi
  echo "$d"
}

# True if something accepts TCP connections on 127.0.0.1:<port>
port_open() {
  { exec 3<>"/dev/tcp/127.0.0.1/$1"; } 2>/dev/null || return 1
  exec 3<&- 3>&-
  return 0
}

# A free localhost port from PMM_SSH_PORT_BASE up, skipping ports recorded for builds in progress
# and for running machines (<dir>/*/port)
free_port() {
  local p="$PMM_SSH_PORT_BASE" taken=" " f d
  for d in "$PMM_STATE_HOME/build" "$PMM_STATE_HOME/run"; do
    for f in "$d"/*/port; do
      [[ -f "$f" ]] && taken+="$(cat "$f") "
    done
  done
  while [[ "$taken" == *" $p "* ]] || port_open "$p"; do
    p=$((p + 1))
    [[ $p -lt $((PMM_SSH_PORT_BASE + 1000)) ]] || die "no free port from $PMM_SSH_PORT_BASE"
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
confirm() { anfs_confirm "$@"; }
