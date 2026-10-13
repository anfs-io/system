#!/usr/bin/env bats
# lib/anfs/iso.sh: the ISO store, its downloader and the layered catalogue. `curl` is a stub that
# serves files from $WEB by their URL's path. pim, pmm and ventoy are its users.
# Run: bats packages/anfs/tests/

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  export ANFS_LOG=off
  CLI_TOOL=tool
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" WEB="$T/web" CURL_LOG="$T/curl.log"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
  unset ANFS_ISO_HOME ANFS_CONFIG_HOME ANFS_CACHE_HOME ANFS_DATA_HOME ANFS_STATE_HOME
  mkdir -p "$HOME" "$WEB" "$T/bin"
  # shellcheck source=/dev/null
  source "$lib/paths.sh"
  source "$lib/log.sh"
  source "$lib/sources.sh"
  source "$lib/iso.sh"

  GITSRC_USER_LIST="$T/user.list"
  GITSRC_SYSTEM_LIST="$T/system.list"
  GITSRC_REPOS_DIR="$T/sources"
  GITSRC_LINK_LOCAL=false
  printf 'file:///x/hi.git  hi\nfile:///x/lo.git  lo\n' > "$GITSRC_USER_LIST"
  mkdir -p "$T/sources/hi/isos" "$T/sources/lo/isos"

  # curl: -o FILE and the URL are all that matter; https://host/<path> is $WEB/<path>
  cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|--retry|-C) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >> "$CURL_LOG"
src="$WEB/${url#https://*/}"
[[ -f "$src" ]] || { printf 404; exit 22; }
if [[ -n "$out" ]]; then cp "$src" "$out"; printf 200; else cat "$src"; fi
EOF
  chmod +x "$T/bin/curl"
  PATH="$T/bin:$PATH"
  : > "$CURL_LOG"
  echo "debian content" > "$WEB/debian.iso"
  SHA=$(anfs_iso_sha256 "$WEB/debian.iso")
}

@test "fetch: downloads into the store once, pinned by sha256" {
  run anfs_iso_fetch --sha256 "$SHA" https://x/debian.iso
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$HOME/.cache/anfs/isos/debian.iso" ]
  [ "$(cat "$HOME/.cache/anfs/isos/debian.iso.sha256")" = "$SHA" ]
  run anfs_iso_fetch --sha256 "$SHA" https://x/debian.iso
  [ "$output" = "$HOME/.cache/anfs/isos/debian.iso" ]
  [ "$(wc -l < "$CURL_LOG")" -eq 1 ]
}

@test "fetch: the URLs are tried in order; a wrong sum is not kept" {
  run anfs_iso_fetch --sha256 "$SHA" https://x/gone/debian.iso https://x/debian.iso
  [ "$status" -eq 0 ]
  [[ "$output" == *"download failed"* ]]
  [ "${lines[-1]}" = "$HOME/.cache/anfs/isos/debian.iso" ]

  echo other > "$WEB/other.iso"
  run anfs_iso_fetch --sha256 "$SHA" https://x/other.iso
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$HOME/.cache/anfs/isos/other.iso" ]
  [ ! -e "$HOME/.cache/anfs/isos/other.iso.part" ]
}

@test "fetch: a file that no longer matches its pinned sum is downloaded again" {
  anfs_iso_fetch --sha256 "$SHA" https://x/debian.iso
  echo tampered > "$HOME/.cache/anfs/isos/debian.iso"
  run anfs_iso_fetch --sha256 "$SHA" https://x/debian.iso
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.cache/anfs/isos/debian.iso")" = "debian content" ]
}

@test "fetch: the publisher's checksum file, a name of its own, and no checksum at all" {
  printf '%s  debian.iso\n%s  other.iso\n' "$SHA" "$(printf '%064d' 0)" > "$WEB/SHA256SUMS"
  run anfs_iso_fetch --checksum-url https://x/SHA256SUMS https://x/debian.iso
  [ "$status" -eq 0 ]
  [ "$(cat "$HOME/.cache/anfs/isos/debian.iso.sha256")" = "$SHA" ]

  run anfs_iso_fetch --name d13.iso https://x/debian.iso
  [ "$status" -eq 0 ]
  [[ "$output" == *"no checksum to verify it against"* ]]
  [ "${lines[-1]}" = "$HOME/.cache/anfs/isos/d13.iso" ]
  [ ! -e "$HOME/.cache/anfs/isos/d13.iso.sha256" ]
}

@test "checksum: the forms publishers use" {
  printf 'SHA256 (debian.iso) = %s\n' "$SHA" > "$WEB/bsd"
  [ "$(anfs_iso_checksum https://x/bsd debian.iso)" = "$SHA" ]
  printf '%s *debian.iso\n' "$SHA" > "$WEB/star"
  [ "$(anfs_iso_checksum https://x/star debian.iso)" = "$SHA" ]
  printf '%s\n' "$SHA" > "$WEB/bare"
  [ "$(anfs_iso_checksum https://x/bare debian.iso)" = "$SHA" ]
  printf '%s  another.iso\n' "$SHA" > "$WEB/none"
  [ -z "$(anfs_iso_checksum https://x/none debian.iso)" ]
}

@test "catalogue: the sources in order, the hand-made one first; an id is defined once" {
  cat > "$T/sources/hi/isos/isos.yml" <<EOF
- id: debian
  url: https://x/debian.iso
  checksum: $SHA
EOF
  cat > "$T/sources/lo/isos/isos.yml" <<'EOF'
- id: debian
  url: https://x/old.iso
- id: pve
  url: [https://x/gone/pve.iso, https://x/pve.iso]
  filename: proxmox.iso
EOF
  [ "$(anfs_iso_ids | paste -sd' ' -)" = "debian pve" ]
  [ "$(anfs_iso_get debian url)" = "https://x/debian.iso" ]
  [ "$(anfs_iso_get pve url | wc -l)" -eq 2 ]
  [ "$(anfs_iso_file pve)" = "$HOME/.cache/anfs/isos/proxmox.iso" ]
  [ "$(anfs_iso_file debian)" = "$HOME/.cache/anfs/isos/debian.iso" ]
  anfs_iso_known pve
  ! anfs_iso_known nope

  mkdir -p "$HOME/.config/anfs"
  printf -- '- id: debian\n  url: https://x/mine.iso\n' > "$HOME/.config/anfs/isos.yml"
  [ "$(anfs_iso_get debian url)" = "https://x/mine.iso" ]
  [ "$(anfs_iso_ids | paste -sd' ' -)" = "debian pve" ]
}

@test "fetch_id: a catalogue entry by its id" {
  echo pve > "$WEB/pve.iso"
  cat > "$T/sources/hi/isos/isos.yml" <<EOF
- id: debian
  url: https://x/debian.iso
  checksum: sha256:$SHA
- id: pve
  url: [https://x/gone/pve.iso, https://x/pve.iso]
  filename: proxmox.iso
EOF
  run anfs_iso_fetch_id debian
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$HOME/.cache/anfs/isos/debian.iso" ]
  run anfs_iso_fetch_id pve
  [ "${lines[-1]}" = "$HOME/.cache/anfs/isos/proxmox.iso" ]
  run anfs_iso_fetch_id nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"no ISO 'nope' in the catalogue"* ]]
}
