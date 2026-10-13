#!/usr/bin/env bats
# lib/anfs/iso.sh: the ISO store, its downloader, the layered catalogue and the `iso` command
# group every tool that uses ISOs adopts (anfs, pmm, ventoy). `curl` is a stub that serves files
# from $WEB by their URL's path. Everything is under a temp HOME, the store included: `iso remove`
# and `iso prune` delete from it.
# Run: bats packages/anfs/tests/

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  export ANFS_LOG=off
  CLI_TOOL=tool
  T="$BATS_TEST_TMPDIR"
  export HOME="$T/home" WEB="$T/web" CURL_LOG="$T/curl.log"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
  export XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state"
  unset ANFS_ISO_HOME ANFS_CONFIG_HOME ANFS_CACHE_HOME ANFS_DATA_HOME ANFS_STATE_HOME
  mkdir -p "$HOME" "$WEB" "$T/bin"
  # shellcheck source=/dev/null
  source "$lib/paths.sh"
  source "$lib/log.sh"
  source "$lib/sources.sh"
  source "$lib/iso.sh"
  source "$lib/cli.sh"
  source "$lib/table.sh"
  export ANFS_TABLE=tsv
  unset ANFS_JSON
  anfs_iso_cli
  STORE="$HOME/.cache/anfs/isos"
  [[ "$ANFS_ISO_HOME" == "$STORE" ]]

  # The lists and the sources are where the tools themselves look, so the real anfs and pmm see
  # the same catalogue (the last tests run them)
  anfs_gitsrc_env
  mkdir -p "$HOME/.config/anfs" "$HOME/.local/share/anfs/sources" "$HOME/.local/lib"
  ln -s "$HOME/.local/share/anfs/sources" "$T/sources"
  ln -s "$lib" "$HOME/.local/lib/anfs"
  printf 'file:///x/hi.git  hi\nfile:///x/lo.git  lo\n' > "$GITSRC_USER_LIST"
  mkdir -p "$T/sources/hi/isos" "$T/sources/lo/isos"
  ANFS="$BATS_TEST_DIRNAME/../home/.local/bin/anfs"
  PMM="$BATS_TEST_DIRNAME/../../pmm/home/.local/bin/pmm"
  export PMM_SOCK_DIR="$T/sock"

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

# A command of the group, as typed after `<tool> iso`
iso() { cli_call "iso $1" "${@:2}"; }

# hi: debian (pinned) and pve; lo: debian again (shadowed) and old
catalogue() {
  echo pve > "$WEB/pve.iso"
  cat > "$T/sources/hi/isos/isos.yml" <<EOF
- id: debian
  name: Debian 13
  architecture: amd64
  url: https://x/debian.iso
  checksum: sha256:$SHA
- id: pve
  url: [https://x/gone/pve.iso, https://x/pve.iso]
  filename: proxmox.iso
EOF
  cat > "$T/sources/lo/isos/isos.yml" <<'EOF'
- id: debian
  url: https://x/old-debian.iso
- id: old
  url: https://x/old.iso
EOF
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

@test "fetch_id: an entry with no url is its file while it is in the store" {
  mkdir -p "$HOME/.config/anfs" "$STORE"
  printf -- '- id: some\n  filename: some.iso\n' > "$HOME/.config/anfs/isos.yml"
  run anfs_iso_fetch_id some
  [ "$status" -eq 1 ]
  [[ "$output" == *"no url in the catalogue, and its file is not in the store"* ]]
  echo some > "$STORE/some.iso"
  run anfs_iso_fetch_id some
  [ "$output" = "$STORE/some.iso" ]
  [ ! -s "$CURL_LOG" ]
}

@test "iso list: a source's entry, a hand-made one over it, present, unverified and missing" {
  catalogue
  mkdir -p "$STORE"
  printf -- '- id: debian\n  url: https://x/mine.iso\n' > "$HOME/.config/anfs/isos.yml"
  echo mine > "$STORE/mine.iso"; echo sum > "$STORE/mine.iso.sha256"
  echo pve > "$STORE/proxmox.iso"
  echo stray > "$STORE/stray.iso"; echo sum > "$STORE/stray.iso.sha256"
  run iso list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "debian"$'\t'"-"$'\t'"-"$'\t'"mine.iso"$'\t'"present"$'\t'5* ]]
  [[ "${lines[1]}" == "pve"$'\t'"-"$'\t'"-"$'\t'"proxmox.iso"$'\t'"unverified"$'\t'4* ]]
  [ "${lines[2]}" = "old"$'\t'"-"$'\t'"-"$'\t'"old.iso"$'\t'"missing"$'\t'"-" ]

  rm "$HOME/.config/anfs/isos.yml"
  run iso ls
  [[ "${lines[0]}" == "debian"$'\t'"Debian 13"$'\t'"amd64"$'\t'"debian.iso"$'\t'"missing"$'\t'"-" ]]
}

