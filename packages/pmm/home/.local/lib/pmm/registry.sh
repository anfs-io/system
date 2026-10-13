#!/usr/bin/env bash
# pmm library: what has been built — each build's meta.yml; the image list, show (with what a
# build reads), remove and prune commands, and what is on a build. Sourced by ~/.local/bin/pmm;
# functions only.
#
# There is no central registry file: $PMM_DATA_HOME/images/<name>/<arch>/meta.yml describes the
# current build of one image for one arch, next to its disk (<key>.qcow2) and UEFI vars. Older
# disks stay until `pmm image prune`, since another image's build, or a machine, may be an
# overlay on them.
#
# A name is one image, and one meta.yml. A definition a higher-priority source shadows can still
# be built: it is what an image whose from: is its own name is built on (user/debian-13 on
# core/debian-13). Its record is meta@<source>.yml in the same directory, its disk beside the
# other's, so the two builds do not replace each other. img_bname is the name such a record is
# asked for by, and what meta_dir, meta_file and everything over them take. It is a record's name
# only: the image is still <name>, in a machine's state.yml and to holders_of.
#
# Which record a definition has therefore changes when a higher source starts or stops defining
# the name. Its build does not: a disk is found by its key (build_one), and build_adopt gives the
# definition's record what the other one said about it.

img_bname() {
  local name
  name=$(img_name "$1")
  if [[ "$(canon "$name" 2>/dev/null)" == "$1" ]]; then echo "$name"; else echo "$name@$(img_src "$1")"; fi
}
meta_dir()  { echo "$PMM_DATA_HOME/images/${1%@*}/$2"; }
meta_file() {
  local m=meta.yml
  [[ "$1" != *@* ]] || m="meta@${1#*@}.yml"
  echo "$(meta_dir "$1" "$2")/$m"
}

# A value from a build's meta.yml, or nothing
# Usage: meta_get <name> <arch> <yq path>
meta_get() {
  local f
  f=$(meta_file "$1" "$2")
  [[ -f "$f" ]] || return 0
  yq -r "($3) | select(. != null)" "$f" 2>/dev/null || true
}

# The current build's disk for <name> <arch>; fails when there is none
build_disk() {
  local key d
  key=$(meta_get "$1" "$2" .cache_key)
  d="$(meta_dir "$1" "$2")/$key.qcow2"
  [[ -n "$key" && -f "$d" ]] && echo "$d"
}

# True when the build <key> of <name> <arch> exists: a qcow2, or for tart a VM in tart's store
build_present() {
  case "$4" in
    tart) tart_exists "$(tart_vm_build "${1%@*}" "$3")" ;;
    *) [[ -f "$(meta_dir "$1" "$2")/$3.qcow2" ]] ;;
  esac
}

# The current build of <name> for <arch>, with what a machine made from it needs. Sets B_NAME
# (the image's name: never the record's, <name>@<source>), B_ID (the definition it was built from), B_BACKEND, B_KEY, B_DISK (a tart build: its VM's name),
# B_USER, B_AT, B_TESTED (true|false), and from the root image's definition, when it is still
# there, B_SSHKEY, B_BOOT_USER and B_BOOT_PW (tart: the stock image's account). Fails when there
# is no build, or its disk is gone.
build_read() {
  local name="$1" arch="$2" f tested root
  B_NAME="${name%@*}" B_ID="" B_BACKEND="" B_KEY="" B_DISK="" B_USER="" B_AT="" B_TESTED=false
  B_SSHKEY="" B_BOOT_USER="" B_BOOT_PW=""
  f=$(meta_file "$name" "$arch")
  [[ -f "$f" ]] || return 1
  IFS='|' read -r B_ID B_BACKEND B_KEY B_DISK B_USER B_AT tested < <(
    yq -r '[.id, .backend, .cache_key, .disk, .user, .built_at // "", .tested_key // ""] | join("|")' "$f" 2>/dev/null) || return 1
  [[ -n "$B_KEY" ]] || return 1
  if [[ "$B_BACKEND" == tart ]]; then
    tart_exists "$B_DISK" || return 1
  else
    B_DISK="$(dirname "$f")/$B_KEY.qcow2"
    [[ -f "$B_DISK" ]] || return 1
  fi
  [[ "$tested" != "$B_KEY" ]] || B_TESTED=true
  if root=$(img_root "$B_ID" 2>/dev/null) && [[ -n "$root" && -f "$(img_yml "$root")" ]]; then
    B_SSHKEY="$PMM_DATA_HOME/keys/$(img_name "$root")/id_ed25519"
    [[ "$B_BACKEND" != tart ]] || { _tart_boot "$B_ID"; B_BOOT_USER="$BOOT_USER" B_BOOT_PW="$BOOT_PW"; }
  fi
  return 0
}

