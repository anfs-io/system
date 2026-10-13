#!/usr/bin/env bash
# pim library: install ISOs. Sourced by ~/.local/bin/pim; functions only.
#
# An image declares iso.<arch>.url (a URL, or a list tried in order: Debian moves releases from
# current/ to the archive) and iso.<arch>.sha256. The store and the downloader are anfs's
# (lib/anfs/iso.sh, $ANFS_ISO_HOME): ventoy and pmm use the same files. The sha256 is the
# image's own, because it is part of the build's cache key.

iso_dir() { echo "$ANFS_ISO_HOME"; }

# ISOs pim downloaded before the store was shared ($PIM_CACHE_HOME/isos) move into it, once
_iso_adopt() {
  local old="$PIM_CACHE_HOME/isos" f
  [[ -d "$old" && ! -L "$old" && "$old" != "$ANFS_ISO_HOME" ]] || return 0
  mkdir -p "$ANFS_ISO_HOME"
  for f in "$old"/*.iso; do
    [[ -f "$f" ]] || continue
    [[ -e "$ANFS_ISO_HOME/$(basename "$f")" ]] || mv "$f" "$ANFS_ISO_HOME/"
    # the recorded sum is rewritten on first use: a moved file is verified again
  done
  rm -rf "$old"
}

# Print the cached ISO path for <id> <arch>, downloading and verifying it when needed
iso_fetch() {
  local id="$1" arch="$2" sha file
  local -a urls=()
  sha=$(img_get "$id" ".iso.$arch.sha256" | tr '[:upper:]' '[:lower:]')
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "$id: iso.$arch.sha256 is missing or not a sha256"
  _iso_adopt
  mapfile -t urls < <(img_list "$id" ".iso.$arch.url")
  file=$(anfs_iso_fetch --sha256 "$sha" "${urls[@]}") ||
    die "$id: no iso.$arch.url could be downloaded and verified"
  echo "$file"
}

# The files in the store that an image names: <url's last part>, one per line
iso_names() {
  local id arch url
  while IFS= read -r id; do
    for arch in arm64 amd64; do
      while IFS= read -r url; do
        [[ -z "$url" ]] || basename "${url%%\?*}"
      done < <(img_list "$id" ".iso.$arch.url")
    done
  done < <(all_ids) | LC_ALL=C sort -u
}
