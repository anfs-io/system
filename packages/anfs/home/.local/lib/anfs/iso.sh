#!/usr/bin/env bash
# anfs: install ISOs — one store, one downloader, one catalogue
#
# pmm builds images from ISOs and boots machines from them, ventoy puts them on a stick. They
# are the same files, so they are kept once ($ANFS_ISO_HOME), fetched one way, and named in one
# catalogue that the sources layer like everything else.
#
# THE STORE
#   $ANFS_ISO_HOME (default $ANFS_CACHE_HOME/isos: everything in it can be downloaded again).
#   A file is named by its URL's last part unless a name is given. A file whose sum was checked
#   has it recorded beside it (<file>.sha256), so it is hashed once.
#
# FETCHING
#   anfs_iso_fetch [--sha256 HEX] [--checksum-url URL] [--name FILE] [--force] <url>...
#       Print the path of the ISO in the store, downloading it when it is not there (or its sum
#       no longer matches). The URLs are tried in order: publishers move a release from current/
#       to an archive. --sha256 pins the content; --checksum-url is the publisher's checksum file,
#       read for the line of this file's name; with neither the download is not verified, and a
#       warning says so. Progress and messages go to stderr. Returns 1 when nothing could be
#       downloaded and verified.
#   anfs_iso_checksum <checksum url> <file name>     the sha256 a publisher's file gives a name:
#       "hash  file", "hash *file", BSD "SHA256 (file) = hash", or a file holding only the hash
#   anfs_iso_sha256 <file>                           its sha256, hex
#
# THE CATALOGUE
#   isos.yml files, the highest priority first: $ANFS_CONFIG_HOME/isos.yml (hand-made), then
#   isos/isos.yml in each source, in source order. Each is a list:
#     - id: debian-13
#       name: Debian 13.7 netinst
#       architecture: amd64
#       url: https://...            a URL, or a list tried in order
#       checksum_url: https://...   or  checksum: <sha256>   (a pinned sum)
#       filename: debian-13.iso     optional; default the URL's last part
#   An id in a higher-priority file replaces the same id below it.
#
#   anfs_iso_catalogs              the files that exist, in priority order
#   anfs_iso_ids                   every id, once
#   anfs_iso_get <id> <field>      a field ("" when unset; url: one per line)
#   anfs_iso_known <id>            true when the catalogue has it
#   anfs_iso_file <id>             where its file is in the store, there or not
#   anfs_iso_fetch_id [--force] <id>    anfs_iso_fetch for a catalogue entry
#
# Requires paths.sh, log.sh and sources.sh (after anfs_gitsrc_env); the catalogue needs yq.
# Functions only; written for the bash floor (5.2, see bash.sh).

: "${ANFS_ISO_HOME:=$ANFS_CACHE_HOME/isos}"
ANFS_ISO_LOCAL_CATALOG="$ANFS_CONFIG_HOME/isos.yml"

anfs_iso_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

anfs_iso_checksum() {
  local url="$1" file="$2" body
  body=$(curl -fsSL "$url") || { anfs_warn "could not fetch checksums from $url"; return 1; }
  printf '%s\n' "$body" | tr -d '\r' | awk -v file="$file" '
    function is_hash(s) { return length(s) == 64 && s !~ /[^0-9a-fA-F]/ }
    is_hash($1) {
      hashes++
      name = $2; sub(/^\*/, "", name)
      if (name == file) { print tolower($1); found = 1; exit }
      if (NF == 1) bare = $1
    }
    index($0, "SHA256 (") == 1 {
      rest = substr($0, 9); p = index(rest, ") = ")
      if (p && substr(rest, 1, p - 1) == file) { print tolower(substr(rest, p + 4)); found = 1; exit }
    }
    END { if (!found && hashes == 1 && bare != "") print tolower(bare) }'
}

# True when <file> is known to hash to <sha>: its recorded sum matches, or hashing it now does
_anfs_iso_verified() {
  local file="$1" sha="$2"
  if [[ -f "$file.sha256" && "$(cat "$file.sha256")" == "$sha" && "$file.sha256" -nt "$file" ]]; then
    return 0
  fi
  echo "Verifying $(basename "$file")" >&2
  [[ "$(anfs_iso_sha256 "$file")" == "$sha" ]] || return 1
  echo "$sha" > "$file.sha256"
}

# Download <url> to <part>, resuming what is there. A server that cannot resume starts over; a
# .part that is already whole (416) is left for its sum to decide.
_anfs_iso_download() {
  local url="$1" part="$2" code
  code=$(curl -fL --retry 3 -C - -# -o "$part" -w '%{http_code}' "$url") && return 0
  case "$code" in
    416) return 0 ;;
    200|206)
      rm -f "$part"
      curl -fL --retry 3 -# -o "$part" "$url" && return 0
      ;;
  esac
  anfs_warn "download failed (HTTP ${code:-none}): $url"
  return 1
}