# Record a finished build
# Usage: meta_write_build <id> <arch> <key> <parent id|"">
meta_write_build() {
  local id="$1" arch="$2" key="$3" parent="$4" name pdisk="" pkey=""
  name=$(img_bname "$id")
  if [[ -n "$parent" ]]; then
    pdisk=$(build_disk "$(img_bname "$parent")" "$arch")
    pkey=$(meta_get "$(img_bname "$parent")" "$arch" .cache_key)
  fi
  ID="$id" NAME="$(img_name "$id")" ARCH="$arch" KEY="$key" BACKEND="$(img_backend "$id")" \
  PARENT="$parent" PKEY="$pkey" PDISK="$pdisk" USER_="$(img_user "$id")" AT="$(now_iso)" \
  ISO="$( [[ -z "$parent" && "$(img_backend "$id")" == qemu ]] && img_iso_id "$id" "$arch")" \
    yq -n '.id = strenv(ID) | .name = strenv(NAME) | .arch = strenv(ARCH) | .backend = strenv(BACKEND)
           | .cache_key = strenv(KEY) | .disk = strenv(KEY) + ".qcow2" | .user = strenv(USER_)
           | .built_at = strenv(AT)
           | .parent = (strenv(PARENT) | select(. != "") | {"id": ., "cache_key": strenv(PKEY), "disk": strenv(PDISK)})
           | .iso = (strenv(ISO) | select(. != ""))
           | .tested_key = null | .exports = []' > "$(meta_file "$name" "$arch").tmp"
  mv "$(meta_file "$name" "$arch").tmp" "$(meta_file "$name" "$arch")"
  _meta_settle "$id" "$arch"
}

# Which record is a definition's changes when a higher source starts or stops defining the name
# (img_bname). Once <id> has the name's own record, the one it had while it was shadowed goes.
_meta_settle() {
  local name
  name=$(img_bname "$1")
  [[ "$name" == *@* ]] || rm -f "$(meta_file "$name@$(img_src "$1")" "$2")"
}

# Record <id>'s build <key> when it is there and <id>'s record does not say so: the name's other
# record has it (a higher source began, or stopped, defining the name), the definition moved to
# another source, or it is an earlier build the definition is back at. Never built again: machines
# and other images' builds are overlays on that disk. The record that names the key is taken
# whole (when it was built, tested, its exports); with none, a new one is written.
# Usage: build_adopt <id> <arch> <key> <parent id|"">
build_adopt() {
  local id="$1" arch="$2" key="$3" parent="$4" name f to
  name=$(img_bname "$id")
  to=$(meta_file "$name" "$arch")
  for f in "$(meta_dir "$name" "$arch")"/meta*.yml; do
    [[ -f "$f" && "$(yq -r '.cache_key // ""' "$f" 2>/dev/null)" == "$key" ]] || continue
    ID="$id" yq '.id = strenv(ID)' "$f" > "$to.tmp"
    mv "$to.tmp" "$to"
    _meta_settle "$id" "$arch"
    return 0
  done
  meta_write_build "$id" "$arch" "$key" "$parent"
  [[ "$(img_backend "$id")" != tart ]] || meta_set "$name" "$arch" '.disk = strenv(v)' "$(tart_vm_build "$(img_name "$id")" "$key")"
}

