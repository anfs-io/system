#!/usr/bin/env bash
# anfs: stacks — manifests of resources, applied to a target (units/stacks)
#
# A stack is stacks/<name>/stack.yml in a source, resolved like any resource (source/name, or a
# bare name through the priority order):
#
#   version: 0.2.0
#   description: ...
#   stacks: [lgat/base]               # installed first; same or lower-priority source (ppm's rule)
#   packages: [stack/ruby]            # each key a resource directory, its value a list of
#   skills: [lgat/rails-conventions]  # source/name; an entry may be a one-key map with status:
#   vaults: [lgat/dev]
#   spaces:     [{ lgat/: { status: installed } }]    # installed|cloned
#   containers: [{ core/anfs-ui: { status: running } }]  # running|stopped (machines too)
#   machines: []
#
# The order is anfs's, not the manifest's: the stacks depended on (depth-first, each once), then
# STACK_KINDS. Each kind is installed by its tool, once, with all of that kind's resources.
#
# The record, $ANFS_STATE_HOME/stacks/<source>/<name>.yml, is what anfs remove reads: every resource
# the install touched, which stack brought it in, and whether it was there before (before: true is
# never removed, and neither is what another record holds).
#
# Requires paths.sh, sources.sh, resolve.sh and yq; table.sh for the lists. Functions only.

# Lines of fields with empty ones in them are joined by this, not a tab (read folds tabs)
_STACK_US=$'\x1f'
STACK_KINDS="packages skills vaults spaces containers machines"
STACK_BUILD_KINDS="packages skills"
ANFS_STACKS_STATE="$ANFS_STATE_HOME/stacks"

# The tool that installs a kind
stack_tool() {
  case "$1" in
    packages) echo ppm ;; skills) echo psm ;; vaults) echo pvm ;;
    spaces) echo wsm ;; containers) echo pcm ;; machines) echo pmm ;;
    *) return 1 ;;
  esac
}

_stack_fail() {
  ! declare -F anfs_fail >/dev/null || anfs_fail "$@"
  echo "anfs: ${*:2}" >&2
  exit "$1"
}

# --- the manifest --------------------------------------------------------------------------------

# Read and check <dir>/stack.yml of stack <q>: STACK_VERSION[q], STACK_DESC[q], STACK_RES[q]
# ("kind<TAB>resource<TAB>status" lines, kind order kept as written) and STACK_NEEDS[q] (the
# stacks: entries). Unknown keys, bad entries and statuses are 64.
declare -gA STACK_VERSION=() STACK_DESC=() STACK_RES=() STACK_NEEDS=() STACK_DIR=() STACK_DEPS=()
_stack_load() {
  local q="$1" dir="$2" file="$2/stack.yml" key line t name vtag status extra n
  [[ -f "$file" ]] || _stack_fail 1 "stack $q has no stack.yml ($(anfs_display "$dir"))"
  [[ "$(yq -r 'tag' "$file" 2>/dev/null)" == '!!map' ]] || _stack_fail 64 "stack $q: stack.yml is not a map"
  STACK_DIR[$q]="$dir"
  STACK_VERSION[$q]=$(yq -r '.version // ""' "$file")
  STACK_DESC[$q]=$(yq -r '.description // ""' "$file")
  STACK_RES[$q]="" STACK_NEEDS[$q]=""
  for key in $(yq -r 'keys | .[]' "$file"); do
    case "$key" in
      version|description) continue ;;
      stacks|packages|skills|vaults|spaces|containers|machines) ;;
      *) _stack_fail 64 "stack $q: unknown key '$key' (stack.yml takes version, description, stacks, $STACK_KINDS)" ;;
    esac
    t=$(K="$key" yq -r '.[strenv(K)] | tag' "$file")
    [[ "$t" != '!!null' ]] || continue
    [[ "$t" == '!!seq' ]] || _stack_fail 64 "stack $q: $key is not a list"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      IFS=$'\t' read -r t n name vtag status extra <<< "$line"
      [[ "$status" != "~" ]] || status=""
      case "$t" in
        S) name="$n" status="" ;;
        M)
          [[ "$n" == 1 ]] || _stack_fail 64 "stack $q: $key: an entry is a name or a one-key map"
          [[ "$vtag" == '!!null' || "$vtag" == '!!map' ]] ||
            _stack_fail 64 "stack $q: $key: $name: its value is a map ({ status: ... })"
          extra="${extra//status/}" extra="${extra//,/}"
          [[ -z "$extra" ]] || _stack_fail 64 "stack $q: $key: $name: only status: is allowed"
          ;;
        *) _stack_fail 64 "stack $q: $key: an entry is a name or a one-key map" ;;
      esac
      [[ -n "$name" ]] || _stack_fail 64 "stack $q: $key: an empty entry"
      if [[ -n "$status" ]]; then
        case "$key:$status" in
          containers:running|containers:stopped|machines:running|machines:stopped) ;;
          spaces:installed|spaces:cloned) ;;
          containers:*|machines:*) _stack_fail 64 "stack $q: $key: $name: status '$status' (running or stopped)" ;;
          spaces:*) _stack_fail 64 "stack $q: $key: $name: status '$status' (installed or cloned)" ;;
          *) _stack_fail 64 "stack $q: $key: $name: $key take no status" ;;
        esac
      fi
      if [[ "$key" == stacks ]]; then
        [[ -z "$status" ]] || _stack_fail 64 "stack $q: stacks: $name: stacks take no status"
        STACK_NEEDS[$q]+="$name"$'\n'
      else
        STACK_RES[$q]+="$key$_STACK_US$name$_STACK_US$status"$'\n'
      fi
    done < <(K="$key" yq -r '.[strenv(K)][] | ((select(tag == "!!str") | "S\t" + .) // (select(tag == "!!map") | "M\t" + (length | tostring) + "\t" + (to_entries | .[0] | .key + "\t" + (.value | tag) + "\t" + ((.value | select(tag == "!!map") | .status // "~") | tostring) + "\t" + ((.value | select(tag == "!!map") | keys | join(",")) // ""))) // ("X\t" + tag))' "$file")
  done
}

