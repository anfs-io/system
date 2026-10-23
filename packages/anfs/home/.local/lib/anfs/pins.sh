#!/usr/bin/env bash
# anfs: pinned release binaries. A package that runs a program from someone's GitHub releases
# (core/nats: nats-server and the nats CLI; core/anfsd: anfsd) pins it in its own pins.yml, as
# stack's ovm pins its plugins:
#
#   <name>:
#     repo: nats-io/nats-server
#     version: v2.15.1
#     asset: nats-server-{version}-{os}-{arch}.tar.gz     # {version}, {version#v}, {os}, {arch}
#     bin: nats-server-{version}-{os}-{arch}/nats-server  # the program inside the archive
#     sha256:
#       darwin-arm64: <64 hex>                             # one per platform, from the release
#
# anfs_pin_fetch downloads the asset once into $XDG_CACHE_HOME/<dir>/<version>/ (CACHE: it can be
# fetched again), checks its sha256 (sha256sum, else shasum -a 256), and unpacks the program into
# $XDG_DATA_HOME/<dir>/<version>/ (DATA). A mismatch deletes the download and fails naming both
# sums; no curl, or no pin for this platform, fails saying what to do. A program already in DATA
# from an asset in the cache with the pinned sum is not fetched again. Bumping a pin: change the
# version and every sum (the package's tests/pins --print fetches the assets and prints them).
#
# Functions only, the bash floor. Needs paths.sh. ANFS_PIN_PLATFORM overrides the platform
# (<os>-<arch>: darwin-arm64, linux-amd64) for tests.

# This machine as a release names it, into REPLY: darwin-arm64, linux-amd64, ...
anfs_pin_platform() {
  local os arch
  if [[ -n "${ANFS_PIN_PLATFORM:-}" ]]; then REPLY="$ANFS_PIN_PLATFORM"; return 0; fi
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) REPLY=""; return 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) REPLY=""; return 1 ;;
  esac
  REPLY="$os-$arch"
}

# sha256 of <file> into REPLY
anfs_sha256() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then out=$(sha256sum -- "$1") || return 1
  else out=$(shasum -a 256 -- "$1") || return 1
  fi
  REPLY="${out%% *}"
}