# Set one field of a build's meta.yml: meta_set <name> <arch> <yq assignment using $v> <value>
meta_set() {
  local f
  f=$(meta_file "$1" "$2")
  v="$4" yq -i "$3" "$f"
}

# Every built image name (that has a meta.yml for some arch)
built_names() {
  local d
  for d in "$PMM_DATA_HOME"/images/*/; do
    ls "$d"*/meta*.yml >/dev/null 2>&1 && basename "$d"
  done
  return 0
}

# Builds (name/arch) whose meta.yml names <disk> as their parent disk
dependents_of_disk() {
  local f
  for f in "$PMM_DATA_HOME"/images/*/*/meta*.yml; do
    [[ -f "$f" ]] || continue
    [[ "$(yq -r '.parent.disk // ""' "$f")" == "$1" ]] && echo "$(yq -r .name "$f")/$(yq -r .arch "$f")"
  done
  return 0
}

# What is on <name> <arch>'s builds (on the build <key>, when one is given), one per line: each
# qemu machine whose disk is an overlay on one, as <machine>, and each of their snapshots, as
# <machine>@<snapshot>. Nothing records this: it is read from the machines' and the snapshots'
# own state.yml whenever it is asked, so it cannot disagree with them. A tart machine is a clone
# and is on nothing.
holders_of() {
  local name="$1" arch="$2" key="${3:-}" f image a k backend
  local -a files=()
  for f in "$PMM_DATA_HOME"/machines/*/state.yml "$PMM_DATA_HOME"/snapshots/*/*/state.yml; do
    [[ -f "$f" ]] && files+=("$f")
  done
  [[ ${#files[@]} -gt 0 ]] || return 0
  while IFS='|' read -r f image a k backend; do
    [[ "$backend" == qemu && -n "$k" && "${image#*/}" == "$name" && "$a" == "$arch" ]] || continue
    [[ -z "$key" || "$k" == "$key" ]] || continue
    f="${f%/state.yml}"
    case "$f" in
      "$PMM_DATA_HOME"/snapshots/*) echo "$(basename "$(dirname "$f")")@$(basename "$f")" ;;
      *) basename "$f" ;;
    esac
  done < <(yq -r '[filename, .image // "", .arch // "", .key // "", .backend // ""] | join("|")' "${files[@]}" 2>/dev/null) |
    LC_ALL=C sort -u
  return 0
}

# built | stale for <id>'s <arch> build, which is B_KEY, built from B_ID (build_read): stale when
# the definition has changed since, or another source's definition of the name is what was built
_build_state() {
  local current
  if [[ "$B_ID" == "$1" ]] && current=$(build_key "$1" "$2" 2>/dev/null) && [[ "$current" == "$B_KEY" ]]; then echo built
  else echo stale
  fi
}

# `pmm image list [image...]`: every image, one row per built arch. STATE: built, stale (the
# definition changed since the build), unbuilt, shadowed (a higher-priority source defines the
# name). An unbuilt or shadowed image is one row with no arch. A build whose definition is gone
# is listed with no source, as stale. Read with --json (lib/anfs/table.sh); the keys are the
# interface.
cmd_image_list() {
  local id name arch f n only=" " arg
  local -a ids=()
  local -A seen=()
  for arg in "$@"; do only+="$(img_name "$(canon "$arg" || echo "x/$arg")") "; done
  while IFS= read -r id; do ids+=("$id"); done < <(all_ids)
  if [[ ${#ids[@]} -eq 0 && -z "$(built_names)" ]]; then
    echo "No images found; add a source with: anfs src add <git-url> [alias]" >&2
    ! anfs_json_on || echo '[]'
    return 0
  fi

  _image_row() {  # <source> <state>: the build in B_*
    anfs_row "$B_NAME" "$1" "$arch" "$2" "$B_KEY" "$B_DISK" "$B_BACKEND" "$B_USER" "$B_SSHKEY" \
      "$(holders_of "$B_NAME" "$arch" "$B_KEY" | paste -sd' ' -)" "$B_AT" "$B_TESTED"
  }
  {
    for id in ${ids[@]+"${ids[@]}"}; do
      name=$(img_name "$id")
      [[ "$only" == " " || "$only" == *" $name "* ]] || continue
      if [[ "$(canon "$name")" != "$id" ]]; then
        anfs_row "$name" "$(img_src "$id")" "" shadowed "" "" "$(img_backend "$id")" "" "" "" "" ""
        continue
      fi
      seen[$name]=1
      n=0
      for arch in arm64 amd64; do
        build_read "$name" "$arch" || continue
        _image_row "$(img_src "$id")" "$(_build_state "$id" "$arch")"
        n=$((n + 1))
      done
      [[ $n -gt 0 ]] || anfs_row "$name" "$(img_src "$id")" "" unbuilt "" "" "$(img_backend "$id")" "$(img_user "$id" 2>/dev/null || true)" "" "" "" ""
    done
    for f in "$PMM_DATA_HOME"/images/*/*/meta.yml; do
      [[ -f "$f" ]] || continue
      arch=$(basename "$(dirname "$f")") name=$(basename "$(dirname "$(dirname "$f")")")
      [[ -z "${seen[$name]:-}" ]] || continue
      [[ "$only" == " " || "$only" == *" $name "* ]] || continue
      build_read "$name" "$arch" || continue
      _image_row "" stale
    done
  } | LC_ALL=C sort -s -t"$ANFS_US" -k1,1 |
    anfs_table "NAME SOURCE ARCH STATE KEY DISK BACKEND USER SSHKEY HELD BUILT TESTED" \
      "name source arch state key disk backend user sshkey held[] built tested"
}

# What a build of <id> reads, one record per line, fields joined by $ANFS_US. `image show` prints
# them and gives them as --json, so the two cannot differ:
#   answer <file>                    the root's answer file (qemu), there or not
#   var <name> <value> <base64>      the root's vars:; <value> has \n for a newline, to be one line
#   iso <arch> <id> <file> <state>   the ISO each arch installs from: present | missing | unknown
#   base <oci image>                 tart
#   step <label> <image> <file>      the provision steps, the root's first, each image's anfs
#                                    install (no file) after its own; then finalize, pmm's (no
#                                    image; qemu)
#   test <file>                      test.sh: the image's, or the nearest up its chain
#   logs <dir>                       where a build's logs go, for the arch this host builds
_image_plan() {
  local id="$1" root cid f arch iso file state line i
  local -a chain=()
  mapfile -t chain < <(img_chain "$id" 2>/dev/null)
  [[ ${#chain[@]} -gt 0 ]] || chain=("$id")
  root="${chain[-1]}"
  if [[ "$(img_backend "$root")" == tart ]]; then
    anfs_row base "$(img_get "$root" .base)"
  else
    f=$(img_answer_file "$id") && anfs_row answer "$f"
    while IFS= read -r line; do
      [[ "$line" == *=* ]] || continue
      file=$(var_value "$line")
      anfs_row var "${line%%=*}" "${file//$'\n'/\\n}" "${line#*=}"
    done < <(img_vars "$id")
    while IFS= read -r arch; do
      iso=$(img_iso_id "$id" "$arch") file="" state=unknown
      if [[ -n "$iso" ]] && anfs_iso_known "$iso" && file=$(anfs_iso_file "$iso" 2>/dev/null); then
        [[ -f "$file" ]] && state=present || state=missing
      fi
      anfs_row iso "$arch" "$iso" "$file" "$state"
    done < <(img_arches "$id")
  fi
  for (( i = ${#chain[@]} - 1; i >= 0; i-- )); do
    cid="${chain[$i]}"
    while IFS= read -r f; do anfs_row step "$(basename "$f")" "$cid" "$f"; done < <(img_scripts "$cid")
    ! img_has_anfs "$cid" || anfs_row step "anfs install ($(img_get "$cid" .anfs.sources pushed))" "$cid" ""
  done
  # a tart build ends with a reboot instead (tart_build)
  [[ "$(img_backend "$root")" == tart ]] || anfs_row step finalize "" "$(img_finalize)"
  f=$(img_test_script "$id" 2>/dev/null) || f=""
  [[ -z "$f" ]] || anfs_row test "$f"
  arch=$(host_arch)
  grep -qx "$arch" <<< "$(img_arches "$id")" || arch=$(img_arches "$id" | head -n1)
  anfs_row logs "$PMM_STATE_HOME/logs/$(img_bname "$id")-$arch/"
}

# `pmm image show <image>`: the definition, everything a build of it reads (with --json, the same
# as one object), then its builds
cmd_image_show() {
  local id name bname arch chain f key held current plan kind a b c d last="" w=16
  id=$(img_canon_or_die "$1")
  name=$(img_name "$id") bname=$(img_bname "$id")
  plan=$(_image_plan "$id")
  if anfs_json_on; then _image_show_json "$id" "$plan"; return; fi
  echo "$id"
  echo "  definition  $(tilde "$(img_dir "$id")")"
  chain=$(img_chain "$id" 2>/dev/null | paste -sd' ' - | sed 's/ / <- /g') || true
  [[ "$(img_chain "$id" 2>/dev/null | wc -l)" -gt 1 ]] && echo "  from        ${chain#* <- }"
  echo "  backend     $(img_backend "$id")"
  echo "  distro      $(img_distro "$id")"
  echo "  arch        $(img_arches "$id" | paste -sd, -)"
  echo "  user        $(img_user "$id")"
  # a label is printed once: the records of a kind follow each other
  _plan_line() {  # <label> <text>
    [[ "$1" == "$last" ]] && printf '  %-11s %s\n' "" "$2" || printf '  %-11s %s\n' "$1" "$2"
    last="$1"
  }
  # the steps' paths line up after the longest label
  while IFS="$ANFS_US" read -r kind a b; do
    [[ "$kind" != step || ${#a} -le $w ]] || w=${#a}
  done <<< "$plan"
  while IFS="$ANFS_US" read -r kind a b c d; do
    case "$kind" in
      answer) _plan_line answer "$(tilde "$a")$([[ -f "$a" ]] || echo "  (missing)")" ;;
      var)    _plan_line vars "$a=$b" ;;
      iso)    _plan_line "iso $a" "${b:-(none)}$([[ -z "$c" ]] || echo "  ($(tilde "$c"), $d)")$([[ -z "$b" || "$d" != unknown ]] || echo "  (not in the catalogue)")" ;;
      base)   _plan_line base "$a" ;;
      step)   if [[ -z "$b" ]]; then _plan_line provision "$(printf '%-*s (pmm) %s' "$w" "$a" "$(tilde "$c")")"
              elif [[ -z "$c" ]]; then _plan_line provision "$(printf '%-*s (pmm) %s' "$w" "$a" "$b: image.yml anfs:")"
              else _plan_line provision "$(printf '%-*s %s' "$w" "$a" "$(tilde "$c")")"
              fi ;;
      test)   _plan_line test "$(tilde "$a")" ;;
      logs)   grep -q "^test$ANFS_US" <<< "$plan" || _plan_line test "(none: image test has nothing to run)"
              _plan_line logs "$(tilde "$a")" ;;
    esac
  done <<< "$plan"
  for arch in arm64 amd64; do
    f=$(meta_file "$bname" "$arch")
    [[ -f "$f" ]] || continue
    key=$(meta_get "$bname" "$arch" .cache_key)
    echo "  build $arch"
    echo "    key       $key$( [[ "$(meta_get "$bname" "$arch" .id)" == "$id" ]] || echo " (built from $(meta_get "$bname" "$arch" .id))")"
    echo "    built     $(meta_get "$bname" "$arch" .built_at)"
    if [[ "$(meta_get "$bname" "$arch" .backend)" == tart ]]; then
      echo "    vm        $(meta_get "$bname" "$arch" .disk) (tart)"
    else
      echo "    disk      $(tilde "$(meta_dir "$bname" "$arch")/$key.qcow2") ($(file_size "$(meta_dir "$bname" "$arch")/$key.qcow2"))"
    fi
    [[ "$(meta_get "$bname" "$arch" .tested_key)" == "$key" ]] && echo "    tested    yes" || echo "    tested    no"
    [[ -n "$(meta_get "$bname" "$arch" .parent.id)" ]] && echo "    parent    $(meta_get "$bname" "$arch" .parent.id) ($(meta_get "$bname" "$arch" .parent.cache_key))"
    held=$(holders_of "$name" "$arch" | paste -sd' ' -)
    [[ -z "$held" ]] || echo "    held by   $held"
    if current=$(build_key "$id" "$arch" 2>/dev/null) && [[ "$current" != "$key" ]]; then
      echo "    stale     the definition changed since (pmm image build $name)"
    fi
  done
  return 0
}

# The same as one JSON object. Values are strings, null for what is not there; lists are lists
_image_show_json() {
  local id="$1" plan="$2" name arch kind a b c d sep h
  local answer=null base=null test=null logs=null vars="" isos="" steps="" builds="" chain="" arches=""
  _js() { if [[ -n "$1" ]]; then _anfs_json_str "$1"; else printf 'null'; fi; }
  name=$(img_name "$id")
  while IFS="$ANFS_US" read -r kind a b c d; do
    case "$kind" in
      answer) answer=$(_js "$a") ;;
      base)   base=$(_js "$a") ;;
      test)   test=$(_js "$a") ;;
      logs)   logs=$(_js "$a") ;;
      var)    vars+="${vars:+,}$(_anfs_json_str "$a"):$(_anfs_json_str "$(var_value "=$c")")" ;;
      iso)    isos+="${isos:+,}$(_anfs_json_str "$a"):{\"id\":$(_js "$b"),\"file\":$(_js "$c"),\"state\":$(_js "$d")}" ;;
      step)   steps+="${steps:+,}{\"step\":$(_js "$a"),\"image\":$(_js "$b"),\"file\":$(_js "$c")}" ;;
    esac
  done <<< "$plan"
  while IFS= read -r a; do chain+="${chain:+,}$(_anfs_json_str "$a")"; done < <(img_chain "$id" 2>/dev/null | tail -n +2)
  while IFS= read -r a; do arches+="${arches:+,}$(_anfs_json_str "$a")"; done < <(img_arches "$id")
  for arch in arm64 amd64; do
    build_read "$(img_bname "$id")" "$arch" || continue
    h="" sep=""
    while IFS= read -r a; do [[ -z "$a" ]] || { h+="$sep$(_anfs_json_str "$a")"; sep=,; }; done < <(holders_of "$name" "$arch")
    builds+="${builds:+,}{\"arch\":\"$arch\",\"state\":\"$(_build_state "$id" "$arch")\",\"key\":$(_js "$B_KEY"),\"disk\":$(_js "$B_DISK"),\"built\":$(_js "$B_AT"),\"tested\":\"$B_TESTED\",\"held\":[$h]}"
  done
  printf '{"id":%s,"definition":%s,"from":[%s],"backend":%s,"distro":%s,"arch":[%s],"user":%s,' \
    "$(_js "$id")" "$(_js "$(img_dir "$id")")" "$chain" "$(_js "$(img_backend "$id")")" "$(_js "$(img_distro "$id")")" "$arches" "$(_js "$(img_user "$id")")"
  printf '"answer":%s,"vars":{%s},"iso":{%s},"base":%s,"provision":[%s],"test":%s,"logs":%s,"builds":[%s]}\n' \
    "$answer" "$vars" "$isos" "$base" "$steps" "$test" "$logs" "$builds"
}

