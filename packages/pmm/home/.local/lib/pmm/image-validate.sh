#!/usr/bin/env bash
# pmm library: checking image definitions; the image validate command. Sourced by ~/.local/bin/pmm;
# functions only. _v_err and _v_warn, and their counters, are validate.sh's.

# The ISO a root image names for <arch>: an id in the catalogue, whose entry pins a sha256
_validate_iso() {
  local id="$1" arch="$2" iso
  if [[ "$(yq -r ".iso.$arch | tag" "$(img_yml "$id")" 2>/dev/null)" == "!!map" ]]; then
    _v_err "iso.$arch: an inline url and sha256 are gone; name an id in the ISO catalogue (iso: {$arch: <id>}; pmm iso list, pmm iso add)"
    return 0
  fi
  iso=$(img_iso_id "$id" "$arch")
  if [[ -z "$iso" ]]; then
    _v_err "iso.$arch is missing: an id in the ISO catalogue (pmm iso list)"
  elif ! anfs_iso_known "$iso"; then
    _v_err "iso.$arch: no ISO '$iso' in the catalogue (pmm iso list)"
  elif [[ -z "$(iso_sha256 "$iso")" ]]; then
    _v_err "iso.$arch: the catalogue entry '$iso' pins no sha256 (checksum: sha256:<hex>; a checksum_url is not enough: the sum is part of the build's key)"
  fi
  return 0
}

