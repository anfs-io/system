#!/usr/bin/env bash
# pim library: install ISOs — download, verify, cache. Sourced by ~/.local/bin/pim; functions only.
#
# An image declares iso.<arch>.url (a URL, or a list tried in order: Debian moves releases from
# current/ to the archive) and iso.<arch>.sha256. The file is cached by its URL's basename in
# $PIM_CACHE_HOME/isos; a verified file records its sum beside it, so it is hashed once.

iso_dir() { echo "$PIM_CACHE_HOME/isos"; }

# Print the cached ISO path for <id> <arch>, downloading and verifying it when needed
iso_fetch() {
  local id="$1" arch="$2" sha url file part ok=false
  sha=$(img_get "$id" ".iso.$arch.sha256" | tr '[:upper:]' '[:lower:]')
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "$id: iso.$arch.sha256 is missing or not a sha256"
  mkdir -p "$(iso_dir)"

  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    file="$(iso_dir)/$(basename "${url%%\?*}")"
    if [[ -f "$file" ]] && iso_verified "$file" "$sha"; then
      echo "$file"
      return 0
    fi
    part="$file.part"
    echo "Downloading $url" >&2
    if curl -fL --retry 3 -C - -o "$part" "$url" >&2; then
      if [[ "$(_sha256 < "$part")" == "$sha" ]]; then
        mv "$part" "$file"
        echo "$sha" > "$file.sha256"
        ok=true
        break
      fi
      warn "checksum mismatch for $url; deleting the download"
      rm -f "$part"
    else
      warn "download failed: $url"
    fi
  done < <(img_list "$id" ".iso.$arch.url")

  $ok || die "$id: no iso.$arch.url could be downloaded and verified"
  echo "$file"
}

# True when <file> is known to hash to <sha>: its recorded sum matches, or hashing it now does
iso_verified() {
  local file="$1" sha="$2"
  if [[ -f "$file.sha256" && "$(cat "$file.sha256")" == "$sha" && "$file.sha256" -nt "$file" ]]; then
    return 0
  fi
  echo "Verifying $(basename "$file")" >&2
  [[ "$(_sha256 < "$file")" == "$sha" ]] || return 1
  echo "$sha" > "$file.sha256"
}
