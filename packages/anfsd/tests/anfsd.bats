#!/usr/bin/env bats
# core/anfsd's hooks: the pinned anfsd release fetched into DATA and linked, or ANFSD_BIN (one built
# from source) run instead; the service written (after NATS, KillMode=process on Linux) and
# loaded; post_remove unloads and deletes it and the link, keeps STATE. A temp HOME; curl serves
# a fixture release whose sum this file pins (a copy of the package with its own pins.yml);
# launchctl and systemctl are stubs. Never the network, never a real service.
# Run: bats packages/anfsd/tests </dev/null

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_STATE_HOME FAIL ANFSD_BIN \
    ANFSD_STATE_HOME ANFSD_CONFIG_HOME
  export ANFS_LOG=off ANFS_EVENTS=off ANFS_PIN_PLATFORM=linux-amd64 STUB="$T/stub"
  mkdir -p "$HOME/.config/anfsd" "$STUB/assets" "$T/bin" "$T/core/packages" "$T/fx"
  ln -s "$REPO/packages/anfsd/home/.config/anfsd/anfsd.env" "$HOME/.config/anfsd/anfsd.env"
  cp -R "$REPO/packages/anfsd" "$T/core/packages/anfsd"
  ln -s "$REPO/packages/anfs" "$T/core/packages/anfs"
  PKG="$T/core/packages/anfsd"
  printf '#!/bin/sh\necho v0.3.0\n' > "$T/fx/anfsd"
  chmod +x "$T/fx/anfsd"
  tar -czf "$STUB/assets/anfsd-v0.3.0-linux-amd64.tar.gz" -C "$T/fx" anfsd
  cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
echo "$url" >> "$STUB/curl.log"
[[ -f "$STUB/assets/${url##*/}" ]] || exit 22
cp "$STUB/assets/${url##*/}" "$out"
STUB
  for t in launchctl systemctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/svc.log"\ncase "$1" in print) exit 113 ;; esac\n[ -z "$FAIL" ]\n' "$t" "$STUB" > "$T/bin/$t"
  done
  chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"
  PLIST="$HOME/Library/LaunchAgents/io.anfs.anfsd.plist"
  UNIT="$HOME/.config/systemd/user/anfsd.service"
  REL="$HOME/.local/share/anfsd/v0.3.0/anfsd"
}

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# pins.yml with the fixture release's sum
pinned() {
  S="$(sha "$STUB/assets/anfsd-v0.3.0-linux-amd64.tar.gz")" yq -i '.anfsd.sha256 = {"linux-amd64": strenv(S)}' "$PKG/pins.yml"
}

hook() {
  bash -c 'user_message() { printf "msg: %s\n" "$*"; }; ppm_fail() { printf "FAIL: %s\n" "$*"; }
           source "$1/install.sh"; "$2"' _ "$PKG" "$1"
}

@test "the release: fetched by its pinned URL into DATA, linked; the agent runs it (macOS)" {
  pinned
  ANFS_SERVICE_OS=macos run hook post_install
  [[ "$output" != *FAIL* ]] || { echo "$output"; false; }
  [[ "$output" == *"msg: anfsd ships the event log to NATS (release)"* ]]
  [ "$(cat "$STUB/curl.log")" = "https://github.com/anfs-io/runtime/releases/download/v0.3.0/anfsd-v0.3.0-linux-amd64.tar.gz" ]
  [ "$(readlink "$HOME/.local/bin/anfsd")" = "$REL" ]
  [ "$("$HOME/.local/bin/anfsd")" = v0.3.0 ]
  grep -q '<key>Label</key><string>io.anfs.anfsd</string>' "$PLIST"
  tr -d ' \n' < "$PLIST" | grep -q "<array><string>$REL</string><string>run</string></array>"
  grep -q "<key>StandardErrorPath</key><string>$HOME/.local/state/anfsd/anfsd.log</string>" "$PLIST"
  grep -qx "launchctl bootstrap gui/$(id -u) $PLIST" "$STUB/svc.log"
  # the XDG rule: nothing in CONFIG but the linked settings
  [ "$(cd "$HOME/.config" && find . ! -type d | sort | tr '\n' ' ')" = "./anfsd/anfsd.env " ]
}