@test "iso list --all shows a file no entry names; --json has the keys" {
  catalogue
  mkdir -p "$STORE"
  echo stray > "$STORE/stray.iso"; echo sum > "$STORE/stray.iso.sha256"
  run iso list --all
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[3]}" == "-"$'\t'"-"$'\t'"-"$'\t'"stray.iso"$'\t'"unlisted"$'\t'6* ]]

  # sizes are bytes in JSON
  ANFS_TABLE="" ANFS_JSON=true run iso list --all
  [[ "$output" == *'"file":"stray.iso","state":"unlisted","size":"6","catalog":null}]' ]]
  ANFS_TABLE="" ANFS_JSON=true run iso list
  [[ "$output" == '[{"id":"debian","name":"Debian 13","architecture":"amd64","file":"debian.iso","state":"missing","size":null,"catalog":"'"$HOME"'/.local/share/anfs/sources/hi/isos/isos.yml"},'* ]]
  [[ "$output" == *'{"id":"old",'*'/sources/lo/isos/isos.yml"}]' ]]
}

@test "iso add: a URL is recorded and not fetched; an id that exists is refused with 73" {
  run iso add https://x/debian.iso --name "Debian 13" --arch amd64 --sha256 "$SHA"
  [ "$status" -eq 0 ]
  [ ! -s "$CURL_LOG" ]
  [ ! -e "$STORE/debian.iso" ]
  [ "$(anfs_iso_get debian url)" = "https://x/debian.iso" ]
  [ "$(anfs_iso_get debian name)" = "Debian 13" ]
  [ "$(anfs_iso_get debian architecture)" = "amd64" ]
  [ "$(anfs_iso_get debian checksum)" = "sha256:$SHA" ]
  [ -z "$(anfs_iso_get debian filename)" ]

  run iso add https://x/debian.iso
  [ "$status" -eq 73 ]
  run iso add https://x/other/debian.iso -f --checksum-url https://x/SHA256SUMS
  [ "$status" -eq 0 ]
  [ "$(anfs_iso_ids)" = "debian" ]
  [ "$(anfs_iso_get debian url)" = "https://x/other/debian.iso" ]
  [ "$(anfs_iso_get debian checksum_url)" = "https://x/SHA256SUMS" ]
  [ -z "$(anfs_iso_get debian checksum)" ]

  # a source's id is refused too: -f is what puts an entry of yours over it
  catalogue
  run iso add https://x/pve.iso --id pve
  [ "$status" -eq 73 ]
  [[ "$output" == *"sources/hi/isos/isos.yml"* ]]
  run iso add https://x/a.iso --id "not an id"
  [ "$status" -eq 64 ]
}

