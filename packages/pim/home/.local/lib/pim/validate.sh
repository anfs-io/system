#!/usr/bin/env bash
# pim library: checking definitions; the validate command. Sourced by ~/.local/bin/pim; functions only.

V_ERRORS=0 V_WARNINGS=0

_v_err()  { echo "  error    $*"; V_ERRORS=$((V_ERRORS + 1)); }
_v_warn() { echo "  warning  $*"; V_WARNINGS=$((V_WARNINGS + 1)); }

# Check one image, printing its problems; adds to V_ERRORS / V_WARNINGS
validate_image() {
  local id="$1" dir yml backend from distro arch a sha url f
  dir=$(img_dir "$id")
  yml="$dir/image.yml"
  yq -e '.' "$yml" >/dev/null 2>&1 || yq -e 'true' "$yml" >/dev/null 2>&1 || { _v_err "image.yml does not parse"; return; }
  [[ "$(yq -r 'tag' "$yml")" == "!!map" ]] || { _v_err "image.yml is not a map"; return; }

  backend=$(img_backend "$id")
  case "$backend" in qemu|tart) ;; *) _v_err "backend '$backend' (qemu or tart)"; return ;; esac

  from=$(img_get "$id" .from)
  if [[ -n "$from" ]]; then
    img_chain "$id" >/dev/null 2>"$PIM_STATE_HOME/.chain.err" || { _v_err "$(cat "$PIM_STATE_HOME/.chain.err")"; return; }
    for f in distro iso base arch; do
      [[ -n "$(img_get "$id" ".$f")" ]] && _v_warn "$f: is ignored on a from: image (its root's applies)"
    done
    [[ "$(img_backend "$(img_root "$id")")" == "$backend" ]] || _v_err "backend $backend differs from its root's"
  else
    distro=$(img_get "$id" .distro)
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
        url=$(img_list "$id" ".iso.$arch.url" | head -n1)
        sha=$(img_get "$id" ".iso.$arch.sha256")
        [[ -n "$url" ]] || _v_err "iso.$arch.url is missing"
        [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || _v_err "iso.$arch.sha256 is missing or not a sha256"
      done < <(img_arches "$id")
      if [[ "$distro" == debian || "$distro" == fedora ]]; then
        f=$(img_answer_file "$id")
        [[ -f "$f" ]] || _v_err "no answer file ($(basename "$f"))"
        if [[ -f "$f" ]]; then
          local pub="$PIM_STATE_HOME/.validate.pub"
          echo "ssh-ed25519 AAAA validate" > "$pub"
          tpl_load "$id" "$(img_arches "$id" | head -n1)" "$pub"
          render "$f" > /dev/null 2>"$PIM_STATE_HOME/.render.err" || _v_err "$(sed 's/^pim: //' "$PIM_STATE_HOME/.render.err")"
          rm -f "$pub"
        fi
      fi
    else
      [[ "$distro" == macos || -z "$distro" ]] || _v_err "distro '$distro': the tart backend builds macos"
      [[ -n "$(img_get "$id" .base)" ]] || _v_err "base: is required for a tart image (an OCI image)"
      [[ "$(host_os)" == darwin && "$(host_arch)" == arm64 ]] || _v_warn "tart images build only on Apple silicon macOS"
    fi
  fi

  for f in "$dir"/scripts/*; do
    [[ -e "$f" ]] || continue
    [[ "$f" == *.sh ]] || { _v_warn "scripts/$(basename "$f") is not *.sh and is never run"; continue; }
    [[ -s "$f" ]] || _v_warn "scripts/$(basename "$f") is empty"
  done
  case "$(img_get "$id" .scripts.defaults true)" in true|false) ;; *) _v_err "scripts.defaults must be true or false" ;; esac
  if img_has_anfs "$id"; then
    case "$(img_get "$id" .anfs.sources pushed)" in host|pushed) ;; *) _v_err "anfs.sources must be host or pushed" ;; esac
  fi
  return 0
}

# Validate one image silently; on failure print its errors to stderr
validate_quiet() {
  local out
  V_ERRORS=0 V_WARNINGS=0
  mkdir -p "$PIM_STATE_HOME"
  out=$(validate_image "$1"; echo "rc:$V_ERRORS")
  [[ "${out##*rc:}" == 0 ]] && return 0
  printf '%s\n' "${out%rc:*}" | grep '  error' >&2
  return 1
}

cmd_validate() {
  local spec id total_e=0 total_w=0 out
  local -a ids=()
  mkdir -p "$PIM_STATE_HOME"
  if [[ $# -eq 0 ]]; then
    while IFS= read -r id; do ids+=("$id"); done < <(effective_ids)
  else
    for spec in "$@"; do ids+=("$(canon_or_die "$spec")"); done
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
  rm -f "$PIM_STATE_HOME"/.chain.err "$PIM_STATE_HOME"/.render.err
  echo "${#ids[@]} image(s): $total_e error(s), $total_w warning(s)"
  [[ $total_e -eq 0 ]]
}
