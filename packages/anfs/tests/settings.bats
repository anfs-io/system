#!/usr/bin/env bats
# Each core tool's shipped settings file documents every setting the tool reads, and nothing else:
# packages/<tool>/home/.config/<tool>/<tool>.env. A setting is a variable of the tool's prefix the
# code reads with a default (${X:-…}, ${X-…}, ${X:=…}, ${X=…}); not a setting: the paths that
# locate things (the XDG kinds' homes, *_DIR, and the path variables below), test hooks and
# internal switches, listed here with why. A tool that gains a setting gains its line; a tool
# without settings (psm) has no file.
# Run: bats packages/anfs/tests/settings.bats

setup() {
  PKGS="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# Not settings, per tool (space-separated)
not_settings() {
  case "$1" in
    # the bash floor, debug/trace/log/output switches, the manifest's, resolve's and move's per-caller
    # knobs, the API's per-request marker and its test hook, table tests; the job switch
    # (environment only, lib/anfs/work.sh); an event's actor, role and space (each process's own,
    # lib/anfs/events.sh), a dispatched run's spool (anfsd sets ANFS_EVENTS_SPOOL per run) and its clock for tests; the platform overrides of service.sh and
    # pins.sh (tests); NATS's settings, which bus.sh reads and core/nats's nats.env documents
    anfs) echo "ANFS_SERVICE_OS ANFS_PIN_PLATFORM ANFS_NATS_PORT ANFS_NATS_HTTP_PORT ANFS_NATS_MAX_FILE ANFS_NATS_MAX_MEM ANFS_BUS_LAYERS
                ANFS_ACTOR ANFS_AS ANFS_SPACE ANFS_EVENTS_SPOOL ANFS_EVENTS_TEST_MS ANFS_WORK ANFS_WORK_HOME ANFS_WORK_SAID ANFS_BASH_CANDIDATES ANFS_BASH_REEXEC ANFS_COLOR ANFS_DEBUG ANFS_JSON ANFS_LOG
                ANFS_MF_KINDS ANFS_MF_SRC_BASE ANFS_MF_YQ_EXTRA ANFS_MOVE_MANIFEST ANFS_NAME_NEST ANFS_RESOLVE_FIRST
                ANFS_RESOLVE_MARKER ANFS_RPC ANFS_RPC_OS ANFS_TABLE ANFS_TEST_TERMINAL ANFS_TRACE
                ANFS_ISO_HOME ANFS_SOURCES_HOME" ;;
    # the package being installed, debug, the run's skip list
    ppm) echo "PPM_CURRENT_PACKAGE PPM_DEBUG PPM_SKIP_FILE" ;;
    # computed at run time (the podman socket, the dependency a hook runs for), a test hook, paths
    pcm) echo "PCM_PODMAN_SOCKET PCM_SERVICE PCM_TOOLKIT_OS PCM_CONTAINERS_HOME PCM_VOLUMES_HOME" ;;
    # host facts and the files pmm-network sets up (tests point them at a temp dir), tart's limit,
    # the ssh host a machine is reached on (per machine), the ssh config file, firmware probed,
    # local definition paths
    pmm) echo "PMM_BRIDGE_CONF PMM_BRIDGE_HELPER PMM_FW_CODE PMM_FW_VARS PMM_HOST_ARCH PMM_HOST_OS
               PMM_KVM_DEV PMM_MACOS_LIMIT PMM_NET_BACKEND PMM_NET_CHECK PMM_SSH_CONFIG PMM_SSH_HOST
               PMM_SYS_NET PMM_VIRSH PMM_MACHINES_HOME PMM_IMAGES_HOME PMM_NETWORKS_HOME" ;;
    *) echo "" ;;
  esac
}

# The code of a tool: its command and its libraries
code_files() {
  find "$PKGS/$1/home/.local/bin" "$PKGS/$1/home/.local/lib/$1" -type f 2>/dev/null
}