@test "iso add: a file is copied into the store, hashed and pinned" {
  echo "my own" > "$T/some-1.2.iso"
  local sum
  sum=$(anfs_iso_sha256 "$T/some-1.2.iso")
  run iso add "$T/some-1.2.iso" --id some
  [ "$status" -eq 0 ]
  [ "$(cat "$STORE/some-1.2.iso")" = "my own" ]
  [ "$(cat "$STORE/some-1.2.iso.sha256")" = "$sum" ]
  [ "$(anfs_iso_get some checksum)" = "sha256:$sum" ]
  [ "$(anfs_iso_get some filename)" = "some-1.2.iso" ]
  [ -z "$(anfs_iso_get some url)" ]
  [ -f "$T/some-1.2.iso" ]
  run iso list
  [[ "$output" == "some"$'\t'*$'\t'"some-1.2.iso"$'\t'"present"$'\t'* ]]
  # what a machine's media: [some] asks for
  run anfs_iso_fetch_id some
  [ "$output" = "$STORE/some-1.2.iso" ]
  [ ! -s "$CURL_LOG" ]

  # the id defaults to the file's name without its extension; a wrong --sha256 adds nothing
  run iso add "$T/some-1.2.iso"
  [ "$status" -eq 0 ]
  [ "$(anfs_iso_ids | paste -sd' ' -)" = "some some-1.2" ]
  echo other > "$T/other.iso"
  run iso add "$T/other.iso" --sha256 "$SHA"
  [ "$status" -eq 1 ]
  [ ! -e "$STORE/other.iso" ]
  ! anfs_iso_known other
}

@test "iso pull: downloads and records the sum; a second run does nothing" {
  catalogue
  run iso pull debian pve
  [ "$status" -eq 0 ]
  [ "$(cat "$STORE/debian.iso")" = "debian content" ]
  [ "$(cat "$STORE/debian.iso.sha256")" = "$SHA" ]
  [ -f "$STORE/proxmox.iso" ]
  local n
  n=$(wc -l < "$CURL_LOG")
  run iso get debian pve
  [ "$status" -eq 0 ]
  [[ "$output" == *"debian: ~/.cache/anfs/isos/debian.iso"* ]]
  [ "$(wc -l < "$CURL_LOG")" -eq "$n" ]
  run iso pull -f debian
  [ "$(wc -l < "$CURL_LOG")" -eq $((n + 1)) ]
  ANFS_JSON=true run iso pull debian
  [ "$output" = "{\"id\":\"debian\",\"file\":\"$STORE/debian.iso\"}" ]
}

@test "iso pull: a wrong pinned sum fails and leaves no file; an unknown id downloads nothing" {
  catalogue
  printf -- '- id: bad\n  url: https://x/pve.iso\n  checksum: %064d\n' 0 > "$HOME/.config/anfs/isos.yml"
  run iso pull bad
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$STORE/pve.iso" ]
  [ ! -e "$STORE/pve.iso.part" ]

  : > "$CURL_LOG"
  run iso pull debian nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"no ISO 'nope' in the catalogue"* ]]
  [ ! -s "$CURL_LOG" ]
}

@test "iso remove deletes the file and keeps the entry; --entry is for a hand-made one only" {
  catalogue
  iso pull debian
  run iso remove debian
  [ "$status" -eq 0 ]
  [ ! -e "$STORE/debian.iso" ]
  [ ! -e "$STORE/debian.iso.sha256" ]
  anfs_iso_known debian
  run iso remove debian
  [ "$status" -eq 0 ]
  [[ "$output" == *"debian: not in the store"* ]]

  # a source's entry: refused, and nothing is deleted
  iso pull debian
  local before
  before=$(cat "$T/sources/hi/isos/isos.yml")
  run iso remove --entry debian
  [ "$status" -eq 1 ]
  [[ "$output" == *"a source's catalogue is changed in the source"* ]]
  [ -f "$STORE/debian.iso" ]
  [ "$(cat "$T/sources/hi/isos/isos.yml")" = "$before" ]

  # one of your own goes, and the source's entry of that id is the catalogue's again
  iso add https://x/mine/debian.iso -f
  iso add https://x/extra.iso
  [ "$(anfs_iso_get debian url)" = "https://x/mine/debian.iso" ]
  run iso rm --entry debian
  [ "$status" -eq 0 ]
  [ ! -e "$STORE/debian.iso" ]
  [ "$(anfs_iso_get debian url)" = "https://x/debian.iso" ]
  anfs_iso_known extra
  run iso remove nope
  [ "$status" -eq 1 ]
}

