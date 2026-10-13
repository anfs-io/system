#!/usr/bin/env bash
# pmm library: reading an image definition — image.yml, the from: chain, the answer file, the
# provision steps, the image's ssh key and the template variables. Sourced by ~/.local/bin/pmm; functions only.

img_yml() { echo "$(img_dir "$1")/image.yml"; }

# A scalar from image.yml, or <default> when it is missing or null
# Usage: img_get <id> <yq path> [default]
img_get() {
  local v
  v=$(yq -r "($2) | select(. != null)" "$(img_yml "$1")" 2>/dev/null) || v=""
  [[ -n "$v" ]] && echo "$v" || echo "${3:-}"
}

# A list from image.yml, one item per line (a scalar is a one-item list)
img_list() {
  yq -r "[($2)] | flatten | .[] | select(. != null)" "$(img_yml "$1")" 2>/dev/null || true
}

img_backend() { img_get "$1" .backend qemu; }

# The image's from: parent id, resolved in the same or a lower-priority source. A from: naming the
# image's own name is the next layer down (a source overriding an image it builds on).
img_parent() {
  local id="$1" from min parent
  from=$(img_get "$id" .from)
  [[ -n "$from" ]] || return 1
  min=$(source_index "$(img_src "$id")")
  parent=$(canon "$from" "$min") || { echo "?$from"; return 0; }
  if [[ "$parent" == "$id" ]]; then
    parent=$(canon "$from" $((min + 1))) || { echo "?$from"; return 0; }
  fi
  echo "$parent"
}

# The from: chain, the image first and its root (the image built from an ISO or base) last.
# Fails on an unresolvable parent or a cycle, printing why to stderr.
img_chain() {
  local id="$1" seen=" " parent
  while :; do
    [[ "$seen" != *" $id "* ]] || { warn "from: cycle at $id"; return 1; }
    seen+="$id "
    echo "$id"
    parent=$(img_parent "$id") || return 0
    [[ "$parent" != \?* ]] || { warn "$id: from: ${parent#\?} not found in its source or below"; return 1; }
    id="$parent"
  done
}

img_root() { img_chain "$1" | tail -n1; }

# distro, arch list and user are the root's (a child inherits what it is built on)
img_distro() { img_get "$(img_root "$1")" .distro; }
img_arches() {
  local a
  a=$(img_list "$(img_root "$1")" .arch | while read -r x; do arch_norm "$x"; done)
  [[ -n "$a" ]] && echo "$a" || host_arch
}
img_user() { img_get "$(img_root "$1")" .user.name pmm; }

# The arch to build or run: --arch, else the host's; it must be one the image supports
img_pick_arch() {
  local id="$1" want="${2:-}"
  want=$(arch_norm "${want:-$(host_arch)}")
  grep -qx "$want" <<< "$(img_arches "$id")" || die "$id supports $(img_arches "$id" | paste -sd, -), not $want (--arch)"
  echo "$want"
}

# pmm's own part of a build: the finalize step, which no image can replace or skip
img_finalize() { echo "$PMM_LIB_DIR/defaults/finalize.sh"; }

# The file name of a distro's answer file; fails for a distro with no installer
answer_name() {
  case "$1" in
    debian) echo preseed.cfg ;;
    fedora) echo kickstart.ks ;;
    *) return 1 ;;
  esac
}

# The answer file <id>'s root image installs with: where it has to be, there or not. Fails for a
# distro with no installer (a tart image has none)
img_answer_file() {
  local root file
  root=$(img_root "$1")
  file=$(answer_name "$(img_get "$root" .distro)") || return 1
  echo "$(img_dir "$root")/$file"
}

# The steps a build of <id> runs, in name order: its own provision/*.sh. A child's build starts
# from its parent's, so the parent's steps are not run again.
img_scripts() {
  local f
  for f in "$(img_dir "$1")/provision"/*.sh; do
    if [[ -f "$f" ]]; then echo "$f"; fi
  done | LC_ALL=C sort
}

# test.sh: the image's, else the nearest one up its chain; nothing when there is none
img_test_script() {
  local id f
  while IFS= read -r id; do
    f="$(img_dir "$id")/test.sh"
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done < <(img_chain "$1")
  return 0
}

# The root image's ssh key (generated on first use); a child's build carries its parent's key
img_key() {
  local name dir
  name=$(img_name "$(img_root "$1")")
  dir="$PMM_DATA_HOME/keys/$name"
  if [[ ! -f "$dir/id_ed25519" ]]; then
    mkdir -p "$dir" && chmod 700 "$dir"
    ssh-keygen -q -t ed25519 -N '' -C "pmm-image-$name" -f "$dir/id_ed25519"
  fi
  echo "$dir/id_ed25519"
}

# --- template variables -------------------------------------------------------------------------
# TPL holds them by name. declare -g: the tests source this file from inside a function.

declare -gA TPL=()

tpl_set() { TPL[$1]="$2"; }

tpl_get() {
  [[ -n "${TPL[$1]+x}" ]] || return 1
  printf '%s' "${TPL[$1]}"
}

# The vars: of <id>'s root image, as NAME=value lines (a null is an empty value)
img_vars() {
  yq -r '.vars // {} | to_entries | .[] | with(select(.value == null); .value = "") | .key + "=" + (.value | tostring)' \
    "$(img_yml "$(img_root "$1")")" 2>/dev/null || true
}

# Load the variables a root image's answer file renders with: HOSTNAME (the image's name unless
# vars: says), image.yml's vars:, then what an image cannot know, which vars: cannot override.
# Nothing else has a default: a name the answer file uses and vars: does not set is an error.
# Usage: tpl_load <id> <arch> <pubkey-file>
tpl_load() {
  local id="$1" arch="$2" pubkey="$3" root user hash line
  root=$(img_root "$id")
  TPL=()
  tpl_set HOSTNAME "$(img_name "$id")"
  while IFS= read -r line; do
    [[ "$line" == *=* ]] && tpl_set "${line%%=*}" "${line#*=}"
  done < <(img_vars "$id")

  user=$(img_user "$id")
  hash=$(img_get "$root" .user.password_hash)
  tpl_set USER "$user"
  tpl_set FULLNAME "$(img_get "$root" .user.fullname "$user")"
  tpl_set PASSWORD_HASH "${hash:-!}"
  if [[ -n "$hash" ]]; then tpl_set KS_PASSWORD "--iscrypted --password=$hash"
  else tpl_set KS_PASSWORD "--lock"
  fi
  tpl_set SSH_PUBKEY "$(cat "$pubkey")"
  tpl_set IMAGE "$(img_name "$id")"
  tpl_set ARCH "$arch"
}
