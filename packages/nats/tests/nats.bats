#!/usr/bin/env bats
# core/nats's hooks (lib/anfs/{pins,service,bus}.sh): the pinned nats-server and nats CLI fetched
# into DATA and linked, ~/.local/state/nats rendered (users, server.conf, port), the service
# written and loaded; post_remove unloads and deletes it and the links, keeps STATE. A temp HOME;
# curl serves fixture archives whose sums this file pins (a copy of the package with its own
# pins.yml); launchctl and systemctl are stubs that log their argv. Never the network, never a
# real service. ANFS_SERVICE_OS picks the platform, ANFS_PIN_PLATFORM the release's.
# Run: bats packages/nats/tests </dev/null

unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_STATE_HOME FAIL \
    ANFS_NATS_PORT ANFS_NATS_HTTP_PORT ANFS_NATS_MAX_FILE ANFS_NATS_MAX_MEM NATS_STATE_HOME NATS_CONFIG_HOME
  export ANFS_LOG=off ANFS_EVENTS=off ANFS_PIN_PLATFORM=darwin-arm64 STUB="$T/stub"
  mkdir -p "$HOME/.config/nats" "$STUB/assets" "$T/bin" "$T/core/packages"
  ln -s "$REPO/packages/nats/home/.config/nats/nats.env" "$HOME/.config/nats/nats.env"
  # the package, beside core/anfs as in a source, with pins of the fixtures
  cp -R "$REPO/packages/nats" "$T/core/packages/nats"
  ln -s "$REPO/packages/anfs" "$T/core/packages/anfs"
  PKG="$T/core/packages/nats"
  fixtures
  # curl -fsSL --retry 3 -o <file> <url>: the asset named by the URL's last part, logged
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
  NS="$HOME/.local/state/nats"
  PLIST="$HOME/Library/LaunchAgents/io.anfs.nats.plist"
  UNIT="$HOME/.config/systemd/user/anfs-nats.service"
}