# `pmm image remove [-y] [-f] <image>...`: delete every build; the definition stays. A build a
# machine or a snapshot is on is refused, like one another image is built on
cmd_image_remove() {
  local yes=${CLI_OPT[yes]:-false} force=${CLI_OPT[force]:-false} arg name d dep arch
  local -a names=()
  for arg in "$@"; do names+=("$(img_name "$(canon "$arg" || echo "x/$arg")")"); done
  for name in "${names[@]}"; do
    for d in "$PMM_DATA_HOME/images/$name"/*/*.qcow2; do
      [[ -f "$d" ]] || continue
      for dep in $(dependents_of_disk "$d"); do
        [[ "${dep%%/*}" == "$name" ]] && continue
        $force || die "$dep is built on $name; remove it first, or pass -f"
      done
    done
    for d in "$PMM_DATA_HOME/images/$name"/*/; do
      [[ -d "$d" ]] || continue
      arch=$(basename "$d")
      dep=$(holders_of "$name" "$arch" | paste -sd' ' -)
      [[ -z "$dep" ]] || $force || die "$name ($arch) has machines on it: $dep; pmm remove them first, or pass -f"
    done
  done
  $yes || confirm "remove deletes builds" "Delete the builds of ${names[*]}?"
  for name in "${names[@]}"; do
    case "$(meta_get "$name" "$(host_arch)" .backend)" in tart) tart_rm "$name" ;; esac
    rm -rf "${PMM_DATA_HOME:?}/images/$name"
    echo "Removed $name"
  done
}

