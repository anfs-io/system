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
#   An id in a higher-priority file replaces the same id below it. A file name is a name in the
#   store: one with a / in it (or none at all) is refused wherever it would be read or written.
#
#   anfs_iso_catalogs              the files that exist, in priority order
#   anfs_iso_ids                   every id, once
#   anfs_iso_get <id> <field>      a field ("" when unset; url: one per line)
#   anfs_iso_known <id>            true when the catalogue has it
#   anfs_iso_file <id>             where its file is in the store, there or not (1: no usable name)
#   anfs_iso_bad_catalogs          the files that are not a list of entries with an id (yq cannot
#                                  read them, or they are a map). Read as empty by the rest, which
#                                  is why `iso list` reports them and `iso prune` refuses to run
#   anfs_iso_fetch_id [--force] <id>    anfs_iso_fetch for a catalogue entry. One with no url (a
#                                       file `iso add` copied in) is its file, while it is there
#
# THE COMMANDS
#   anfs_iso_cli                   declare the `iso` group (lib/anfs/cli.sh). A tool that uses ISOs
#                                  calls it beside its own declarations, and has
#     <tool> iso list [--all]      the catalogue: ID NAME ARCH FILE STATE SIZE
#     <tool> iso show <id>         the entry, the catalogue file that defines it, its file and sum
#     <tool> iso pull [-f] <id>... download and verify into the store (alias: get)
#     <tool> iso add <url|file>    an entry of your own, in $ANFS_CONFIG_HOME/isos.yml
#     <tool> iso remove <id>...    delete the file; --entry also drops an entry of your own. It
#                                  asks (-y) for a file with no url to pull it from again
#     <tool> iso path <id>         the file's path in the store, there or not
#     <tool> iso prune [-y]        delete the files in the store no entry names. Refused while a
#                                  catalogue cannot be read, or when there is no entry at all
#   They are written here once (cmd_iso_*, complete_iso), so anfs, pmm and ventoy cannot differ.
#
# Requires paths.sh, log.sh and sources.sh (after anfs_gitsrc_env); the catalogue needs yq, the
# commands cli.sh and table.sh.
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