# Check one image, printing its problems; adds to V_ERRORS / V_WARNINGS
validate_image() {
  local id="$1" dir yml backend from distro arch a f
  dir=$(img_dir "$id")
  yml="$dir/image.yml"
  yq -e '.' "$yml" >/dev/null 2>&1 || yq -e 'true' "$yml" >/dev/null 2>&1 || { _v_err "image.yml does not parse"; return; }
  [[ "$(yq -r 'tag' "$yml")" == "!!map" ]] || { _v_err "image.yml is not a map"; return; }

  backend=$(img_backend "$id")
  case "$backend" in qemu|tart) ;; *) _v_err "backend '$backend' (qemu or tart)"; return ;; esac

  from=$(img_get "$id" .from)
  if [[ -n "$from" ]]; then
    img_chain "$id" >/dev/null 2>"$PMM_STATE_HOME/.chain.err" || { _v_err "$(cat "$PMM_STATE_HOME/.chain.err")"; return; }
    for f in distro iso base arch vars user; do
      [[ "$(yq -r "has(\"$f\")" "$yml")" != true ]] || _v_warn "$f: is ignored on a from: image (its root's applies)"
    done
    [[ "$(img_backend "$(img_root "$id")")" == "$backend" ]] || _v_err "backend $backend differs from its root's"
  else
    distro=$(img_get "$id" .distro)
    # the name reaches a root shell in the guest as it is (~<user>): an account's name only
    [[ "$(img_user "$id")" =~ ^[a-z_][a-z0-9_-]*$ ]] || _v_err "user.name '$(img_user "$id")' is not an account's name (a letter or _, then letters, digits, _ and -)"
    while IFS= read -r a; do
      case "$(arch_norm "$a")" in arm64|amd64) ;; *) _v_err "arch '$a' (arm64 or amd64)" ;; esac
    done < <(img_list "$id" .arch)
    if [[ "$backend" == qemu ]]; then
      case "$distro" in
        debian|fedora) ;;
        "") _v_err "distro: is required (debian or fedora)" ;;
        *) _v_err "distro '$distro' has no installer (debian or fedora)" ;;
      esac
      while IFS= read -r arch; do
        _validate_iso "$id" "$arch"
      done < <(img_arches "$id")
      if f=$(answer_name "$distro"); then
        if [[ ! -f "$dir/$f" ]]; then
          _v_err "no answer file: a $distro image installs with its own $f (pmm image new --copy copies a shipped image's)"
        else
          local pub="$PMM_STATE_HOME/.validate.pub"
          echo "ssh-ed25519 AAAA validate" > "$pub"
          tpl_load "$id" "$(img_arches "$id" | head -n1)" "$pub"
          render "$dir/$f" > /dev/null 2>"$PMM_STATE_HOME/.render.err" ||
            _v_err "$(sed 's/^pmm: //' "$PMM_STATE_HOME/.render.err") (image.yml's vars: sets none of that name)"
          rm -f "$pub"
        fi
      fi
    else
      [[ "$distro" == macos || -z "$distro" ]] || _v_err "distro '$distro': the tart backend builds macos"
      [[ -n "$(img_get "$id" .base)" ]] || _v_err "base: is required for a tart image (an OCI image)"
      [[ "$(host_os)" == darwin && "$(host_arch)" == arm64 ]] || _v_warn "tart images build only on Apple silicon macOS"
    fi
  fi

  [[ -z "$from" ]] || for f in preseed.cfg kickstart.ks; do
    [[ ! -f "$dir/$f" ]] || _v_warn "$f is ignored on a from: image (its root's installed it)"
  done
  # Every file in provision/ is a step, and something has to run it: its provisioner is there,
  # has what it needs on this host (check), and can say what the step depends on (fingerprint),
  # all of which is there
  local ext bin out seen=" "
  prov_image_env "$id" "$(img_arches "$id" 2>/dev/null | head -n1)"
  for f in "$dir"/provision/*; do
    [[ -f "$f" ]] || continue   # a directory is not a step: a provisioner's own tree may be one
    ext=$(prov_ext "$f") || { _v_err "provision/$(basename "$f") has no extension: a step's provisioner is its extension (10-base.sh)"; continue; }
    bin=$(prov_bin "$ext") || { _v_err "provision/$(basename "$f"): nothing provides .$ext steps: install the package that does"; continue; }
    [[ -s "$f" ]] || _v_warn "provision/$(basename "$f") is empty"
    if [[ "$seen" != *" $ext "* ]]; then
      seen+="$ext "
      out=$(prov_call check "$f" 2>&1) && [[ -z "$out" ]] || { _v_err ".$ext steps: ${out:-its check failed}"; continue; }
    fi
    # as the build key reads it: what it names is there too
    out=$(key_step "$bin" "$f" 2>&1 >/dev/null) || _v_err "provision/$(basename "$f"): $(paste -sd' ' - <<< "${out:-its fingerprint failed}")"
  done
  # What the image directory used to be: said, not silently ignored
  [[ ! -d "$dir/scripts" ]] || _v_err "scripts/ is never run: the steps are in provision/ now"
  [[ "$(yq -r 'has("scripts")' "$yml")" != true ]] || _v_err "scripts: is gone: an image runs its own provision/ and nothing else"
  for f in cpus memory disk; do
    [[ -z "$(img_get "$id" ".$f")" ]] || _v_err "$f: is build.$f now (build: {cpus, memory, disk}: what the build runs with)"
  done
  # build: what the build runs with. A key nothing reads, or a value qemu or tart would choke on
  # mid-build, is said here
  if [[ "$(yq -r 'has("build")' "$yml")" == true ]]; then
    if [[ "$(yq -r '.build | tag' "$yml")" != "!!map" ]]; then
      _v_err "build: is a map (build: {cpus, memory, disk})"
    else
      while IFS='=' read -r f a; do
        case "$f" in
          cpus)   [[ "$a" =~ ^[1-9][0-9]*$ ]] || _v_err "build.cpus '$a' is not a number" ;;
          memory) [[ "$a" =~ ^[1-9][0-9]*$ ]] || _v_err "build.memory '$a' is not a number of MB (4096)" ;;
          disk)   if [[ "$backend" == tart ]]; then [[ "$a" =~ ^[1-9][0-9]*G$ ]] || _v_err "build.disk '$a' is not a size in G (80G)"
                  else [[ "$a" =~ ^[1-9][0-9]*[MG]$ ]] || _v_err "build.disk '$a' is not a size (20G)"
                  fi ;;
          *)      _v_err "build.$f is not a setting (cpus, memory, disk)" ;;
        esac
      done < <(yq -r '.build | to_entries | .[] | .key + "=" + (.value | tostring)' "$yml")
    fi
  fi
  [[ "$(yq -r 'has("anfs")' "$yml")" != true ]] || _v_err "anfs: is gone: a step holds it now (provision/50-toolkit.anfs, with the same keys)"
  return 0
}

# Validate one image silently; on failure print its errors to stderr
validate_image_quiet() {
  local out
  V_ERRORS=0 V_WARNINGS=0
  mkdir -p "$PMM_STATE_HOME"
  out=$(validate_image "$1"; echo "rc:$V_ERRORS")
  [[ "${out##*rc:}" == 0 ]] && return 0
  printf '%s\n' "${out%rc:*}" | grep '  error' >&2
  return 1
}

cmd_image_validate() {
  local spec id total_e=0 total_w=0 out
  local -a ids=()
  mkdir -p "$PMM_STATE_HOME"
  if [[ $# -eq 0 ]]; then
    while IFS= read -r id; do ids+=("$id"); done < <(effective_ids)
  else
    for spec in "$@"; do ids+=("$(img_canon_or_die "$spec")"); done
  fi
  [[ ${#ids[@]} -gt 0 ]] || { echo "No images to validate"; return 0; }
  for id in "${ids[@]}"; do
    V_ERRORS=0 V_WARNINGS=0
    out=$(validate_image "$id"; echo "rc:$V_ERRORS:$V_WARNINGS")
    local counts="${out##*rc:}"
    out="${out%rc:*}"
    total_e=$((total_e + ${counts%%:*}))
    total_w=$((total_w + ${counts##*:}))
    if [[ -n "${out//[$'\n']/}" ]]; then echo "$id"; printf '%s' "$out"
    else echo "$id ok"
    fi
  done
  rm -f "$PMM_STATE_HOME"/.chain.err "$PMM_STATE_HOME"/.render.err
  echo "${#ids[@]} image(s): $total_e error(s), $total_w warning(s)"
  [[ $total_e -eq 0 ]]
}