# `pmm image prune`: delete superseded build disks that no other build and no machine is on, and
# stale build workspaces. The ISOs are not pmm's alone: `pmm iso remove`, `pmm iso prune`
cmd_image_prune() {
  local f dir keys d d_key src freed=0
  for dir in "$PMM_DATA_HOME"/images/*/*/; do
    dir="${dir%/}"
    # a shadowed definition's record, when the definition is gone, is nothing's
    for f in "$dir"/meta@*.yml; do
      [[ -f "$f" ]] || continue
      src="${f##*/meta@}"
      canon "${src%.yml}/$(basename "$(dirname "$dir")")" >/dev/null 2>&1 || rm -f "$f"
    done
    # the current build of each definition of the name: the effective one's, and a shadowed one's
    keys=" "
    for f in "$dir"/meta*.yml; do
      [[ ! -f "$f" ]] || keys+="$(yq -r .cache_key "$f") "
    done
    [[ "$keys" != " " ]] || continue
    for d in "$dir"/*.qcow2 "$dir"/*.qcow2.part; do
      d_key=$(basename "${d%%.qcow2*}")
      [[ -f "$d" ]] || continue
      [[ "$d" == *.part || "$keys" != *" $d_key "* ]] || continue
      [[ -n "$(dependents_of_disk "$d")" ]] && continue
      [[ -n "$(holders_of "$(basename "$(dirname "$dir")")" "$(basename "$dir")" "$d_key")" ]] && continue
      echo "Deleting $(tilde "$d")"
      rm -f "$d" "${d%.qcow2}-efivars.fd"
      freed=$((freed + 1))
    done
  done
  for d in "$PMM_STATE_HOME"/build/*/; do
    [[ -d "$d" ]] || continue
    [[ -f "${d}pid" ]] && pid_alive "$(cat "${d}pid")" && continue
    rm -rf "$d"
  done
  echo "Pruned ($freed superseded disks)"
}