# A file name in the store: not empty, no directory part. A catalogue's `filename` is joined to
# the store's path, and `iso remove` deletes what that names.
_anfs_iso_name_ok() {
  [[ -n "$1" && "$1" != */* && "$1" != . && "$1" != .. ]]
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
  [[ -z "$name" ]] || _anfs_iso_name_ok "$name" || { anfs_warn "'$name' is not a file name in the store"; return 1; }
  mkdir -p "$ANFS_ISO_HOME"

  for url in "$@"; do
    [[ -n "$url" ]] || continue
    file="${name:-$(basename "${url%%\?*}")}"
    _anfs_iso_name_ok "$file" || { anfs_warn "$url names no file"; continue; }
    file="$ANFS_ISO_HOME/$file"
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

anfs_iso_bad_catalogs() {
  local f
  while IFS= read -r f; do
    # Empty, or comments only: a catalogue with no entries
    grep -qvE '^[[:space:]]*(#.*|---)?$' "$f" 2>/dev/null || continue
    yq -e 'tag == "!!seq" and all_c(tag == "!!map" and has("id"))' "$f" >/dev/null 2>&1 || echo "$f"
  done < <(anfs_iso_catalogs)
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
    url="${url%%\?*}"
    name="${url##*/}"
  fi
  echo "$name"
}

anfs_iso_file() {
  local name
  name=$(_anfs_iso_name "$1")
  if ! _anfs_iso_name_ok "$name"; then
    anfs_warn "$1: its entry names no file in the store (filename: '$name'; a name, with no /)"
    return 1
  fi
  echo "$ANFS_ISO_HOME/$name"
}

anfs_iso_fetch_id() {
  local force=() id sum sum_url file
  local -a urls=() args=()
  [[ "$1" != --force ]] || { force=(--force); shift; }
  id="$1"
  anfs_iso_known "$id" || { anfs_warn "no ISO '$id' in the catalogue"; return 1; }
  mapfile -t urls < <(anfs_iso_get "$id" url)
  sum=$(anfs_iso_get "$id" checksum)
  if [[ ${#urls[@]} -eq 0 || -z "${urls[0]}" ]]; then
    # An entry `iso add` made from a file: there is nowhere to download it from
    file=$(anfs_iso_file "$id") || return 1
    sum="${sum,,}"
    if [[ -f "$file" ]] && { [[ -z "$sum" ]] || _anfs_iso_verified "$file" "${sum#sha256:}"; }; then
      echo "$file"
      return 0
    fi
    anfs_warn "$id: no url in the catalogue, and its file is not in the store"
    return 1
  fi
  sum_url=$(anfs_iso_get "$id" checksum_url)
  file=$(anfs_iso_file "$id") || return 1
  args=(--name "${file##*/}")
  [[ -z "$sum" ]] || args+=(--sha256 "$sum")
  [[ -z "$sum_url" ]] || args+=(--checksum-url "$sum_url")
  anfs_iso_fetch "${force[@]}" "${args[@]}" "${urls[@]}"
}

# --- the iso command ------------------------------------------------------------------------
# One group for every tool that uses ISOs: the tool calls anfs_iso_cli beside its own
# declarations (after cli.sh and table.sh), and the commands below are its `iso` commands.

anfs_iso_cli() {
  cli_group iso "Install ISOs: the catalogue, and the store every tool shares"
  cli_cmd "iso list" "The catalogue: ID NAME ARCH FILE STATE SIZE. present: in the store;
unverified: there, with no recorded sum; missing" --alias ls \
    --opt "--all: Also the files in the store no entry names (unlisted)"
  cli_cmd "iso show" "The entry, the catalogue file that defines it, its file and its sum" --arg "iso"
  cli_cmd "iso pull" "Download into the store and verify; a file that is there is left" --alias get \
    --opt "-f --force: Download again" --arg "iso..."
  cli_cmd "iso add" "An entry of your own (~/.config/anfs/isos.yml, first in priority). A URL is
recorded, and fetched by pull; a file is copied into the store and pinned by
its sha256. The id is the file's name without its extension unless given" \
    --opt "--id ID: Its id" --opt "--name TEXT: A description" --opt "--arch ARCH: amd64 or arm64" \
    --opt "--sha256 HEX: Pin the content" --opt "--checksum-url URL: The publisher's checksum file" \
    --opt "-f --force: Replace the entry of that id" --arg "url|file"
  cli_cmd "iso remove" "Delete ISOs from the store. The entry stays: pull fetches it again when it has
a url. One with none (a file iso add copied in) is asked about first" --alias rm \
    --opt "--entry: Drop the entry too (one of your own; never a source's)" \
    --opt "-y --yes: Do not ask" --arg "iso..."
  cli_cmd "iso path" "Print the file's path in the store, there or not" --arg "iso"
  cli_cmd "iso prune" "Delete the files in the store no catalogue entry names. Refused while a
catalogue cannot be read, or when there are no entries at all" --opt "-y --yes: Do not ask"
}

_anfs_iso_need() {
  anfs_require yq "https://github.com/mikefarah/yq, which ppm installs"
}

_anfs_iso_unknown() {
  anfs_die "no ISO '$1' in the catalogue (list them with: $CLI_TOOL iso list)"
}

# Warn about each catalogue file that cannot be read; true when there is one
_anfs_iso_warn_bad() {
  local f bad=1
  while IFS= read -r f; do
    anfs_warn "$(anfs_display "$f") is not a list of entries with an id (see: yq . $(anfs_display "$f")); nothing in it is read"
    bad=0
  done < <(anfs_iso_bad_catalogs)
  return "$bad"
}

# The size of a file in bytes ("" when it is not there)
_anfs_iso_bytes() {
  [[ ! -f "$1" ]] || { wc -c < "$1" | tr -d ' '; }
}

# Every entry that counts (an id's first, in priority order), one row each: id, name,
# architecture, file name, checksum, checksum_url, the catalogue file. One yq per file.
_anfs_iso_entries() {
  local f id name arch fname url sum sum_url
  local -A seen=()
  while IFS= read -r f; do
    while IFS="$ANFS_US" read -r id name arch fname url sum sum_url; do
      [[ -n "$id" && -z "${seen[$id]:-}" ]] || continue
      seen[$id]=1
      if [[ -z "$fname" ]]; then
        fname="${url%%\?*}"
        fname="${fname##*/}"
      fi
      anfs_row "$id" "$name" "$arch" "$fname" "$sum" "$sum_url" "$f"
    done < <(SEP="$ANFS_US" yq -r '.[] | [.id, .name // "", .architecture // "", .filename // "",
      ((.url | select(tag == "!!seq") | .[0]) // .url // ""), .checksum // "", .checksum_url // ""]
      | join(strenv(SEP))' "$f" 2>/dev/null)
  done < <(anfs_iso_catalogs)
}

# present, missing, or unverified: there, with no recorded sum
_anfs_iso_state() {
  if [[ ! -f "$1" ]]; then echo missing
  elif [[ -f "$1.sha256" ]]; then echo present
  else echo unverified
  fi
}

_anfs_iso_size() {
  [[ ! -f "$1" ]] || ls -lhL "$1" | awk '{ print $5 }'
}

# The files in the store no entry names, their .sha256 and .part with them; one path per line
_anfs_iso_strays() {
  local id name arch fname rest f base
  local -A named=()
  while IFS="$ANFS_US" read -r id name arch fname rest; do
    [[ -z "$fname" ]] || named[$fname]=1
  done < <(_anfs_iso_entries)
  for f in "$ANFS_ISO_HOME"/*; do
    [[ -f "$f" ]] || continue
    base="${f##*/}"
    base="${base%.sha256}"
    base="${base%.part}"
    [[ -n "${named[$base]:-}" ]] || echo "$f"
  done
}

cmd_iso_list() {
  local id name arch fname sum sum_url catalog f state size bad=false
  _anfs_iso_need
  # Before the rows: what an unreadable catalogue names would be listed as unlisted
  ! _anfs_iso_warn_bad || bad=true
  size=_anfs_iso_size
  ! anfs_json_on || size=_anfs_iso_bytes
  {
    while IFS="$ANFS_US" read -r id name arch fname sum sum_url catalog; do
      f="$ANFS_ISO_HOME/$fname"
      # An entry with no file name, or one that is not a name in the store, has no file
      if _anfs_iso_name_ok "$fname"; then
        anfs_row "$id" "$name" "$arch" "$fname" "$(_anfs_iso_state "$f")" "$($size "$f")" "$catalog"
      else
        anfs_row "$id" "$name" "$arch" "$fname" invalid "" "$catalog"
      fi
    done < <(_anfs_iso_entries)
    if ${CLI_OPT[all]:-false} && ! $bad; then
      while IFS= read -r f; do
        [[ "$f" != *.sha256 ]] || continue
        anfs_row "" "" "" "${f##*/}" unlisted "$($size "$f")" ""
      done < <(_anfs_iso_strays)
    fi
  } | anfs_table "ID NAME ARCH FILE STATE SIZE" "id name architecture file state size catalog"
  [[ -n "$(anfs_iso_catalogs)" ]] || anfs_json_on ||
    anfs_warn "no ISO catalogue: isos/isos.yml in a source, or $(anfs_display "$ANFS_ISO_LOCAL_CATALOG") ($CLI_TOOL iso add)"
  ! $bad
}

cmd_iso_show() {
  local id="$1" catalog file field value recorded="" size
  _anfs_iso_need
  catalog=$(_anfs_iso_catalog_of "$id") || _anfs_iso_unknown "$id"
  file=$(anfs_iso_file "$id") || return 1
  [[ ! -f "$file.sha256" ]] || recorded=$(cat "$file.sha256")
  size=$(_anfs_iso_size "$file")
  echo "id:            $id"
  for field in name architecture url checksum checksum_url; do
    while IFS= read -r value; do
      [[ -z "$value" ]] || printf '%-14s %s\n' "$field:" "$value"
    done < <(anfs_iso_get "$id" "$field")
  done
  echo "catalog:       $(anfs_display "$catalog")"
  echo "file:          $(anfs_display "$file")"
  echo "state:         $(_anfs_iso_state "$file")${size:+ ($size)}"
  echo "sha256:        ${recorded:-not recorded}"
}

cmd_iso_pull() {
  local id file rc=0
  local -a force=()
  _anfs_iso_need
  ! ${CLI_OPT[force]:-false} || force=(--force)
  # Every id is checked before anything is downloaded
  for id in "$@"; do
    anfs_iso_known "$id" || _anfs_iso_unknown "$id"
  done
  for id in "$@"; do
    if file=$(anfs_iso_fetch_id "${force[@]}" "$id"); then
      anfs_json_on || anfs_info "$id: $(anfs_display "$file") ($(_anfs_iso_size "$file"))"
      anfs_result id "$id" file "$file"
    else
      anfs_warn "$id: could not be downloaded and verified"
      rc=1
    fi
  done
  return "$rc"
}

# Write $ANFS_ISO_LOCAL_CATALOG through <yq args...>, in place: the file may be a link into a
# customization repo, which a rename would replace
_anfs_iso_catalog_write() {
  local out
  out=$(yq "$@") || anfs_die "could not write $(anfs_display "$ANFS_ISO_LOCAL_CATALOG")"
  mkdir -p "$(dirname "$ANFS_ISO_LOCAL_CATALOG")"
  printf '%s\n' "$out" > "$ANFS_ISO_LOCAL_CATALOG"
}

cmd_iso_add() {
  local src="$1" id="${CLI_OPT[id]:-}" sha="${CLI_OPT[sha256]:-}" sum_url="${CLI_OPT[checksum-url]:-}"
  local force=${CLI_OPT[force]:-false} url="" fname file="" got catalog
  local entry='{"id": strenv(ID), "name": strenv(NAME), "architecture": strenv(ARCH), "url": strenv(URL),
    "filename": strenv(FNAME), "checksum": strenv(SUM), "checksum_url": strenv(SUM_URL)}
    | with_entries(select(.value != ""))'
  _anfs_iso_need
  [[ -z "$sha" || -z "$sum_url" ]] || cli_usage_err "--sha256 or --checksum-url, not both"
  sha="${sha,,}"
  sha="${sha#sha256:}"
  [[ -z "$sha" || "$sha" =~ ^[0-9a-f]{64}$ ]] || cli_usage_err "--sha256 takes 64 hex digits"

  if [[ "$src" == *://* ]]; then
    url="$src"
    fname="${src%%\?*}"
    fname="${fname##*/}"
    [[ -n "$fname" ]] || anfs_die "$src names no file"
  else
    [[ -f "$src" ]] || anfs_die "$src is not a URL or a file"
    [[ -z "$sum_url" ]] || cli_usage_err "--checksum-url is for a URL; a file is hashed"
    fname="${src##*/}"
    file="$ANFS_ISO_HOME/$fname"
  fi
  [[ -n "$id" ]] || id="${fname%.*}"
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || cli_usage_err "'$id' is not an id (letters, digits, . _ -); give one with --id"
  if catalog=$(_anfs_iso_catalog_of "$id") && ! $force; then
    anfs_fail 73 "the catalogue has '$id' already ($(anfs_display "$catalog")); -f replaces it with yours"
  fi

  if [[ -n "$file" ]]; then
    got=$(anfs_iso_sha256 "$src")
    [[ -z "$sha" || "$sha" == "$got" ]] || anfs_die "$src: its sha256 is $got, not $sha"
    if [[ ! "$src" -ef "$file" ]]; then
      if [[ -f "$file" ]] && ! $force && [[ "$(anfs_iso_sha256 "$file")" != "$got" ]]; then
        anfs_fail 73 "the store has another $fname already; -f replaces it"
      fi
      mkdir -p "$ANFS_ISO_HOME"
      cp "$src" "$file"
    fi
    echo "$got" > "$file.sha256"
    sha="$got"
  else
    # default name: the URL's last part, as the downloader's
    fname=""
  fi

  export ID="$id" NAME="${CLI_OPT[name]:-}" ARCH="${CLI_OPT[arch]:-}" URL="$url" FNAME="$fname"
  export SUM="${sha:+sha256:$sha}" SUM_URL="$sum_url"
  if [[ -s "$ANFS_ISO_LOCAL_CATALOG" ]]; then
    _anfs_iso_catalog_write "(. // []) | del(.[] | select(.id == strenv(ID))) | . + [$entry]" "$ANFS_ISO_LOCAL_CATALOG"
  else
    _anfs_iso_catalog_write -n "[$entry]"
  fi
  if [[ -n "$file" ]]; then
    anfs_json_on || anfs_info "Added $id: $(anfs_display "$file"), sha256 $sha"
  else
    anfs_json_on || anfs_info "Added $id: $url (fetch it with: $CLI_TOOL iso pull $id)"
  fi
  anfs_result id "$id" file "$(anfs_iso_file "$id")" catalog "$ANFS_ISO_LOCAL_CATALOG"
}

cmd_iso_remove() {
  local entry=${CLI_OPT[entry]:-false} id catalog file
  local -a files=() lost=()
  _anfs_iso_need
  # Every id is checked before anything is deleted
  for id in "$@"; do
    catalog=$(_anfs_iso_catalog_of "$id") || _anfs_iso_unknown "$id"
    ! $entry || [[ "$catalog" == "$ANFS_ISO_LOCAL_CATALOG" ]] ||
      anfs_die "$id is defined in $(anfs_display "$catalog"): --entry drops an entry of $(anfs_display "$ANFS_ISO_LOCAL_CATALOG") only; a source's catalogue is changed in the source"
    file=$(anfs_iso_file "$id") || return 1
    files+=("$file")
    [[ ! -f "$file" || -n "$(anfs_iso_get "$id" url)" ]] || lost+=("${file##*/}")
  done
  [[ ${#lost[@]} -eq 0 ]] ||
    anfs_confirm "this deletes ${lost[*]} from $(anfs_display "$ANFS_ISO_HOME"): no url in the catalogue to pull it from again" "Delete?"
  for id in "$@"; do
    file="${files[0]}"
    files=("${files[@]:1}")
    if [[ -e "$file" || -e "$file.sha256" || -e "$file.part" ]]; then
      rm -f "$file" "$file.sha256" "$file.part"
      anfs_json_on || anfs_info "Deleted $(anfs_display "$file")"
    else
      anfs_json_on || anfs_info "$id: not in the store"
    fi
    if $entry; then
      ID="$id" _anfs_iso_catalog_write 'del(.[] | select(.id == strenv(ID)))' "$ANFS_ISO_LOCAL_CATALOG"
      anfs_json_on || anfs_info "Dropped the entry $id from $(anfs_display "$ANFS_ISO_LOCAL_CATALOG")"
    fi
    anfs_result id "$id" file "$file"
  done
}

cmd_iso_path() {
  _anfs_iso_need
  anfs_iso_known "$1" || _anfs_iso_unknown "$1"
  anfs_iso_file "$1" || return 1
}

cmd_iso_prune() {
  local f
  local -a strays=()
  _anfs_iso_need
  # A catalogue that cannot be read names nothing, and with no entries every file is a stray:
  # neither is a reason to empty the store
  ! _anfs_iso_warn_bad || anfs_die "not pruning: the files that catalogue names cannot be told from the strays"
  [[ -n "$(_anfs_iso_entries)" ]] ||
    anfs_die "not pruning: the catalogue has no entries, so every file in $(anfs_display "$ANFS_ISO_HOME") would go"
  mapfile -t strays < <(_anfs_iso_strays)
  if [[ ${#strays[@]} -eq 0 ]]; then
    anfs_json_on || anfs_info "Nothing to prune in $(anfs_display "$ANFS_ISO_HOME")"
    anfs_result deleted 0
    return 0
  fi
  for f in "${strays[@]}"; do
    printf '  %-6s %s\n' "$(_anfs_iso_size "$f")" "${f##*/}"
  done >&2
  anfs_confirm "this deletes ${#strays[@]} files no catalogue entry names from $(anfs_display "$ANFS_ISO_HOME")" "Delete them?"
  rm -f "${strays[@]}"
  anfs_json_on || anfs_info "Deleted ${#strays[@]} files"
  anfs_result deleted "${#strays[@]}"
}

# What cli.sh asks for on a tab press: the ids, read off the catalogue files' `- id:` lines. No
# yq, no source list (so every clone's catalogue, listed or not): a tab press has a budget
# (iso.bats). An entry whose id is not its first key is not offered.
complete_iso() {
  local f line
  local -A seen=()
  for f in "$ANFS_ISO_LOCAL_CATALOG" "$ANFS_SOURCES_HOME"/*/isos/isos.yml; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*-[[:space:]]+id:(.*)$ ]] || continue
      line="${BASH_REMATCH[1]%%[[:space:]]#*}"
      line="${line//[[:space:]\"\']/}"
      [[ -z "$line" || -n "${seen[$line]:-}" ]] || { seen[$line]=1; printf '%s\n' "$line"; }
    done < "$f"
  done
}
