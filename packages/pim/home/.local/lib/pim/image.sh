#!/usr/bin/env bash
# pim library: reading a definition — image.yml, the from: chain, the answer file, scripts, the
# image's ssh key and the template variables. Sourced by ~/.local/bin/pim; functions only.

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
img_user() { img_get "$(img_root "$1")" .user.name pim; }

# The arch to build or run: --arch, else the host's; it must be one the image supports
img_pick_arch() {
  local id="$1" want="${2:-}"
  want=$(arch_norm "${want:-$(host_arch)}")
  img_arches "$id" | grep -qx "$want" || die "$id supports $(img_arches "$id" | paste -sd, -), not $want (--arch)"
  echo "$want"
}

pim_defaults() { echo "$PIM_LIB_DIR/defaults"; }

# The answer file a root image installs with: its own, else pim's default for the distro
img_answer_file() {
  local id="$1" distro file
  distro=$(img_distro "$id")
  case "$distro" in
    debian) file=preseed.cfg ;;
    fedora) file=kickstart.ks ;;
    *) return 1 ;;
  esac
  if [[ -f "$(img_dir "$id")/$file" ]]; then echo "$(img_dir "$id")/$file"
  else echo "$(pim_defaults)/$distro/$file"
  fi
}

# The scripts a build runs, in order: the distro's defaults (root images only, unless
# scripts.defaults is false) and the image's scripts/*.sh, an image script replacing a default of
# the same name
img_scripts() {
  local id="$1" dir distro f
  dir=$(img_dir "$id")
  {
    if [[ -z "$(img_get "$id" .from)" && "$(img_get "$id" .scripts.defaults true)" != false ]]; then
      distro=$(img_distro "$id")
      for f in "$(pim_defaults)/$distro/scripts"/*.sh; do
        [[ -f "$f" && ! -f "$dir/scripts/$(basename "$f")" ]] && printf '%s\t%s\n' "$(basename "$f")" "$f"
      done
    fi
    for f in "$dir/scripts"/*.sh; do
      [[ -f "$f" ]] && printf '%s\t%s\n' "$(basename "$f")" "$f"
    done
  } | LC_ALL=C sort -t$'\t' -k1,1 | cut -f2
}

# verify.sh: the image's, else the nearest one up its chain, else the distro's default
img_verify_script() {
  local id f
  while IFS= read -r id; do
    f="$(img_dir "$id")/verify.sh"
    [[ -f "$f" ]] && { echo "$f"; return 0; }
  done < <(img_chain "$1")
  f="$(pim_defaults)/$(img_distro "$1")/verify.sh"
  [[ -f "$f" ]] && echo "$f"
}

# The root image's ssh key (generated on first use); a child's build carries its parent's key
pim_key() {
  local name dir
  name=$(img_name "$(img_root "$1")")
  dir="$PIM_DATA_HOME/keys/$name"
  if [[ ! -f "$dir/id_ed25519" ]]; then
    mkdir -p "$dir" && chmod 700 "$dir"
    ssh-keygen -q -t ed25519 -N '' -C "pim-$name" -f "$dir/id_ed25519"
  fi
  echo "$dir/id_ed25519"
}

# --- template variables -------------------------------------------------------------------------
# Parallel arrays (bash 3.2 has no associative arrays). A later tpl_set of a name wins.

TPL_NAMES=() TPL_VALUES=()

tpl_set() {
  local i
  for i in ${TPL_NAMES[@]+"${!TPL_NAMES[@]}"}; do
    [[ "${TPL_NAMES[$i]}" == "$1" ]] && { TPL_VALUES[$i]="$2"; return; }
  done
  TPL_NAMES+=("$1") TPL_VALUES+=("$2")
}

tpl_get() {
  local i
  for i in ${TPL_NAMES[@]+"${!TPL_NAMES[@]}"}; do
    [[ "${TPL_NAMES[$i]}" == "$1" ]] && { printf '%s' "${TPL_VALUES[$i]}"; return 0; }
  done
  return 1
}

# Load the variables a root image's answer file renders with: defaults, then image.yml vars:,
# then the built-ins (which vars: cannot override)
# Usage: tpl_load <id> <arch> <pubkey-file>
tpl_load() {
  local id="$1" arch="$2" pubkey="$3" root user hash line
  root=$(img_root "$id")
  TPL_NAMES=() TPL_VALUES=()
  tpl_set LOCALE en_US.UTF-8
  tpl_set KEYBOARD us
  tpl_set TIMEZONE UTC
  tpl_set HOSTNAME "$(img_name "$id")"
  tpl_set DOMAIN local
  tpl_set MIRROR_HOST deb.debian.org
  tpl_set MIRROR_PATH /debian
  tpl_set HTTP_PROXY ""
  tpl_set PARTITIONING_METHOD regular
  tpl_set PARTITIONING_RECIPE atomic
  tpl_set TASKSEL "standard, ssh-server"
  tpl_set PACKAGES "openssh-server curl sudo qemu-guest-agent"
  tpl_set GRUB_DEVICE default
  while IFS= read -r line; do
    [[ "$line" == *=* ]] && tpl_set "${line%%=*}" "${line#*=}"
  done < <(yq -r '.vars // {} | to_entries | .[] | .key + "=" + (.value | tostring)' "$(img_yml "$root")" 2>/dev/null)

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