anfs_iso_fetch() {
  local sha="" sum_url="" name="" force=false url file part want
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sha256) sha=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); sha="${sha#sha256:}"; shift 2 ;;
      --checksum-url) sum_url="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --force) force=true; shift ;;
      *) break ;;
    esac
  done
  [[ $# -gt 0 ]] || { anfs_warn "anfs_iso_fetch: no url"; return 1; }
  mkdir -p "$ANFS_ISO_HOME"

  for url in "$@"; do
    [[ -n "$url" ]] || continue
    file="$ANFS_ISO_HOME/${name:-$(basename "${url%%\?*}")}"
    part="$file.part"
    if [[ -f "$file" ]] && ! $force; then
      # What is there is taken as it is unless a pinned sum says otherwise
      if [[ -z "$sha" ]] || _anfs_iso_verified "$file" "$sha"; then
        echo "$file"
        return 0
      fi
      anfs_warn "$(basename "$file") no longer matches its sha256; downloading it again"
    fi
    ! $force || rm -f "$part"

    want="$sha"
    if [[ -z "$want" && -n "$sum_url" ]]; then
      want=$(anfs_iso_checksum "$sum_url" "$(basename "$file")") || want=""
      [[ -n "$want" ]] || anfs_warn "no sha256 for $(basename "$file") in $sum_url"
    fi

    echo "Downloading $url" >&2
    _anfs_iso_download "$url" "$part" >&2 || continue
    if [[ -n "$want" ]]; then
      if [[ "$(anfs_iso_sha256 "$part")" != "$want" ]]; then
        anfs_warn "checksum mismatch for $url; deleting the download"
        rm -f "$part"
        continue
      fi
      mv "$part" "$file"
      echo "$want" > "$file.sha256"
    else
      anfs_warn "$(basename "$file"): no checksum to verify it against"
      mv "$part" "$file"
      rm -f "$file.sha256"
    fi
    echo "$file"
    return 0
  done
  return 1
}

# --- the catalogue --------------------------------------------------------------------------

anfs_iso_catalogs() {
  local i f
  [[ ! -f "$ANFS_ISO_LOCAL_CATALOG" ]] || echo "$ANFS_ISO_LOCAL_CATALOG"
  gitsrc_collect
  for i in "${!GITSRC_NAMES[@]}"; do
    f="$(gitsrc_dir "${GITSRC_NAMES[$i]}")/isos/isos.yml"
    [[ ! -f "$f" ]] || echo "$f"
  done
}

# The catalogue file that defines <id>: the first, in priority order
_anfs_iso_catalog_of() {
  local f
  while IFS= read -r f; do
    if ID="$1" yq -e '.[] | select(.id == strenv(ID))' "$f" >/dev/null 2>&1; then
      echo "$f"
      return 0
    fi
  done < <(anfs_iso_catalogs)
  return 1
}

anfs_iso_known() { _anfs_iso_catalog_of "$1" >/dev/null; }

anfs_iso_ids() {
  local f id
  local -A seen=()
  while IFS= read -r f; do
    while IFS= read -r id; do
      [[ -n "$id" && -z "${seen[$id]:-}" ]] || continue
      seen[$id]=1
      echo "$id"
    done < <(yq -r '.[].id' "$f" 2>/dev/null)
  done < <(anfs_iso_catalogs)
}

anfs_iso_get() {
  local f
  f=$(_anfs_iso_catalog_of "$1") || return 0
  ID="$1" yq -r ".[] | select(.id == strenv(ID)) | .$2 | select(. != null) | (select(tag == \"!!seq\") | .[]) // ." "$f" 2>/dev/null || true
}

# The file name of a catalogue entry: its filename, else its first URL's last part
_anfs_iso_name() {
  local name url
  name=$(anfs_iso_get "$1" filename)
  if [[ -z "$name" ]]; then
    url=$(anfs_iso_get "$1" url | head -n1)
    name=$(basename "${url%%\?*}")
  fi
  echo "$name"
}

anfs_iso_file() { echo "$ANFS_ISO_HOME/$(_anfs_iso_name "$1")"; }

anfs_iso_fetch_id() {
  local force=() id sum sum_url
  local -a urls=() args=()
  [[ "$1" != --force ]] || { force=(--force); shift; }
  id="$1"
  anfs_iso_known "$id" || { anfs_warn "no ISO '$id' in the catalogue"; return 1; }
  mapfile -t urls < <(anfs_iso_get "$id" url)
  [[ ${#urls[@]} -gt 0 && -n "${urls[0]}" ]] || { anfs_warn "$id: no url in the catalogue"; return 1; }
  sum=$(anfs_iso_get "$id" checksum)
  sum_url=$(anfs_iso_get "$id" checksum_url)
  args=(--name "$(_anfs_iso_name "$id")")
  [[ -z "$sum" ]] || args+=(--sha256 "$sum")
  [[ -z "$sum_url" ]] || args+=(--checksum-url "$sum_url")
  anfs_iso_fetch "${force[@]}" "${args[@]}" "${urls[@]}"
}
