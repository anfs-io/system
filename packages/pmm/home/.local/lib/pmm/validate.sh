#!/usr/bin/env bash
# pmm library: checking machine definitions; the validate command. Sourced by ~/.local/bin/pmm;
# functions only. (Images: image-validate.sh, which counts with _v_err and _v_warn too.)

V_ERRORS=0 V_WARNINGS=0

_v_err()  { echo "  error    $*"; V_ERRORS=$((V_ERRORS + 1)); }
_v_warn() { echo "  warning  $*"; V_WARNINGS=$((V_WARNINGS + 1)); }

# Check one machine definition, printing its problems; adds to V_ERRORS / V_WARNINGS
validate_machine() {
  local id="$1" yml k v image profile path line
  yml=$(mach_yml "$id")
  yq -e 'true' "$yml" >/dev/null 2>&1 || { _v_err "machine.yml does not parse"; return; }
  [[ "$(mach_q "$id" tag)" == "!!map" ]] || { _v_err "machine.yml is not a map"; return; }
  mach_name_ok "$(mach_name "$id")" || _v_err "the name '$(mach_name "$id")': $PMM_NAME_RULE"

  while IFS= read -r k; do
    [[ " $PMM_KEYS " == *" $k "* ]] || _v_err "$k: is not a machine setting ($PMM_KEYS)"
  done < <(mach_q "$id" 'keys | .[]')

  image=$(mach_get "$id" .image)
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    line=$(media_problem "$v")
    case "$line" in
      error*) _v_err "${line#error }" ;;
      warning*) _v_warn "${line#warning }" ;;
    esac
  done < <(mach_list "$id" .media)
  if [[ -z "$image" ]]; then
    [[ -n "$(mach_list "$id" .media)" ]] || _v_err "image: is required (or media:, for a machine installed from an ISO)"
  elif ! image_def_dir "$image" >/dev/null 2>&1; then
    _v_err "image '$image' not found (pmm image list)"
    image=""
  fi

  profile=$(mach_get "$id" .profile)
  [[ -z "$profile" ]] || profile_file "$profile" >/dev/null || _v_err "profile '$profile' not found (machines/profiles.yml in a source)"
  if [[ -z "$profile" && -n "$image" ]]; then
    profile=$(image_machine_get "$image" .profile)
    [[ -z "$profile" ]] || profile_file "$profile" >/dev/null || _v_warn "$image's profile '$profile' not found: 2 cpus and 2048 MB unless set here"
  fi

  v=$(mach_setting "$id" cpus)
  [[ -z "$v" || "$v" =~ ^[1-9][0-9]*$ ]] || _v_err "cpus '$v' is not a number"
  v=$(mach_setting "$id" memory)
  [[ -z "$v" ]] || size_mb "$v" >/dev/null || _v_err "memory '$v' (8G, 512M, or a number of MB)"
  v=$(mach_setting "$id" disk)
  [[ -z "$v" || "$v" =~ ^[1-9][0-9]*[GM]$ ]] || _v_err "disk '$v' (40G, 512M)"
  v=$(mach_get "$id" .arch)
  case "$(arch_norm "$v")" in ""|arm64|amd64) ;; *) _v_err "arch '$v' (arm64 or amd64)" ;; esac

  while IFS= read -r v; do
    [[ -z "$v" || "$v" =~ ^[0-9]+:[0-9]+$ ]] || _v_err "ports: '$v' is not host:guest"
  done < <(mach_list "$id" .ports)
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    path=$(share_expand "$v"); path="${path%%:*}"; path="${path%/\*}"
    [[ -d "$path" ]] || _v_warn "shares: $path is not a directory here"
  done < <(mach_list "$id" .shares)

  validate_interfaces "$id"

  if [[ -n "$image" && "$V_ERRORS" -eq 0 ]]; then
    while IFS= read -r line; do [[ -z "$line" ]] || _v_err "$line"; done < <(min_problems "$id")
  fi
  return 0
}

# Validate one machine silently; on failure print its errors to stderr
validate_quiet() {
  local out
  V_ERRORS=0 V_WARNINGS=0
  out=$(validate_machine "$1"; echo "rc:$V_ERRORS")
  [[ "${out##*rc:}" == 0 ]] && return 0
  printf '%s\n' "${out%rc:*}" | grep '  error' >&2
  return 1
}

cmd_validate() {
  local spec id total_e=0 total_w=0 out counts
  local -a ids=()
  if [[ $# -eq 0 ]]; then
    while IFS= read -r id; do ids+=("$id"); done < <(effective_ids)
  else
    for spec in "$@"; do
      id=$(canon "$spec") || die "machine '$spec' is not defined (see: pmm list)"
      ids+=("$id")
    done
  fi
  # with no machine named, every network too
  local -a nets=()
  if [[ $# -eq 0 ]]; then
    while IFS= read -r id; do
      [[ "$(net_canon "${id#*/}")" != "$id" ]] || nets+=("$id")
    done < <(net_all_ids)
  fi
  [[ $(( ${#ids[@]} + ${#nets[@]} )) -gt 0 ]] || { echo "No machines to validate"; return 0; }
  for id in ${nets[@]+"${nets[@]}"}; do
    V_ERRORS=0 V_WARNINGS=0
    out=$(validate_network "$id"; echo "rc:$V_ERRORS:$V_WARNINGS")
    counts="${out##*rc:}"
    out="${out%rc:*}"
    total_e=$((total_e + ${counts%%:*}))
    total_w=$((total_w + ${counts##*:}))
    if [[ -n "${out//[$'\n']/}" ]]; then echo "network $id"; printf '%s' "$out"
    else echo "network $id ok"
    fi
  done
  for id in ${ids[@]+"${ids[@]}"}; do
    V_ERRORS=0 V_WARNINGS=0
    out=$(validate_machine "$id"; echo "rc:$V_ERRORS:$V_WARNINGS")
    counts="${out##*rc:}"
    out="${out%rc:*}"
    total_e=$((total_e + ${counts%%:*}))
    total_w=$((total_w + ${counts##*:}))
    if [[ -n "${out//[$'\n']/}" ]]; then echo "$id"; printf '%s' "$out"
    else echo "$id ok"
    fi
  done
  echo "${#ids[@]} machine(s)$([[ ${#nets[@]} -eq 0 ]] || echo ", ${#nets[@]} network(s)"): $total_e error(s), $total_w warning(s)"
  [[ $total_e -eq 0 ]]
}