# --- resolving ------------------------------------------------------------------------------------

# The highest-priority stack <spec> names at or below source index <min>: "index<TAB>source<TAB>dir"
# into REPLY; false when there is none. Call anfs_sources stacks first.
stack_find() {
  local m
  m=$(anfs_find stacks "$1" "${2:-0}") || return 1
  REPLY="${m%%$'\n'*}"
}

# Resolve <spec>... with what they depend on, depth-first, each once, dependencies first:
# STACK_ORDER (source/name), STACK_TOP (the qualified names asked for), STACK_DEPS[q] (q's direct
# dependencies, qualified). A cycle is 1, naming the chain.
stack_resolve() {
  STACK_ORDER=() STACK_TOP=()
  declare -gA _STACK_DONE=() _STACK_ON=()
  anfs_sources stacks
  local spec
  for spec in "$@"; do
    _stack_visit "$spec" 0 ""
    STACK_TOP+=("$_STACK_LAST")
  done
}

_stack_visit() {
  local spec="$1" min="$2" chain="$3" idx src dir q need
  if ! stack_find "$spec" "$min"; then
    [[ -z "$chain" ]] || _stack_fail 1 "stack '$spec' not found (needed by ${chain##* -> }: a stack depends on its own source or a lower-priority one)"
    _stack_fail 1 "stack '$spec' not found (anfs list)"
  fi
  IFS=$'\t' read -r idx src dir <<< "$REPLY"
  _anfs_split "$spec"
  q="$src/$_ANFS_NAME"
  [[ -z "${_STACK_ON[$q]:-}" ]] || _stack_fail 1 "circular stack dependency: ${chain#* -> } -> $q"
  if [[ -n "${_STACK_DONE[$q]:-}" ]]; then _STACK_LAST="$q"; return 0; fi
  _STACK_ON[$q]=1
  _stack_load "$q" "$dir"
  STACK_DEPS[$q]=""
  while IFS= read -r need; do
    [[ -n "$need" ]] || continue
    _stack_visit "$need" "$idx" "$chain -> $q"
    STACK_DEPS[$q]+="$_STACK_LAST "
  done <<< "${STACK_NEEDS[$q]}"
  unset '_STACK_ON[$q]'
  _STACK_DONE[$q]=1
  STACK_ORDER+=("$q")
  _STACK_LAST="$q"
}

