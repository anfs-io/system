#!/usr/bin/env bats
# pmm and the XDG rule (core AGENTS.md, "Where files go"): its sockets are RUNTIME (pmm/ under
# XDG_RUNTIME_DIR on Linux, /tmp/pmm-<uid> on macOS, PMM_SOCK_DIR over both), and the Host
# entries of running machines are STATE ($PMM_STATE_HOME/ssh_config), included from the
# ~/.ssh/config.d/05-pmm.conf core/pmm ships: nothing pmm runs writes into ~/.ssh.
#
# pmm's own suites (packages/pmm/tests) are off until further notice (ROADMAP, 2026-10-19). This
# file is not one of them: it sources the few pmm libraries it needs, boots nothing, and runs with
# anfs's suites. Linux is stubbed (PMM_HOST_OS); no socket is made.
# Run: bats packages/anfs/tests/pmm-runtime.bats

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

setup() {
  T="$BATS_TEST_TMPDIR"
  PMM_PKG="$(cd "$BATS_TEST_DIRNAME/../../pmm" && pwd)"
  local anfs="$BATS_TEST_DIRNAME/../home/.local/lib/anfs" lib="$PMM_PKG/home/.local/lib/pmm" f
  export HOME="$T/home" ANFS_LOG=off
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  unset PMM_CONFIG_HOME PMM_DATA_HOME PMM_STATE_HOME PMM_CACHE_HOME PMM_SOCK_DIR PMM_SSH_CONFIG XDG_RUNTIME_DIR
  mkdir -p "$HOME"
  # shellcheck source=/dev/null
  source "$anfs/paths.sh"; source "$anfs/log.sh"
  CLI_TOOL=pmm
  anfs_tool_paths pmm
  for f in core settings machine interfaces; do
    # shellcheck source=/dev/null
    source "$lib/$f.sh"
  done
  # the macOS default, the live directory isolation.bats keeps tests from naming: only compared
  # with what sock_dir_default and sock_dir_path print, never made
  printf -v UID_LIVE '/tmp/pmm-%s' "$(id -u)"
  RUN="$T/run"
}

@test "PMM_SOCK_DIR wins over either default" {
  export PMM_SOCK_DIR="$T/socks" PMM_HOST_OS=linux XDG_RUNTIME_DIR="$RUN"
  mkdir -p "$RUN"
  [ "$(sock_dir_path)" = "$T/socks" ]
  PMM_HOST_OS=darwin
  [ "$(sock_dir_path)" = "$T/socks" ]
}

@test "Linux with XDG_RUNTIME_DIR a directory: the default is pmm/ in it" {
  export PMM_HOST_OS=linux XDG_RUNTIME_DIR="$RUN"
  mkdir -p "$RUN"
  [ "$(sock_dir_default)" = "$RUN/pmm" ]
  XDG_RUNTIME_DIR="$RUN/"
  [ "$(sock_dir_default)" = "$RUN/pmm" ]
}

@test "Linux without XDG_RUNTIME_DIR, or one that is not a directory, and macOS: /tmp/pmm-<uid>" {
  export PMM_HOST_OS=linux
  [ "$(sock_dir_default)" = "$UID_LIVE" ]
  export XDG_RUNTIME_DIR="$RUN"            # not made
  [ "$(sock_dir_default)" = "$UID_LIVE" ]
  mkdir -p "$RUN"
  PMM_HOST_OS=darwin                        # macOS ignores it even when set
  [ "$(sock_dir_default)" = "$UID_LIVE" ]
}

@test "under bats both live defaults are refused, set or defaulted" {
  export PMM_HOST_OS=linux XDG_RUNTIME_DIR="$RUN"
  mkdir -p "$RUN"
  run sock_dir_path                         # defaulted: $RUN/pmm
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing $RUN/pmm under a test"* ]]
  PMM_SOCK_DIR="$RUN/pmm/" run sock_dir_path
  [ "$status" -eq 1 ]
  PMM_SOCK_DIR="$UID_LIVE" run sock_dir_path
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing $UID_LIVE under a test"* ]]
  PMM_HOST_OS=darwin
  unset XDG_RUNTIME_DIR
  run sock_dir_path                         # defaulted: /tmp/pmm-<uid>
  [ "$status" -eq 1 ]
  [ ! -e "$RUN/pmm" ]
}

@test "bin/pmm's ssh config is \$PMM_STATE_HOME/ssh_config; core/pmm ships the one Include" {
  grep -qx ': "${PMM_SSH_CONFIG=$PMM_STATE_HOME/ssh_config}"' "$PMM_PKG/home/.local/bin/pmm"
  f="$PMM_PKG/home/.ssh/config.d/05-pmm.conf"
  [ "$(grep -v '^#' "$f" | grep .)" = "Include ~/.local/state/pmm/ssh_config" ]
}

@test "ssh_config_write writes \$PMM_STATE_HOME/ssh_config and nothing under ~/.ssh" {
  PMM_SSH_CONFIG="$PMM_STATE_HOME/ssh_config"
  local r="$PMM_STATE_HOME/run/web1"
  mkdir -p "$r"
  echo $$ > "$r/pid"; echo 2299 > "$r/port"; echo pmm > "$r/user"; echo "$T/key" > "$r/key"
  ssh_config_write
  grep -qx "Host web1" "$PMM_SSH_CONFIG"
  grep -qx "  Port 2299" "$PMM_SSH_CONFIG"
  [ ! -e "$HOME/.ssh" ]
  # a stopped machine leaves the file with no entry
  echo 999999 > "$r/pid"
  ssh_config_write
  ! grep -q "^Host" "$PMM_SSH_CONFIG"
}
