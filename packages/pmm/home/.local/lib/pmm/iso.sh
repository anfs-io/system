#!/usr/bin/env bash
# pmm library: the install ISOs images name. Sourced by ~/.local/bin/pmm; functions only.
#
# A root image names its ISO for each arch by id (iso.<arch>: debian-13-arm64): an entry in the
# ISO catalogue, which is anfs's with the store and the downloader (lib/anfs/iso.sh,
# $ANFS_ISO_HOME; ventoy and a machine's media use the same files). The catalogue resolves the id
# its own way ($ANFS_CONFIG_HOME/isos.yml, then the sources in order), so a person's catalogue can
# point an id at a mirror. The entry must pin a sha256, which is part of the build's cache key:
# a different file under the same id is a different build.

# The id <id>'s root image names for <arch>; nothing when it names none, or still has the inline
# map (url, sha256) that ids replaced
img_iso_id() {
  yq -r ".iso.$2 | select(tag == \"!!str\")" "$(img_yml "$(img_root "$1")")" 2>/dev/null || true
}

# The sha256 the catalogue pins for an ISO id, lowercase hex; nothing when it pins none
iso_sha256() {
  local sum
  sum=$(anfs_iso_get "$1" checksum)
  sum="${sum,,}"
  sum="${sum#sha256:}"
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] && echo "$sum"
  return 0
}

# Print the path of <id>'s ISO for <arch> in the store, downloading and verifying it when needed
iso_fetch() {
  local id="$1" arch="$2" iso file
  iso=$(img_iso_id "$id" "$arch")
  [[ -n "$iso" ]] || die "$id: iso.$arch names no ISO (pmm image validate $id)"
  [[ -n "$(iso_sha256 "$iso")" ]] || die "$id: the ISO '$iso' has no pinned sha256 in the catalogue (pmm iso show $iso)"
  file=$(anfs_iso_fetch_id "$iso") || die "$id: the ISO '$iso' could not be downloaded and verified"
  echo "$file"
}