# The settings the code reads, by the rule above
read_settings() {
  local t="$1" up skip
  up=$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')
  skip=" $(not_settings "$t" | tr -s ' \n' '  ') "
  code_files "$t" | xargs grep -hoE "\\\$\\{${up}_[A-Z0-9_]+:?[-=]" | sed -E 's/^\$\{//; s/:?[-=]$//' |
    grep -vE '_(CONFIG|DATA|STATE|CACHE)_HOME$|_DIR$' | sort -u | while read -r n; do
      [[ "$skip" == *" $n "* ]] || echo "$n"
    done
}

# The names a shipped file has a line for, active or commented
file_settings() {
  sed -nE 's/^#?([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$1" | sort -u
}

check_tool() {
  local t="$1" env="$PKGS/$1/home/.config/$1/$1.env" n missing="" extra=""
  [ -f "$env" ] || { echo "no $env"; return 1; }
  for n in $(read_settings "$t"); do
    file_settings "$env" | grep -qx "$n" || missing="$missing $n"
  done
  for n in $(file_settings "$env"); do
    [[ "$n" == HOMEBREW_* && "$t" == anfs ]] && continue   # brew's, read by brew
    code_files "$t" | xargs grep -qw -- "$n" || extra="$extra $n"
  done
  [ -z "$missing" ] || echo "$t reads, $t.env does not document:$missing"
  [ -z "$extra" ] || echo "$t.env names what $t does not read:$extra"
  [ -z "$missing$extra" ]
}

@test "anfs.env documents every ANFS_ setting, and Homebrew's" {
  run check_tool anfs
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx 'HOMEBREW_NO_AUTO_UPDATE=1' "$PKGS/anfs/home/.config/anfs/anfs.env"
  grep -qx 'HOMEBREW_NO_ENV_HINTS=1' "$PKGS/anfs/home/.config/anfs/anfs.env"
}

@test "ppm.env documents every PPM_ setting" {
  run check_tool ppm
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "pcm.env documents every PCM_ setting" {
  run check_tool pcm
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "pmm.env documents every PMM_ setting" {
  run check_tool pmm
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "wsm.env documents every WSM_ setting" {
  run check_tool wsm
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "psm reads no setting of its own and ships no file" {
  [ ! -e "$PKGS/psm/home/.config/psm/psm.env" ]
  run read_settings psm
  [ -z "$output" ]
}

@test "the rule finds what it is for" {
  # a new setting with a default and no line is caught
  mkdir -p "$BATS_TEST_TMPDIR/p/demo/home/.local/bin" "$BATS_TEST_TMPDIR/p/demo/home/.config/demo"
  printf ': "${DEMO_A:=1}"\nb="${DEMO_B:-x}"\nc="${DEMO_DATA_HOME:-y}"\nd="${DEMO_X_DIR:-z}"\n' \
    > "$BATS_TEST_TMPDIR/p/demo/home/.local/bin/demo"
  printf '#DEMO_A=1\n#DEMO_GONE=1\n' > "$BATS_TEST_TMPDIR/p/demo/home/.config/demo/demo.env"
  PKGS="$BATS_TEST_TMPDIR/p"
  run check_tool demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not document: DEMO_B"* ]]
  [[ "$output" == *"does not read: DEMO_GONE"* ]]
}

@test "every shipped setting is named for its tool, and nothing ships anfs.conf" {
  local t f n bad=""
  for t in ppm pcm pmm wsm; do
    f="$PKGS/$t/home/.config/$t/$t.env"
    for n in $(file_settings "$f"); do
      [[ "$n" == "$(printf '%s' "$t" | tr '[:lower:]' '[:upper:]')_"* ]] || bad="$bad $t:$n"
    done
  done
  for n in $(file_settings "$PKGS/anfs/home/.config/anfs/anfs.env"); do
    [[ "$n" == ANFS_* || "$n" == HOMEBREW_* ]] || bad="$bad anfs:$n"
  done
  [ -z "$bad" ] || { echo "$bad"; return 1; }
  run find "$PKGS" -name anfs.conf -o -name anfs.local.conf
  [ -z "$output" ]
}