sha() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# A tar.gz holding nats-server-v2.15.1-darwin-arm64/nats-server and a zip holding
# nats-0.5.0-darwin-arm64/nats, each a script that says what it is; pins.yml pins their sums
fixtures() {
  local d="$T/fx"
  mkdir -p "$d/nats-server-v2.15.1-darwin-arm64" "$d/nats-0.5.0-darwin-arm64"
  printf '#!/bin/sh\necho "nats-server: v2.15.1 $*"\n' > "$d/nats-server-v2.15.1-darwin-arm64/nats-server"
  printf '#!/bin/sh\necho "nats cli $*"\n' > "$d/nats-0.5.0-darwin-arm64/nats"
  chmod +x "$d"/*/*
  tar -czf "$STUB/assets/nats-server-v2.15.1-darwin-arm64.tar.gz" -C "$d" nats-server-v2.15.1-darwin-arm64
  if command -v zip >/dev/null; then
    (cd "$d" && zip -qr "$STUB/assets/nats-0.5.0-darwin-arm64.zip" nats-0.5.0-darwin-arm64)
  else
    (cd "$d" && python3 -m zipfile -c "$STUB/assets/nats-0.5.0-darwin-arm64.zip" nats-0.5.0-darwin-arm64)
  fi
  S1=$(sha "$STUB/assets/nats-server-v2.15.1-darwin-arm64.tar.gz")
  S2=$(sha "$STUB/assets/nats-0.5.0-darwin-arm64.zip")
  S1="$S1" S2="$S2" yq -i '.["nats-server"].sha256 = {"darwin-arm64": strenv(S1)} | .nats.sha256 = {"darwin-arm64": strenv(S2)}' "$PKG/pins.yml"
}

# One of the hooks, as ppm runs it: install.sh sourced in a subshell, ppm's helpers given
hook() {
  bash -c 'user_message() { printf "msg: %s\n" "$*"; }; ppm_fail() { printf "FAIL: %s\n" "$*"; }
           source "$1/install.sh"; "$2"' _ "$PKG" "$1"
}

mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

@test "macOS post_install: both programs in DATA, linked; STATE rendered; the agent written and loaded" {
  ANFS_SERVICE_OS=macos run hook post_install
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]] || { echo "$output"; false; }
  [[ "$output" == *"msg: NATS listens on 127.0.0.1:47222 (monitoring 47223)"* ]]
  [ -x "$HOME/.local/share/nats/v2.15.1/nats-server" ]
  [ -x "$HOME/.local/share/nats/v0.5.0/nats" ]
  [ "$(readlink "$HOME/.local/bin/nats-server")" = "$HOME/.local/share/nats/v2.15.1/nats-server" ]
  [ "$(readlink "$HOME/.local/bin/nats")" = "$HOME/.local/share/nats/v0.5.0/nats" ]
  [ "$("$HOME/.local/bin/nats" x)" = "nats cli x" ]
  [ -f "$HOME/.cache/nats/v2.15.1/nats-server-v2.15.1-darwin-arm64.tar.gz" ]
  [ "$(mode "$NS")" = 700 ] && [ "$(mode "$NS/server.conf")" = 600 ] && [ "$(mode "$NS/users")" = 700 ]
  [ "$(cat "$NS/port")" = 47222 ]
  grep -qx 'listen: 127.0.0.1:47222' "$NS/server.conf"
  grep -qx 'http: 127.0.0.1:47223' "$NS/server.conf"
  grep -qx "  store_dir: \"$NS\"" "$NS/server.conf"
  grep -qx '  max_file_store: 2GiB' "$NS/server.conf"
  for u in anfsd admin reader; do
    [[ "$(cat "$NS/users/$u")" =~ ^[0-9a-f]{64}$ ]]
    [ "$(mode "$NS/users/$u")" = 600 ]
    grep -q "user: \"$u\", password: \"$(cat "$NS/users/$u")\"" "$NS/server.conf"
  done
  # reader: subscribe anfs.>, never publish it
  grep -q 'subscribe: {allow: \["anfs.>", "_INBOX.>"\]}' "$NS/server.conf"
  ! grep -q 'publish: {allow: \[[^]]*"anfs\.' "$NS/server.conf"
  # the agent
  ! command -v plutil >/dev/null || plutil -lint "$PLIST"
  grep -q '<key>Label</key><string>io.anfs.nats</string>' "$PLIST"
  tr -d ' \n' < "$PLIST" | grep -q "<array><string>$HOME/.local/share/nats/v2.15.1/nats-server</string><string>-c</string><string>$NS/server.conf</string></array>"
  tr -d ' \n' < "$PLIST" | grep -q '<key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>'
  grep -q "<key>StandardErrorPath</key><string>$NS/nats-server.log</string>" "$PLIST"
  grep -q "<key>HOME</key><string>$HOME</string>" "$PLIST"
  [ "$(cat "$STUB/svc.log")" = "launchctl print gui/$(id -u)/io.anfs.nats
launchctl bootstrap gui/$(id -u) $PLIST" ]
  [ ! -e "$HOME/.config/systemd" ]
  # the XDG rule: nothing in CONFIG but the linked settings
  [ "$(cd "$HOME/.config" && find . ! -type d | sort | tr '\n' ' ')" = "./nats/nats.env " ]
}

@test "nats.local.env: the ports and caps rendered; a bad value writes nothing and fails" {
  printf 'ANFS_NATS_PORT=47999\nANFS_NATS_HTTP_PORT=47998\nANFS_NATS_MAX_FILE=5GiB\n' > "$HOME/.config/nats/nats.local.env"
  ANFS_SERVICE_OS=macos run hook post_install
  [[ "$output" != *FAIL* ]]
  grep -qx 'listen: 127.0.0.1:47999' "$NS/server.conf"
  grep -qx 'http: 127.0.0.1:47998' "$NS/server.conf"
  grep -qx '  max_file_store: 5GiB' "$NS/server.conf"
  [ "$(cat "$NS/port")" = 47999 ]
  printf 'ANFS_NATS_PORT=nope\n' > "$HOME/.config/nats/nats.local.env"
  ANFS_SERVICE_OS=macos run hook post_install
  [[ "$output" == *"FAIL: server.conf not written"* ]]
  grep -qx 'listen: 127.0.0.1:47999' "$NS/server.conf"
}

@test "ANFS_BUS_LAYERS: a publisher user per layer, its subjects only (anfs.*.<layer>.>) and reader's consumer API; a bad name warned and left out" {
  printf 'ANFS_BUS_LAYERS=cnfs anfs Bad-1 lgat reader cnfs\n' > "$HOME/.config/nats/nats.local.env"
  ANFS_SERVICE_OS=macos run hook post_install
  [[ "$output" != *FAIL* ]] || { echo "$output"; false; }
  [[ "$output" == *"ANFS_BUS_LAYERS: 'anfs' is not a layer's namespace"* ]]
  [[ "$output" == *"ANFS_BUS_LAYERS: 'Bad-1' is not a layer's namespace"* ]]
  [[ "$output" == *"ANFS_BUS_LAYERS: 'reader' is not a layer's namespace"* ]]
  [ "$(ls "$NS/users" | tr '\n' ' ')" = "admin anfsd cnfs lgat reader " ]
  for u in cnfs lgat; do
    [[ "$(cat "$NS/users/$u")" =~ ^[0-9a-f]{64}$ ]] && [ "$(mode "$NS/users/$u")" = 600 ]
  done
  [ "$(grep -c 'user: "cnfs"' "$NS/server.conf")" = 1 ]
  # cnfs's block: subscribe anfs.> and inboxes; publish its layer's subjects and the consumer API
  block=$(sed -n '/user: "cnfs"/,/^    }/p' "$NS/server.conf")
  [[ "$block" == *'subscribe: {allow: ["anfs.>", "_INBOX.>"]}'* ]]
  [[ "$block" == *'"anfs.*.cnfs.>",'* ]]
  for p in '$JS.API.INFO' '$JS.API.STREAM.INFO.ANFS' '$JS.API.CONSUMER.*.ANFS.>' '$JS.API.CONSUMER.DURABLE.CREATE.ANFS.>' '$JS.API.CONSUMER.MSG.NEXT.ANFS.>' '$JS.ACK.ANFS.>'; do
    [[ "$block" == *"\"$p\""* ]]
  done
  # never anfs's subjects, all of anfs.>, or stream management
  pub="${block#*publish: }"
  [[ "$pub" != *'"anfs.>"'* && "$pub" != *'*.anfs.>'* && "$pub" != *STREAM.CREATE* && "$pub" != *STREAM.DELETE* && "$pub" != *STREAM.UPDATE* ]]
  [ "$(sed -n '/user: "lgat"/,/^    }/p' "$NS/server.conf" | grep -c '"anfs.\*.lgat.>"')" = 1 ]
  # the reader's block is unchanged: no publish of anfs.>
  ! sed -n '/user: "reader"/,/^    }/p' "$NS/server.conf" | grep -q '"anfs\.'
  # none by default
  rm "$HOME/.config/nats/nats.local.env"
  ANFS_SERVICE_OS=macos hook post_install
  ! grep -q 'user: "cnfs"' "$NS/server.conf"
}

@test "a reinstall keeps the passwords and fetches nothing again; the loaded agent goes out, then in" {
  ANFS_SERVICE_OS=macos hook post_install
  local a
  a=$(cat "$NS/users/admin")
  [ "$(wc -l < "$STUB/curl.log" | tr -d ' ')" = 2 ]
  : > "$STUB/svc.log"
  ANFS_SERVICE_OS=macos hook post_remove
  ANFS_SERVICE_OS=macos run hook post_install
  [[ "$output" != *FAIL* ]]
  [ "$(cat "$NS/users/admin")" = "$a" ]
  [ "$(wc -l < "$STUB/curl.log" | tr -d ' ')" = 2 ]
  grep -qx "launchctl bootout gui/$(id -u)/io.anfs.nats" "$STUB/svc.log"
  [ "$(tail -1 "$STUB/svc.log")" = "launchctl bootstrap gui/$(id -u) $PLIST" ]
}

@test "a wrong sum: both sums named, the download deleted, nothing linked or written" {
  printf 'tampered' >> "$STUB/assets/nats-0.5.0-darwin-arm64.zip"
  ANFS_SERVICE_OS=macos run hook post_install
  [[ "$output" == *"FAIL: nats-0.5.0-darwin-arm64.zip: sha256 $(sha "$STUB/assets/nats-0.5.0-darwin-arm64.zip"), pinned $S2"* ]]
  [ ! -e "$HOME/.local/bin/nats" ] && [ ! -e "$HOME/.local/bin/nats-server" ]
  [ -z "$(ls -A "$HOME/.cache/nats/v0.5.0")" ]
  [ ! -e "$HOME/.local/share/nats/v0.5.0" ]
  [ ! -e "$NS" ] && [ ! -e "$PLIST" ]
}

@test "an unpinned platform, and no curl, fail saying what is missing" {
  ANFS_PIN_PLATFORM=freebsd-riscv64 ANFS_SERVICE_OS=macos run hook post_install
  [[ "$output" == *"FAIL: nats-server v2.15.1 has no sha256 for freebsd-riscv64"*"no release is pinned for this platform"* ]]
  [ ! -e "$HOME/.local/bin/nats-server" ]
  # a PATH with what the hook needs before the download, and no curl
  mkdir -p "$T/nocurl"
  for t in bash yq dirname; do ln -s "$(command -v "$t")" "$T/nocurl/$t"; done
  PATH="$T/nocurl" ANFS_SERVICE_OS=macos run hook post_install
  [[ "$output" == *"FAIL: curl is not installed"* ]] || { echo "$output"; false; }
}

@test "Linux post_install: the user unit written, enabled and restarted" {
  ANFS_SERVICE_OS=linux run hook post_install
  [ "$status" -eq 0 ]
  [[ "$output" != *FAIL* ]]
  grep -qx "ExecStart=$HOME/.local/share/nats/v2.15.1/nats-server -c $NS/server.conf" "$UNIT"
  grep -qx 'Restart=on-failure' "$UNIT"
  grep -qx 'RestartSec=5' "$UNIT"
  grep -qx 'WantedBy=default.target' "$UNIT"
  ! grep -q '^KillMode' "$UNIT"
  [ "$(cat "$STUB/svc.log")" = "systemctl --user daemon-reload
systemctl --user enable anfs-nats.service
systemctl --user restart anfs-nats.service" ]
  [ ! -e "$PLIST" ]
}

@test "no user manager or GUI session: the install goes on, with a warning" {
  FAIL=1 ANFS_SERVICE_OS=linux run hook post_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not enable anfs-nats.service"* ]]
  [ -f "$UNIT" ]
}

@test "post_remove: unloaded, the unit and the links deleted; STATE and DATA kept" {
  for os in macos linux; do
    ANFS_SERVICE_OS=$os hook post_install
    : > "$STUB/svc.log"
    ANFS_SERVICE_OS=$os run hook post_remove
    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.local/bin/nats" ] && [ ! -e "$HOME/.local/bin/nats-server" ]
    [ -s "$NS/users/admin" ] && [ -f "$NS/server.conf" ]
    [ -x "$HOME/.local/share/nats/v2.15.1/nats-server" ]
  done
  [ ! -e "$PLIST" ] && [ ! -e "$HOME/.config/systemd" ]
  [ "$(cat "$STUB/svc.log")" = "systemctl --user disable --now anfs-nats.service
systemctl --user daemon-reload" ]
}

@test "remove with no unit in this HOME calls neither launchctl nor systemctl" {
  ANFS_SERVICE_OS=macos run hook post_remove
  ANFS_SERVICE_OS=linux run hook post_remove
  [ ! -s "$STUB/svc.log" ]
}

@test "nats.env documents every setting bus.sh reads for NATS, and nothing else" {
  local lib="$REPO/packages/anfs/home/.local/lib/anfs/bus.sh" n
  local read shipped
  read=$(grep -oE '\$\{ANFS_NATS_[A-Z_]+:?[-=]' "$lib" | sed -E 's/^\$\{//; s/:?[-=]$//' | sort -u)
  shipped=$(sed -nE 's/^#?(ANFS_NATS_[A-Z_]+)=.*/\1/p' "$REPO/packages/nats/home/.config/nats/nats.env" | sort -u)
  [ -n "$read" ]
  [ "$read" = "$shipped" ]
}

@test "the real pins: four platforms each, 64-hex sums, the versions the plan pins" {
  local p="$REPO/packages/nats/pins.yml"
  [ "$(yq -r '.["nats-server"].version' "$p")" = v2.15.1 ]
  [ "$(yq -r '.nats.version' "$p")" = v0.5.0 ]
  for n in nats-server nats; do
    [ "$(N=$n yq -r '.[strenv(N)].sha256 | keys | sort | join(" ")' "$p")" = "darwin-amd64 darwin-arm64 linux-amd64 linux-arm64" ]
    N=$n yq -r '.[strenv(N)].sha256[]' "$p" | while read -r s; do [[ "$s" =~ ^[0-9a-f]{64}$ ]]; done
  done
}