@test "Linux: after NATS, KillMode=process, restarted on failure" {
  pinned
  ANFS_SERVICE_OS=linux run hook post_install
  [[ "$output" != *FAIL* ]]
  grep -qx 'Requires=anfs-nats.service' "$UNIT"
  grep -qx 'After=anfs-nats.service' "$UNIT"
  grep -qx 'KillMode=process' "$UNIT"
  grep -qx 'Restart=on-failure' "$UNIT"
  grep -qx "ExecStart=$REL run" "$UNIT"
  grep -qx "Environment=\"HOME=$HOME\"" "$UNIT"
}

@test "ANFSD_BIN: its path in the unit, the release still fetched when pinned" {
  pinned
  mkdir -p "$HOME/.local/share/anfsd/dev"
  printf '#!/bin/sh\necho dev\n' > "$HOME/.local/share/anfsd/dev/anfsd"
  chmod +x "$HOME/.local/share/anfsd/dev/anfsd"
  printf 'ANFSD_BIN=~/.local/share/anfsd/dev/anfsd\n' > "$HOME/.config/anfsd/anfsd.local.env"
  ANFS_SERVICE_OS=linux run hook post_install
  [[ "$output" == *"msg: anfsd ships the event log to NATS (source)"* ]]
  grep -qx "ExecStart=$HOME/.local/share/anfsd/dev/anfsd run" "$UNIT"
  [ "$(readlink "$HOME/.local/bin/anfsd")" = "$REL" ]
}

@test "no release pinned: ANFSD_BIN is enough; without it the install fails saying how" {
  ANFS_SERVICE_OS=linux run hook post_install
  [[ "$output" == *"FAIL: anfsd v0.3.0 has no sha256 for linux-amd64"*"set ANFSD_BIN in ~/.config/anfsd/anfsd.local.env"* ]]
  [ ! -e "$UNIT" ] && [ ! -s "$STUB/curl.log" ]
  printf 'ANFSD_BIN=%s\n' "$T/fx/anfsd" > "$HOME/.config/anfsd/anfsd.local.env"
  ANFS_SERVICE_OS=linux run hook post_install
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"No anfsd release installed"*"runs ANFSD_BIN=$T/fx/anfsd"* ]]
  grep -qx "ExecStart=$T/fx/anfsd run" "$UNIT"
  [ ! -e "$HOME/.local/bin/anfsd" ]
  printf 'ANFSD_BIN=%s\n' "$T/nothing" > "$HOME/.config/anfsd/anfsd.local.env"
  ANFS_SERVICE_OS=linux run hook post_install
  [[ "$output" == *"FAIL: ANFSD_BIN=$T/nothing is not an executable file"* ]]
}

@test "post_remove: unloaded, the unit and the link gone; STATE kept" {
  pinned
  ANFS_SERVICE_OS=macos hook post_install
  mkdir -p "$HOME/.local/state/anfsd" && echo '{}' > "$HOME/.local/state/anfsd/cursors.json"
  : > "$STUB/svc.log"
  ANFS_SERVICE_OS=macos run hook post_remove
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB/svc.log")" = "launchctl bootout gui/$(id -u)/io.anfs.anfsd" ]
  [ ! -e "$PLIST" ] && [ ! -e "$HOME/.local/bin/anfsd" ]
  [ -f "$HOME/.local/state/anfsd/cursors.json" ] && [ -x "$REL" ]
}

@test "the real pins: anfs-io/runtime v0.3.0, an archive per platform with anfsd at its root" {
  local p="$REPO/packages/anfsd/pins.yml"
  [ "$(yq -r '.anfsd.repo + " " + .anfsd.version + " " + .anfsd.asset + " " + .anfsd.bin' "$p")" = \
    "anfs-io/runtime v0.3.0 anfsd-{version}-{os}-{arch}.tar.gz anfsd" ]
  yq -r '.anfsd.sha256[]' "$p" | while read -r s; do [[ "$s" =~ ^[0-9a-f]{64}$ ]]; done
}

@test "anfsd.env names the settings anfsd and anfs bus read" {
  local f="$REPO/packages/anfsd/home/.config/anfsd/anfsd.env"
  [ "$(sed -nE 's/^#?(ANFSD_[A-Z_]+)=.*/\1/p' "$f" | sort | tr '\n' ' ')" = \
    "ANFSD_BIN ANFSD_CLAUDE_BARE ANFSD_DUP_WINDOW ANFSD_MAX_RUNS ANFSD_PODMAN ANFSD_RUN_EVENTS_MAX ANFSD_SHIP_BURST ANFSD_SHIP_RATE ANFSD_STREAM_MAX_AGE ANFSD_STREAM_MAX_BYTES " ]
}