@test "iso prune removes only the files no entry names, and nothing without -y or a terminal" {
  catalogue
  iso pull debian
  echo stray > "$STORE/stray.iso"; echo sum > "$STORE/stray.iso.sha256"; echo half > "$STORE/gone.iso.part"
  run iso prune </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"stray.iso"* ]]
  [[ "$output" == *"pass -y"* ]]
  [ -f "$STORE/stray.iso" ] && [ -f "$STORE/gone.iso.part" ]
  run iso prune -y
  [ "$status" -eq 0 ]
  [ ! -e "$STORE/stray.iso" ] && [ ! -e "$STORE/stray.iso.sha256" ] && [ ! -e "$STORE/gone.iso.part" ]
  [ -f "$STORE/debian.iso" ] && [ -f "$STORE/debian.iso.sha256" ]
  run iso prune </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to prune"* ]]
}

@test "iso prune: a catalogue that cannot be read, or no entry at all, deletes nothing" {
  catalogue
  iso pull debian
  echo pve > "$STORE/proxmox.iso"; echo stray > "$STORE/stray.iso"
  local good
  good=$(cat "$T/sources/hi/isos/isos.yml")

  # an unterminated quote, then a map where the list should be: its files are not strays
  local bad
  for bad in '- id: "debian' $'isos:\n  - id: debian\n    url: https://x/debian.iso' '- name: no id'; do
    printf '%s\n' "$bad" > "$T/sources/hi/isos/isos.yml"
    run iso prune -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"sources/hi/isos/isos.yml is not a list of entries"* ]]
    [[ "$output" == *"not pruning"* ]]
    [ -f "$STORE/debian.iso" ] && [ -f "$STORE/proxmox.iso" ] && [ -f "$STORE/stray.iso" ]
    run iso list --all
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a list of entries"* ]]
    [[ "$output" != *unlisted* ]]
    [[ "$output" == *old.iso* ]]
  done

  # no entries: an empty catalogue, then none
  printf '# nothing yet\n' > "$T/sources/hi/isos/isos.yml"
  rm "$T/sources/lo/isos/isos.yml"
  run iso list
  [ "$status" -eq 0 ]
  run iso prune -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"the catalogue has no entries"* ]]
  rm "$T/sources/hi/isos/isos.yml"
  run iso prune -y
  [ "$status" -eq 1 ]
  [ -f "$STORE/debian.iso" ] && [ -f "$STORE/proxmox.iso" ] && [ -f "$STORE/stray.iso" ]

  # readable again: only the stray goes, and --json answers with one object
  printf '%s\n' "$good" > "$T/sources/hi/isos/isos.yml"
  [ "$(ANFS_JSON=true iso prune -y 2>/dev/null)" = '{"deleted":"1"}' ]
  [ -f "$STORE/debian.iso" ] && [ -f "$STORE/proxmox.iso" ] && [ ! -e "$STORE/stray.iso" ]
}

@test "a filename is a name in the store: one with a / is never read, written or deleted" {
  echo keep > "$HOME/victim.txt"
  mkdir -p "$STORE"
  echo x > "$WEB/victim.txt"
  cat > "$T/sources/hi/isos/isos.yml" <<'EOF'
- id: evil
  filename: ../../../victim.txt
- id: evil-url
  url: https://x/victim.txt
  filename: ../../../victim.txt
- id: nofile
  name: neither a url nor a filename
EOF
  local id
  for id in evil evil-url nofile; do
    run iso remove -y "$id"
    [ "$status" -eq 1 ]
    [[ "$output" == *"names no file in the store"* ]]
    run iso path "$id"
    [ "$status" -eq 1 ]
    run iso show "$id"
    [ "$status" -eq 1 ]
    run iso pull -f "$id"
    [ "$status" -eq 1 ]
  done
  [ "$(cat "$HOME/victim.txt")" = keep ]
  [ ! -s "$CURL_LOG" ]
  run anfs_iso_fetch --name ../x.iso https://x/debian.iso
  [ "$status" -eq 1 ]
  [ ! -e "$HOME/.cache/anfs/x.iso" ]
  run iso list
  [[ "${lines[0]}" == "evil"$'\t'*$'\t'"invalid"$'\t'"-" ]]
  [[ "${lines[2]}" == "nofile"$'\t'*$'\t'"-"$'\t'"invalid"$'\t'"-" ]]
}

