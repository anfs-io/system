#!/usr/bin/env bash
# pmm library: the install ISOs images name. Sourced by ~/.local/bin/pmm; functions only.
#
# An image declares iso.<arch>.url (a URL, or a list tried in order: Debian moves releases from
# current/ to the archive) and iso.<arch>.sha256. The store and the downloader are anfs's
# (lib/anfs/iso.sh, $ANFS_ISO_HOME): ventoy and a machine's media use the same files. The sha256 is the
# image's own, because it is part of the build's cache key.

iso_dir() { echo "$ANFS_ISO_HOME"; }

# Print the cached ISO path for <id> <arch>, downloading and verifying it when needed
iso_fetch() {
  local id="$1" arch="$2" sha file
  local -a urls=()
  sha=$(img_get "$id" ".iso.$arch.sha256" | tr '[:upper:]' '[:lower:]')
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "$id: iso.$arch.sha256 is missing or not a sha256"
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