# <q> and every stack it depends on, space-separated
_stack_closure_set() {
  local q="$1" d
  local -A seen=()
  local -a todo=("$q")
  while [[ ${#todo[@]} -gt 0 ]]; do
    q="${todo[0]}" todo=("${todo[@]:1}")
    [[ -z "${seen[$q]:-}" ]] || continue
    seen[$q]=1
    for d in ${STACK_DEPS[$q]:-}; do todo+=("$d"); done
  done
  echo " ${!seen[*]} "
}

# The resources of the stacks <q>... bring in (each with what it depends on), in install order:
# kind by STACK_KINDS, then as the stacks were resolved. One "kind resource status from" line
# each (joined by $_STACK_US); a resource two stacks name is the first one's.
stack_resources() {
  local set="" q kind line k r s
  for q in "$@"; do set+="$(_stack_closure_set "$q")"; done
  local -A seen=()
  for kind in $STACK_KINDS; do
    for q in "${STACK_ORDER[@]}"; do
      [[ "$set" == *" $q "* ]] || continue
      while IFS="$_STACK_US" read -r k r s; do
        [[ "$k" == "$kind" && -z "${seen[$k|$r]:-}" ]] || continue
        seen[$k|$r]=1
        printf '%s\n' "$k$_STACK_US$r$_STACK_US$s$_STACK_US$q"
      done <<< "${STACK_RES[$q]}"
    done
  done
}

# --- what is there: the tools' lists, read with --json -------------------------------------------

# STACK_HAVE[kind] holds "resource<TAB>actual" lines for what the kind's tool has installed. A tool
# that is not installed has nothing.
declare -gA STACK_HAVE=()
stack_have_load() {
  local kind bin
  for kind in "$@"; do
    bin="$ANFS_BIN_DIR/$(stack_tool "$kind")"
    STACK_HAVE[$kind]=""
    [[ -x "$bin" ]] || continue
    case "$kind" in
      packages) STACK_HAVE[$kind]=$("$bin" list --installed --json </dev/null 2>/dev/null |
        yq -p json -r '.[] | select(.status != null) | .package + "\tinstalled"') || true ;;
      containers) STACK_HAVE[$kind]=$("$bin" list --json </dev/null 2>/dev/null |
        yq -p json -r '.[] | select(.status != null and .status != "shadowed") | .container + "\t" + (.status | sub(", shadowed$"; ""))') || true ;;
      machines) STACK_HAVE[$kind]=$("$bin" list --json </dev/null 2>/dev/null |
        yq -p json -r '.[] | select(.status == "running" or .status == "stopped") | .machine + "\t" + .status') || true ;;
      skills) STACK_HAVE[$kind]=$("$bin" list --json </dev/null 2>/dev/null |
        yq -p json -r '.[] | select(.status == "ok" or .status == "partial") | .skill + "\t" + (.status | sub("^ok$"; "installed"))') || true ;;
      spaces) STACK_HAVE[$kind]=$("$bin" list --json </dev/null 2>/dev/null |
        yq -p json -r '.[] | select(.dir != null) | .space + "\tinstalled"') || true ;;
    esac
  done
}

# The actual state of <resource> of <kind> into REPLY (a bare name matches any source's); false
# when it is not there. After stack_have_load.
stack_actual() {
  local kind="$1" want="$2" r a
  while IFS=$'\t' read -r r a; do
    [[ -n "$r" ]] || continue
    if [[ "$r" == "$want" || "$r" == */"$want" ]]; then REPLY="$a"; return 0; fi
  done <<< "${STACK_HAVE[$kind]:-}"
  REPLY=""
  return 1
}

# --- the record -----------------------------------------------------------------------------------

stack_record_file() { echo "$ANFS_STACKS_STATE/$1.yml"; }

# A record's resources: "kind<TAB>resource<TAB>from<TAB>before" lines
stack_record_resources() {
  yq -r '.resources[]? | .kind + "\t" + .resource + "\t" + .from + "\t" + (.before | tostring)' "$1"
}