@test "iso remove asks before a file with no url goes: it cannot be pulled again" {
  echo mine > "$T/mine.iso"
  iso add "$T/mine.iso"
  iso add https://x/debian.iso
  iso pull debian
  run iso remove mine debian </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"mine.iso"*"no url"* ]]
  [[ "$output" == *"pass -y"* ]]
  [ -f "$STORE/mine.iso" ] && [ -f "$STORE/debian.iso" ]
  # one with a url is not asked about
  run iso remove debian </dev/null
  [ "$status" -eq 0 ]
  run iso remove -y mine
  [ "$status" -eq 0 ]
  [ ! -e "$STORE/mine.iso" ]
}

@test "iso show and path: the entry and its file; an unknown id is 1" {
  catalogue
  iso pull debian
  run iso show debian
  [ "$status" -eq 0 ]
  [[ "$output" == *"catalog:       ~/.local/share/anfs/sources/hi/isos/isos.yml"* ]]
  [[ "$output" == *"file:          ~/.cache/anfs/isos/debian.iso"* ]]
  [[ "$output" == *"state:         present"* ]]
  [[ "$output" == *"sha256:        $SHA"* ]]
  run iso show pve
  [ "$(grep -c '^url:' <<< "$output")" -eq 2 ]
  [[ "$output" == *"sha256:        not recorded"* ]]
  [ "$(iso path pve)" = "$STORE/proxmox.iso" ]
  run iso path nope
  [ "$status" -eq 1 ]
  run iso show nope
  [ "$status" -eq 1 ]
}

@test "anfs iso and pmm iso are the same commands: the same rows, the same help" {
  catalogue
  iso pull debian
  local rows
  rows=$(iso list --all)
  run "$ANFS" iso list --all
  [ "$status" -eq 0 ]
  [ "$output" = "$rows" ]
  run "$PMM" iso list --all
  [ "$status" -eq 0 ]
  [ "$output" = "$rows" ]
  # ventoy is stack's: compared when a checkout is named (its own suite compares it with anfs)
  if [[ -n "${VENTOY:-}" ]]; then
    run "$VENTOY" iso list --all
    [ "$output" = "$rows" ]
  fi
  [ "$("$ANFS" iso --help | sed 's/anfs iso/TOOL iso/')" = "$("$PMM" iso --help | sed 's/pmm iso/TOOL iso/')" ]
  run "$PMM" iso pull
  [ "$status" -eq 64 ]
  [[ "$output" == *"usage: pmm iso pull [-f] <iso>..."* ]]
  run "$PMM" image prune --isos
  [ "$status" -eq 64 ]
}

@test "iso pull <TAB>: the ids, inside a tab press's budget (registry.bats)" {
  catalogue
  printf -- '- id: mine\n  url: https://x/mine.iso\n' > "$HOME/.config/anfs/isos.yml"
  run "$ANFS" __complete iso pull ""
  [ "$output" = "mine"$'\n'"debian"$'\n'"pve"$'\n'"old" ]
  run "$PMM" __complete iso rm ""
  [ "$output" = "mine"$'\n'"debian"$'\n'"pve"$'\n'"old" ]
  # an indented list, a quoted id, a comment after it
  printf -- '  - id: "ind"   # the one\n    url: https://x/ind.iso\n  - name: later\n    id: late\n' > "$HOME/.config/anfs/isos.yml"
  run "$ANFS" __complete iso pull ""
  [ "${lines[0]}" = ind ]
  [ "${#lines[@]}" -eq 4 ]
  [[ -n "${EPOCHREALTIME:-}" ]] || skip "no microsecond clock in this bash"
  local start end best=999999 i
  for i in 1 2 3; do
    start="${EPOCHREALTIME/[.,]/}"
    "$ANFS" __complete iso pull "" >/dev/null
    end="${EPOCHREALTIME/[.,]/}"
    (( end - start >= best )) || best=$(( end - start ))
  done
  echo "best of three: $(( best / 1000 )) ms"
  (( best / 1000 < 100 ))
}