# A pin of <pins.yml> into PIN_REPO, PIN_VERSION, PIN_ASSET, PIN_BIN (both expanded for this
# platform), PIN_SHA (this platform's; empty when none), PIN_URL, PIN_PLATFORM. 1 with PIN_ERR.
anfs_pin_read() {
  local file="$1" name="$2" out os arch t
  PIN_REPO="" PIN_VERSION="" PIN_ASSET="" PIN_BIN="" PIN_SHA="" PIN_URL="" PIN_PLATFORM="" PIN_ERR=""
  anfs_pin_platform || { PIN_ERR="no release is built for $(uname -s) $(uname -m)"; return 1; }
  PIN_PLATFORM="$REPLY"
  out=$(N="$name" P="$PIN_PLATFORM" yq -r '.[strenv(N)] | [(.repo // ""), (.version // "" | tostring),
    (.asset // ""), (.bin // ""), ((.sha256 // {})[strenv(P)] // "")] | join("\t")' "$file" 2>/dev/null) ||
    { PIN_ERR="$(anfs_display "$file") does not read"; return 1; }
  IFS=$'\t' read -r PIN_REPO PIN_VERSION PIN_ASSET PIN_BIN PIN_SHA <<< "$out"
  if [[ ! "$PIN_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ || -z "$PIN_VERSION" || -z "$PIN_ASSET" || -z "$PIN_BIN" ]]; then
    PIN_ERR="$(anfs_display "$file"): $name needs repo, version, asset and bin"
    return 1
  fi
  os="${PIN_PLATFORM%-*}" arch="${PIN_PLATFORM#*-}"
  for t in PIN_ASSET PIN_BIN; do
    local v="${!t}"
    v="${v//\{version\}/$PIN_VERSION}" v="${v//\{version#v\}/${PIN_VERSION#v}}"
    v="${v//\{os\}/$os}" v="${v//\{arch\}/$arch}"
    printf -v "$t" '%s' "$v"
  done
  if [[ "$PIN_ASSET" == */* || "$PIN_BIN" == /* || "$PIN_BIN" == *..* ]]; then
    PIN_ERR="$(anfs_display "$file"): $name's asset is a file name and bin a path inside it"
    return 1
  fi
  PIN_URL="https://github.com/$PIN_REPO/releases/download/$PIN_VERSION/$PIN_ASSET"
}

# Fetch, check and unpack pin <name> of <pins.yml> under <dir> (the tool's directory name in
# CACHE and DATA). The program's path into REPLY. 1 with PIN_ERR on any failure, nothing left in
# DATA. Usage: anfs_pin_fetch <pins.yml> <name> <dir>
anfs_pin_fetch() {
  local file="$1" name="$2" dir="$3" cache data asset prog tmp got
  anfs_pin_read "$file" "$name" || return 1
  if [[ -z "$PIN_SHA" ]]; then
    PIN_ERR="$name $PIN_VERSION has no sha256 for $PIN_PLATFORM in $(anfs_display "$file"): no release is pinned for this platform"
    return 1
  fi
  [[ "$PIN_SHA" =~ ^[0-9a-f]{64}$ ]] || { PIN_ERR="$name's sha256 for $PIN_PLATFORM is not 64 hex: $PIN_SHA"; return 1; }
  cache="$XDG_CACHE_HOME/$dir/$PIN_VERSION" data="$XDG_DATA_HOME/$dir/$PIN_VERSION"
  asset="$cache/$PIN_ASSET" prog="$data/${PIN_BIN##*/}"

  if [[ -f "$asset" ]] && anfs_sha256 "$asset" && [[ "$REPLY" == "$PIN_SHA" ]]; then
    if [[ -x "$prog" ]]; then REPLY="$prog"; return 0; fi
  else
    command -v curl >/dev/null 2>&1 || { PIN_ERR="curl is not installed: it is how $name $PIN_VERSION is downloaded"; return 1; }
    mkdir -p -- "$cache" || { PIN_ERR="cannot make $(anfs_display "$cache")"; return 1; }
    rm -f -- "$asset.part"
    if ! curl -fsSL --retry 3 -o "$asset.part" "$PIN_URL" 2>/dev/null; then
      rm -f -- "$asset.part"
      PIN_ERR="download failed: $PIN_URL"
      return 1
    fi
    anfs_sha256 "$asset.part" && got="$REPLY" || got="?"
    if [[ "$got" != "$PIN_SHA" ]]; then
      rm -f -- "$asset.part"
      PIN_ERR="$PIN_ASSET: sha256 $got, pinned $PIN_SHA (the pin or the release changed; nothing installed)"
      return 1
    fi
    mv -f -- "$asset.part" "$asset"
  fi

  mkdir -p -- "$data" || { PIN_ERR="cannot make $(anfs_display "$data")"; return 1; }
  tmp=$(mktemp -d "$data/.unpack.XXXXXX") || { PIN_ERR="cannot write in $(anfs_display "$data")"; return 1; }
  case "$PIN_ASSET" in
    *.tar.gz|*.tgz) tar -xzf "$asset" -C "$tmp" 2>/dev/null ;;
    *.zip)
      command -v unzip >/dev/null 2>&1 || { rm -rf -- "$tmp"; PIN_ERR="unzip is not installed: $PIN_ASSET needs it"; return 1; }
      unzip -q -o "$asset" -d "$tmp" 2>/dev/null ;;
    *) false ;;
  esac || { rm -rf -- "$tmp"; PIN_ERR="cannot unpack $PIN_ASSET"; return 1; }
  if [[ ! -f "$tmp/$PIN_BIN" ]]; then
    rm -rf -- "$tmp"
    PIN_ERR="$PIN_ASSET holds no $PIN_BIN"
    return 1
  fi
  chmod 755 "$tmp/$PIN_BIN" && mv -f -- "$tmp/$PIN_BIN" "$prog"
  rm -rf -- "$tmp"
  REPLY="$prog"
}

# Link ~/.local/bin/<name> to <program> (a link already there is replaced; anything else is left,
# 1). Usage: anfs_pin_link <program> [name]
anfs_pin_link() {
  local prog="$1" link="$ANFS_BIN_DIR/${2:-${1##*/}}"
  mkdir -p -- "$ANFS_BIN_DIR"
  if [[ -e "$link" && ! -L "$link" ]]; then
    PIN_ERR="$(anfs_display "$link") is in the way (not a link)"
    return 1
  fi
  ln -sfn -- "$prog" "$link"
}

# Remove ~/.local/bin/<name> when it is a link (a file is not ours). Usage: anfs_pin_unlink <name>
anfs_pin_unlink() {
  [[ ! -L "$ANFS_BIN_DIR/$1" ]] || rm -f -- "$ANFS_BIN_DIR/$1"
}