# Every record but those of <q>...: their resources' "kind|resource" keys, one per line, with the
# stack holding each
_stack_held_elsewhere() {
  local f q skip=" $* " k r
  for f in "$ANFS_STACKS_STATE"/*/*.yml; do
    [[ -f "$f" ]] || continue
    q="${f#"$ANFS_STACKS_STATE"/}" q="${q%.yml}"
    [[ "$skip" != *" $q "* ]] || continue
    while IFS=$'\t' read -r k r _ _; do
      [[ -n "$k" ]] && printf '%s|%s\t%s\n' "$k" "$r" "$q"
    done < <(stack_record_resources "$f")
  done
}

# The stack holding <key> ("kind|resource") in <held> (from _stack_held_elsewhere) into REPLY
_stack_holder() {
  local key value
  while IFS=$'\t' read -r key value; do
    if [[ "$key" == "$2" ]]; then REPLY="$value"; return 0; fi
  done <<< "$1"
  return 1
}

# Write the record of <q> from REC_LINES[q] ("kind<TAB>resource<TAB>from<TAB>before" lines)
declare -gA REC_LINES=() REC_BUILD=()
_stack_record_write() {
  local q="$1" file k r f b
  file=$(stack_record_file "$q")
  mkdir -p "$(dirname "$file")"
  {
    echo "stack: $q"
    echo "version: \"${STACK_VERSION[$q]:-}\""
    echo "installed_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "build: ${REC_BUILD[$q]:-false}"
    echo "resources:"
    while IFS=$'\t' read -r k r f b; do
      [[ -n "$k" ]] && printf '  - { kind: %s, resource: "%s", from: "%s", before: %s }\n' "$k" "$r" "$f" "$b"
    done <<< "${REC_LINES[$q]:-}"
  } > "$file.tmp"
  mv "$file.tmp" "$file"
}

# --- the commands --------------------------------------------------------------------------------

_stack_target() {
  [[ -z "${1:-}" || "$1" == host ]] ||
    _stack_fail 64 "-t $1: only host for now (container: and machine: targets are plan 04)"
}

# `anfs install <stack>...`
stack_install() {
  local yes="$1" build="$2" target="$3"
  shift 3
  _stack_target "$target"
  local spec
  anfs_sources stacks
  for spec in "$@"; do
    stack_find "$spec" && continue
    if [[ "${spec%/}" != */* && "$(gitsrc_index "${spec%/}")" != 9999 ]]; then
      _stack_fail 64 "'$spec' is a source, not a stack: did you mean anfs src install ${spec%/}"
    fi
  done
  stack_resolve "$@"

  local kinds="$STACK_KINDS" line k r s f
  $build && kinds="$STACK_BUILD_KINDS"
  local -a rows=()
  mapfile -t rows < <(stack_resources "${STACK_TOP[@]}")

  # The tools the kinds need, before anything is installed
  local -A need=() vaults=()
  for line in "${rows[@]}"; do
    IFS="$_STACK_US" read -r k r s f <<< "$line"
    if [[ "$k" == vaults ]]; then vaults[$r]=1; continue; fi
    [[ " $kinds " == *" $k "* ]] && need[$k]=1
  done
  for k in $STACK_KINDS; do
    [[ -n "${need[$k]:-}" ]] || continue
    [[ -x "$ANFS_BIN_DIR/$(stack_tool "$k")" ]] ||
      _stack_fail 69 "$(stack_tool "$k") is not installed, and the stack has $k (ppm install core/$(stack_tool "$k"))"
  done
  stack_have_load "${!need[@]}"

  # The plan
  local deps=() q
  for q in "${STACK_ORDER[@]}"; do [[ " ${STACK_TOP[*]} " == *" $q "* ]] || deps+=("$q"); done
  printf 'anfs install %s%s%s:\n' "${STACK_TOP[*]}" "${deps[*]:+ (with ${deps[*]})}" "$($build && echo ', --build')"
  local -a there=()
  local -A todo=()
  for k in $STACK_KINDS; do
    [[ -n "${need[$k]:-}" ]] || continue
    local list=""
    for line in "${rows[@]}"; do
      IFS="$_STACK_US" read -r kk r s f <<< "$line"
      [[ "$kk" == "$k" ]] || continue
      if stack_actual "$k" "$r"; then there+=("$r"); else todo[$k]+="$r "; fi
      list+=" $r${s:+ ($s)}"
    done
    printf '  %-11s %s%s\n' "$k" "$(stack_tool "$k")" "$list"
  done
  [[ ${#there[@]} -eq 0 ]] || printf '  already installed: %s\n' "${there[*]}"
  if [[ ${#vaults[@]} -gt 0 ]]; then
    if $build; then
      printf '  --build: no vault is installed (%s)\n' "${!vaults[*]}"
    else
      printf '  vaults: not installed, pvm does not install vaults from sources yet (%s)\n' "${!vaults[*]}"
    fi
  fi
  # A stack is a group: the plan above is more than the names typed
  $yes || anfs_confirm "install changes this machine" "Install?"

  # The records: what each one held already (before is never flipped to false), and what was
  # there before this run and no other stack's record holds
  local held
  held=$(_stack_held_elsewhere "${STACK_ORDER[@]}")
  declare -A old=()
  for q in "${STACK_ORDER[@]}"; do
    local file
    file=$(stack_record_file "$q")
    REC_LINES[$q]="" REC_BUILD[$q]=$build
    [[ -f "$file" ]] || continue
    REC_LINES[$q]=$(stack_record_resources "$file")$'\n'
    [[ "$(yq -r '.build' "$file")" == true ]] || REC_BUILD[$q]=false
    while IFS=$'\t' read -r k r f b; do [[ -n "$k" ]] && old[$q|$k|$r]=1; done <<< "${REC_LINES[$q]}"
  done
  local -A before=()
  for line in "${rows[@]}"; do
    IFS="$_STACK_US" read -r k r s f <<< "$line"
    before[$k|$r]=false
    if stack_actual "$k" "$r" && ! _stack_holder "$held" "$k|$r"; then before[$k|$r]=true; fi
  done

  local rc=0 closure
  local -a items
  for k in $STACK_KINDS; do
    [[ -n "${need[$k]:-}" ]] || continue
    read -ra items <<< "${todo[$k]:-}"
    if [[ ${#items[@]} -gt 0 ]]; then
      echo "== $(stack_tool "$k") install ${items[*]}"
      _stack_install_kind "$k" "${items[@]}" || rc=1
    fi
    # Recorded as the install goes, so a failed one leaves what it did
    for q in "${STACK_ORDER[@]}"; do
      closure=$(_stack_closure_set "$q")
      for line in "${rows[@]}"; do
        IFS="$_STACK_US" read -r kk r s f <<< "$line"
        [[ "$kk" == "$k" && "$closure" == *" $f "* && -z "${old[$q|$k|$r]:-}" ]] || continue
        REC_LINES[$q]+="$k"$'\t'"$r"$'\t'"$f"$'\t'"${before[$k|$r]}"$'\n'
        old[$q|$k|$r]=1
      done
      _stack_record_write "$q"
    done
  done

  $build || _stack_apply_status "${rows[@]}" || rc=1
  return $rc
}

_stack_install_kind() {
  local k="$1" bin r
  shift
  bin="$ANFS_BIN_DIR/$(stack_tool "$k")"
  case "$k" in
    # -y: a stack may hold a whole source (source/), which each tool asks about
    # wsm installs one level per run
    spaces) local rc=0; for r in "$@"; do "$bin" install -y "$r" || rc=1; done; return $rc ;;
    *) "$bin" install -y "$@" ;;
  esac
}

# The status: entries: pcm up|stop, pmm up|stop, and a cloned space's repositories
_stack_apply_status() {
  local line k r s f rc=0
  local -A by=()
  for line in "$@"; do
    IFS="$_STACK_US" read -r k r s f <<< "$line"
    [[ -n "$s" ]] || continue
    case "$k:$s" in
      containers:running) by[pcm up]+="$r " ;;
      containers:stopped) by[pcm stop]+="$r " ;;
      machines:running)   by[pmm up]+="$r " ;;
      machines:stopped)   by[pmm stop]+="$r " ;;
      spaces:cloned)      by[wsm repo install]+="$r " ;;
    esac
  done
  local cmd
  local -a items
  for cmd in "pcm up" "pcm stop" "pmm up" "pmm stop" "wsm repo install"; do
    [[ -n "${by[$cmd]:-}" ]] || continue
    read -ra items <<< "${by[$cmd]}"
    echo "== $cmd ${items[*]}"
    if [[ "$cmd" == "wsm repo install" ]]; then
      for r in "${items[@]}"; do "$ANFS_BIN_DIR/wsm" repo install "$r" || rc=1; done
    else
      # shellcheck disable=SC2086
      "$ANFS_BIN_DIR/${cmd%% *}" ${cmd#* } "${items[@]}" || rc=1
    fi
  done
  return $rc
}

# The installed stack <spec> names (a record), qualified, into REPLY
_stack_installed_name() {
  local spec="$1" f
  local -a hits=()
  if [[ "$spec" == */* ]]; then
    [[ -f "$(stack_record_file "$spec")" ]] || _stack_fail 1 "stack $spec is not installed (anfs list)"
    REPLY="$spec"
    return 0
  fi
  for f in "$ANFS_STACKS_STATE"/*/"$spec".yml; do [[ -f "$f" ]] && hits+=("$f"); done
  [[ ${#hits[@]} -gt 0 ]] || _stack_fail 1 "stack $spec is not installed (anfs list)"
  [[ ${#hits[@]} -eq 1 ]] || _stack_fail 64 "more than one stack $spec is installed: name it source/$spec"
  f="${hits[0]#"$ANFS_STACKS_STATE"/}"
  REPLY="${f%.yml}"
}

# `anfs remove <stack>...`: what the records say these installed, that was not there before and
# no other record holds; in reverse order. STACK_REMOVE_KEEP ("kind|resource" words) is kept too:
# implode's, for ppm and anfs, which ppm implode removes after
stack_remove() {
  local yes="$1" target="$2" spec q
  shift 2
  _stack_target "$target"
  local -a names=()
  for spec in "$@"; do _stack_installed_name "$spec"; names+=("$REPLY"); done

  local held line k r f b
  held=$(_stack_held_elsewhere "${names[@]}")
  stack_have_load $STACK_KINDS
  local -a rows=() keep=()
  local -A seen=()
  for q in "${names[@]}"; do
    while IFS=$'\t' read -r k r f b; do
      [[ -n "$k" && -z "${seen[$k|$r]:-}" ]] || continue
      seen[$k|$r]=1
      if [[ "$b" == true ]]; then keep+=("$k $r: there before $q"); continue; fi
      if [[ " ${STACK_REMOVE_KEEP:-} " == *" $k|$r "* ]]; then keep+=("$k $r: removed last"); continue; fi
      if _stack_holder "$held" "$k|$r"; then keep+=("$k $r: $REPLY holds it"); continue; fi
      if ! stack_actual "$k" "$r"; then keep+=("$k $r: already gone"); continue; fi
      rows+=("$k"$'\t'"$r")
    done < <(stack_record_resources "$(stack_record_file "$q")")
  done

  echo "anfs remove ${names[*]}:"
  local -A todo=()
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r k r <<< "$line"
    todo[$k]="$r ${todo[$k]:-}"
  done
  local rev="" any=false
  for k in $STACK_KINDS; do rev="$k $rev"; done
  for k in $rev; do
    [[ -n "${todo[$k]:-}" ]] || continue
    printf '  remove %-11s %s %s\n' "$k" "$(stack_tool "$k")" "${todo[$k]% }"
    any=true
  done
  $any || echo "  nothing to remove"
  for line in ${keep[@]+"${keep[@]}"}; do printf '  keep   %s\n' "$line"; done
  if $any && ! $yes; then anfs_confirm "remove changes this machine" "Remove?"; fi

  local rc=0 bin
  local -a items
  for k in $rev; do
    [[ -n "${todo[$k]:-}" ]] || continue
    bin="$ANFS_BIN_DIR/$(stack_tool "$k")"
    read -ra items <<< "${todo[$k]}"
    echo "== $(stack_tool "$k") remove ${items[*]}"
    # Confirmed above: every tool's remove asks
    "$bin" remove -y "${items[@]}" || rc=1
  done
  if [[ $rc -eq 0 ]]; then
    for q in "${names[@]}"; do
      rm -f "$(stack_record_file "$q")"
      rmdir "$(dirname "$(stack_record_file "$q")")" 2>/dev/null || true
    done
  else
    echo "anfs: a tool failed; the records are kept (remove again once it is fixed)" >&2
  fi
  return $rc
}

# The installed stacks (their records), the last installed first: reverse install order
stack_installed_reverse() {
  local f q
  for f in "$ANFS_STACKS_STATE"/*/*.yml; do
    [[ -f "$f" ]] || continue
    q="${f#"$ANFS_STACKS_STATE"/}" q="${q%.yml}"
    printf '%s\t%s\n' "$(yq -r '.installed_at // ""' "$f")" "$q"
  done | LC_ALL=C sort -r | cut -f2
}

# installed, partial or - for stack <q>, after stack_have_load
_stack_status() {
  local file k r
  file=$(stack_record_file "$1")
  [[ -f "$file" ]] || { echo -; return 0; }
  while IFS=$'\t' read -r k r _ _; do
    [[ -n "$k" ]] || continue
    stack_actual "$k" "$r" || { echo partial; return 0; }
  done < <(stack_record_resources "$file")
  echo installed
}

# `anfs list`: STACK STATUS VERSION, every stack in every source, and installed ones whose
# definition is gone
stack_list() {
  local q f v
  anfs_sources stacks
  [[ ! -d "$ANFS_STACKS_STATE" ]] || stack_have_load $STACK_KINDS
  local -A listed=()
  {
    while IFS= read -r q; do
      [[ -n "$q" ]] || continue
      listed[$q]=1
      v=""
      [[ ! -f "$(gitsrc_dir "${q%%/*}")/stacks/${q#*/}/stack.yml" ]] ||
        v=$(yq -r '.version // ""' "$(gitsrc_dir "${q%%/*}")/stacks/${q#*/}/stack.yml" 2>/dev/null) || v=""
      anfs_row "$q" "$(_stack_status "$q")" "$v"
    done < <(anfs_list stacks)
    for f in "$ANFS_STACKS_STATE"/*/*.yml; do
      [[ -f "$f" ]] || continue
      q="${f#"$ANFS_STACKS_STATE"/}" q="${q%.yml}"
      [[ -z "${listed[$q]:-}" ]] || continue
      anfs_row "$q" "$(_stack_status "$q")" "$(yq -r '.version // ""' "$f")"
    done
  } | anfs_table "STACK STATUS VERSION" "stack status version"
}

# `anfs show <stack>`: its resources through its stacks, in install order, declared vs actual
stack_show() {
  stack_resolve "$1"
  local q="${STACK_TOP[0]}" line k r s f
  local -a rows=()
  mapfile -t rows < <(stack_resources "$q")
  stack_have_load $STACK_KINDS
  if ! anfs_json_on; then
    echo "$q${STACK_VERSION[$q]:+ ${STACK_VERSION[$q]}}${STACK_DESC[$q]:+: ${STACK_DESC[$q]}}"
  fi
  {
    local d
    for d in "${STACK_ORDER[@]}"; do
      [[ "$d" != "$q" ]] || continue
      local by="$q" p
      for p in "${STACK_ORDER[@]}"; do [[ " ${STACK_DEPS[$p]:-} " != *" $d "* ]] || { by="$p"; break; }; done
      local st
      st=$(_stack_status "$d")
      anfs_row stacks "$d" "" "${st#-}" "$by"
    done
    for line in ${rows[@]+"${rows[@]}"}; do
      IFS="$_STACK_US" read -r k r s f <<< "$line"
      stack_actual "$k" "$r" || true
      anfs_row "$k" "$r" "$s" "$REPLY" "$f"
    done
  } | anfs_table "KIND RESOURCE DECLARED ACTUAL FROM" "kind resource declared actual from"
}

# `anfs path <stack>`
stack_path() {
  anfs_sources stacks
  stack_find "$1" || _stack_fail 1 "stack '$1' not found (anfs list)"
  printf '%s\n' "${REPLY##*$'\t'}"
}
