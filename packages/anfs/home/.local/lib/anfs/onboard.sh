#!/usr/bin/env bash
# anfs onboard: from a fresh install to a machine that is yours
#
# install.sh leaves the tools and the shipped sources, and nothing about the person. onboard walks
# through what makes the machine theirs, one step at a time. anfs itself knows two steps:
#
#   packages   what the sources offer and is not installed (a package's `onboard.offer`)
#   repo       your own repo, the "user" source: started on this machine, or one you have
#
# Every other step belongs to an installed package, which declares it in package.yml (`onboard:`)
# and implements it in its install.sh: stack/git brings your git identity and GitHub, stack/ssh
# your key, stack/op 1Password. The contract is in lib/ppm/onboard.sh. anfs knows none of them by
# name: it reads the declarations, orders the steps by their `after:` and `before:`, and runs
# each through `ppm __onboard`.
#
# Every step is detect, propose, apply. Nothing is recorded: a step looks at the machine each
# time, so a rerun does only what is still missing, and `anfs onboard --check` is the detects
# alone. What steps learn (your name, your public key, the vault) they hand on through a facts
# file that lasts for the run.
#
# Every answer has an option, declared by the package whose step asks, so it runs without a
# terminal: -y takes the proposals, and a question no option answered is a usage error.
#
# Sourced by the anfs command, which provides tool() (the other tools, from ~/.local/bin),
# _login_shell() and the gitsrc_* functions already set up for anfs's lists.

# The alias your own repo always has: ppm's PPM_USER_REPO_ALIAS (lib/ppm/core.sh)
ONBOARD_USER_ALIAS=user
_OB_SEP="|"

# The steps of this run, in order: name, the package it is from (empty: anfs's own), summary
OB_NAMES=() OB_PKGS=() OB_SUMMARIES=()
OB_FACTS=""

# --- facts -------------------------------------------------------------------------------------

_ob_get() {
  awk -v k="$1" 'index($0, k "\t") == 1 { v = substr($0, length(k) + 2) } END { if (v != "") print v }' "$OB_FACTS"
}
_ob_set()    { printf '%s\t%s\n' "$1" "${2//$'\n'/ }" >> "$OB_FACTS"; }
_ob_detail() { _ob_set _detail "$*"; }
_ob_state()  { _ob_set _state "$1"; }

_ob_facts_start() {
  local key
  OB_FACTS=$(mktemp "${TMPDIR:-/tmp}/anfs-onboard.XXXXXX")
  anfs_on_exit 'rm -f "$OB_FACTS"'
  for key in "${!CLI_OPT[@]}"; do
    _ob_set "opt.$key" "${CLI_OPT[$key]}"
  done
}

# Go ahead with a step? True at once with -y. Unlike anfs_confirm a no is not the end of the
# run: the step is skipped and the next one is offered.
_ob_propose() {
  local answer
  ! ${CLI_OPT[yes]:-false} || return 0
  [[ -t 0 ]] || anfs_die "$1: pass -y to go ahead without a terminal"
  read -r -p "$1? [Y/n] " answer
  [[ "$answer" != [nN]* ]]
}

# --- what the sources declare ------------------------------------------------------------------

# Every package.yml of every source, the higher-priority source first
_ob_all_ymls() {
  local name file
  gitsrc_collect
  for name in ${GITSRC_NAMES[@]+"${GITSRC_NAMES[@]}"}; do
    for file in "$ANFS_SOURCES_HOME/$name"/packages/*/package.yml; do
      [[ -f "$file" ]] && printf '%s\n' "$file"
    done
  done
  return 0
}

# The package.yml of every installed package (ppm's trackers are installed/<repo>/<pkg>.yml)
_ob_installed_ymls() {
  local tracker file
  for tracker in "$XDG_STATE_HOME"/ppm/installed/*/*.yml; do
    [[ -f "$tracker" ]] || continue
    file="$ANFS_SOURCES_HOME/$(basename "$(dirname "$tracker")")/packages/$(basename "$tracker" .yml)/package.yml"
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
  return 0
}

# repo/pkg of a package.yml path
_ob_qualified() {
  local rel="${1#"$ANFS_SOURCES_HOME"/}"
  rel="${rel%/package.yml}"
  printf '%s\n' "${rel/\/packages\//\/}"
}

_ob_pkg_installed() {
  compgen -G "$XDG_STATE_HOME/ppm/installed/*/${1##*/}.yml" >/dev/null
}

# The option specs packages declare (onboard.options), each once. From every package, installed
# or not: `anfs onboard --install op --vault Dev` must know --vault before op is there.
onboard_options() {
  local -a files=()
  command -v yq >/dev/null 2>&1 || return 0
  mapfile -t files < <(_ob_all_ymls)
  [[ ${#files[@]} -gt 0 ]] || return 0
  yq -N -r '.onboard.options[]?' "${files[@]}" 2>/dev/null | awk 'NF && !seen[$0]++'
}

# Lines "repo/pkg|offer" for what is offered and not installed; a package name counts once
_ob_offers() {
  local -a files=()
  local file offer qualified seen=" "
  mapfile -t files < <(_ob_all_ymls)
  [[ ${#files[@]} -gt 0 ]] || return 0
  while IFS="$_OB_SEP" read -r file offer; do
    [[ -n "$file" && -n "$offer" ]] || continue
    qualified=$(_ob_qualified "$file")
    [[ "$seen" != *" ${qualified##*/} "* ]] || continue
    seen="$seen${qualified##*/} "
    _ob_pkg_installed "$qualified" || printf '%s%s%s\n' "$qualified" "$_OB_SEP" "$offer"
  done < <(yq -N -r 'select(.onboard.offer != null) | [filename, .onboard.offer] | join("|")' "${files[@]}" 2>/dev/null)
}

# Fill OB_NAMES, OB_PKGS and OB_SUMMARIES: anfs's repo step and every installed package's steps,
# ordered so that each comes after what it names in `after:` and before what it names in
# `before:`. Otherwise the order is the one they were found in. A cycle is cut where it is met.
_ob_discover() {
  local -a files=() names=() pkgs=() sums=() afters=() befores=() placed=()
  local file name after before summary i j n ready pick dep last=""

  names=(repo) pkgs=("") sums=("Your own repo, the '$ONBOARD_USER_ALIAS' source") afters=("") befores=("")
  mapfile -t files < <(_ob_installed_ymls)
  if [[ ${#files[@]} -gt 0 ]]; then
    while IFS="$_OB_SEP" read -r file name after before summary; do
      [[ -n "$file" && -n "$name" ]] || continue
      names+=("$name") pkgs+=("$(_ob_qualified "$file")") sums+=("$summary")
      afters+=("$after") befores+=("$before")
    done < <(yq -N -r '.onboard.steps[]? | [filename, .name, ((.after // []) | join(" ")), ((.before // []) | join(" ")), (.summary // "")] | join("|")' "${files[@]}" 2>/dev/null)
  fi

  # before: [x] on a step is after: [it] on x
  n=${#names[@]}
  for ((i = 0; i < n; i++)); do
    for dep in ${befores[$i]}; do
      for ((j = 0; j < n; j++)); do
        [[ "${names[$j]}" != "$dep" ]] || afters[$j]="${afters[$j]} ${names[$i]}"
      done
    done
  done

  OB_NAMES=() OB_PKGS=() OB_SUMMARIES=()
  for ((i = 0; i < n; i++)); do placed[$i]=false; done
  while [[ ${#OB_NAMES[@]} -lt $n ]]; do
    # Of the steps that wait on nothing: the next one of the package just placed, so a
    # package's steps stay together where they can; else the first as it was found
    pick=-1
    for ((i = 0; i < n; i++)); do
      ! ${placed[$i]} || continue
      ready=true
      for dep in ${afters[$i]}; do
        for ((j = 0; j < n; j++)); do
          if [[ "${names[$j]}" == "$dep" && $j -ne $i ]] && ! ${placed[$j]}; then ready=false; fi
        done
      done
      $ready || continue
      [[ $pick -ge 0 ]] || pick=$i
      if [[ -n "$last" && "${pkgs[$i]}" == "$last" ]]; then pick=$i; break; fi
    done
    # Nothing is ready: the steps left wait on each other. Take the first as it was found.
    if [[ $pick -lt 0 ]]; then
      for ((i = 0; i < n; i++)); do
        if ! ${placed[$i]}; then pick=$i; break; fi
      done
    fi
    placed[$pick]=true
    last="${pkgs[$pick]}"
    OB_NAMES+=("${names[$pick]}") OB_PKGS+=("${pkgs[$pick]}") OB_SUMMARIES+=("${sums[$pick]}")
  done
}

# --- packages: what is on offer ----------------------------------------------------------------

_onboard_packages_detect() {
  local offers list=""
  offers=$(_ob_offers)
  if [[ -z "$offers" ]]; then
    _ob_detail "nothing more on offer"
    return 0
  fi
  list=$(cut -d"$_OB_SEP" -f1 <<< "$offers" | tr '\n' ' ')
  _ob_detail "on offer: ${list% } (--install)"
  _ob_state optional
  return 1
}

# Never on -y alone: what gets installed is picked, or named with --install
_onboard_packages() {
  local wanted="${CLI_OPT[install]:-}" offers line qualified answer i
  local -a all=() pick=()
  offers=$(_ob_offers)
  [[ -n "$offers" ]] || { _ob_detail "nothing more on offer"; return 0; }
  mapfile -t all <<< "$offers"

  if [[ -n "$wanted" ]]; then
    for line in "${all[@]}"; do
      qualified="${line%%"$_OB_SEP"*}"
      if grep -qxF -e all -e "$qualified" -e "${qualified##*/}" <<< "${wanted// /$'\n'}"; then
        pick+=("$qualified")
      fi
    done
  elif [[ -t 0 ]] && ! ${CLI_OPT[yes]:-false}; then
    echo "On offer:" >&2
    for i in "${!all[@]}"; do
      printf '  %d) %-18s %s\n' "$((i + 1))" "${all[$i]%%"$_OB_SEP"*}" "${all[$i]#*"$_OB_SEP"}" >&2
    done
    read -r -p "Install which? (numbers, 'all', Enter for none): " answer
    for i in $answer; do
      if [[ "$i" == all ]]; then
        pick=("${all[@]%%"$_OB_SEP"*}")
        break
      fi
      [[ "$i" =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#all[@]} )) || anfs_die "'$i' is not one of 1-${#all[@]}; nothing installed"
      pick+=("${all[$((i - 1))]%%"$_OB_SEP"*}")
    done
  fi

  if [[ ${#pick[@]} -gt 0 ]]; then
    tool ppm install "${pick[@]}" || anfs_die "ppm install ${pick[*]} failed"
    hash -r
  fi
  _onboard_packages_detect
}

# --- repo: your own -----------------------------------------------------------------------------

# What the user source is listed as (a git URL or a path), or nothing
_ob_user_entry() {
  local i
  gitsrc_collect
  i=$(gitsrc_index "$ONBOARD_USER_ALIAS")
  [[ "$i" == 9999 ]] || printf '%s\n' "${GITSRC_URLS[$i]}"
}

# True when ppm was told to leave a $HOME-relative path alone (ppm file protect)
_ob_protected() {
  local file="$XDG_STATE_HOME/ppm/installed/protected.yml" list
  [[ -s "$file" ]] || return 1
  list=$(yq -r '.[]' "$file" 2>/dev/null || true)
  grep -qxF -- "$1" <<< "$list"
}

_onboard_repo_detect() {
  local entry
  entry=$(_ob_user_entry)
  if [[ -z "$entry" ]]; then
    _ob_detail "no '$ONBOARD_USER_ALIAS' source"
    return 1
  fi
  gitsrc_is_git_url "$entry" || entry="$(anfs_display "$entry") (on this machine only)"
  _ob_detail "$entry"
}

_ob_commit() {
  local dir="$1" msg="$2" user name email
  user=$(id -un)
  name=$(_ob_get name) email=$(_ob_get email)
  git -C "$dir" add -A
  ! git -C "$dir" diff --cached --quiet || return 0
  git -C "$dir" -c user.name="${name:-$user}" -c user.email="${email:-$user@$(hostname -s)}" \
    commit -q -m "$msg"
}

# Start your own repo: a git repo at sources/user with an anfs package (a layer of the shipped
# one) that holds user.list, stowed, so your source list lives in your repo from here on.
_onboard_repo_init() {
  local alias="$ONBOARD_USER_ALIAS" dir="$1"
  local config_dir="$dir/packages/anfs/home/.config/anfs"

  if [[ -e "$dir" ]]; then
    anfs_warn "$dir exists but is not a listed source; list it (anfs src add --top $dir $alias) or move it away"
    return 1
  fi
  if [[ -L "$ANFS_USER_LIST" ]]; then
    anfs_warn "$ANFS_USER_LIST is already a link into a package ($(readlink "$ANFS_USER_LIST"))"
    return 1
  fi
  if _ob_protected "${ANFS_USER_LIST#"$HOME"/}"; then
    anfs_warn "$ANFS_USER_LIST is protected; run 'ppm file unprotect' on it first"
    return 1
  fi

  mkdir -p "$config_dir"
  git -C "$dir" init -q
  printf 'version: 0.1.0\nauthor: %s\n' "$(id -un)" > "$dir/packages/anfs/package.yml"

  # At the top of the list, as a local path: never pulled until it has a remote. The repo's copy
  # of the list must list the repo itself, or once it is stowed nothing registers the source.
  gitsrc_add --top "$dir" "$alias" >/dev/null
  cp "$ANFS_USER_LIST" "$config_dir/user.list"
  # -f swaps the plain user.list for the link into the repo (ppm keeps the plain one as a backup)
  tool ppm install -f "$alias/anfs" || anfs_die "ppm install -f $alias/anfs failed"
  _ob_commit "$dir" "anfs onboard: the user source"
}

# A repo you already have: listed first, cloned, and its anfs package stowed over the seeded list
# (what install.sh --repo does)
_onboard_repo_use() {
  local alias="$ONBOARD_USER_ALIAS" url="$1" dir="$2"
  gitsrc_add --top "$url" "$alias"
  gitsrc_update "$alias" || anfs_die "could not clone $url"
  if [[ -d "$dir/packages/anfs" ]]; then
    tool ppm install -f "$alias/anfs" || anfs_die "ppm install -f $alias/anfs failed"
  else
    anfs_warn "$url has no anfs package; ~/.config/anfs keeps the seeded user.list"
  fi
}

# --repo local starts one here; --repo new does the same and tells whichever package can publish
# it (stack/git, on GitHub) to do so; anything else is the URL of one you have.
_onboard_repo() {
  local mode="${CLI_OPT[repo]:-}" dir="$ANFS_SOURCES_HOME/$ONBOARD_USER_ALIAS"
  ! _onboard_repo_detect || return 0

  if [[ -z "$mode" ]]; then
    anfs_choose --repo "Your own repo: your packages, containers and skills, and this machine's source list" \
      "local: start one on this machine" "existing: I have one"
    mode="$REPLY"
    if [[ "$mode" == existing ]]; then
      anfs_ask --repo "Its git URL"
      mode="$REPLY"
    fi
  fi

  case "$mode" in
    new|local)
      _ob_propose "Start your repo at $(anfs_display "$dir")" || return 1
      _onboard_repo_init "$dir" || return 1
      ;;
    *)
      gitsrc_is_git_url "$mode" || [[ -d "$mode" ]] || cli_usage_err "--repo is local, new, or a git URL, not '$mode'"
      _onboard_repo_use "$mode" "$dir"
      ;;
  esac
  _onboard_repo_detect
}

# --- the walk ----------------------------------------------------------------------------------

# Not a step: install.sh installs your login shell's package, and without one nothing puts
# Homebrew on an interactive shell's PATH. Reported so --check says why brew is "not found".
_onboard_shell_detect() {
  local shell
  shell=$(_login_shell 2>/dev/null || true)
  shell="${shell##*/}"
  if [[ -z "$shell" ]]; then
    _ob_detail "login shell unknown"
    _ob_state n/a
    return 0
  fi
  if _ob_pkg_installed "$shell"; then
    _ob_detail "$shell"
    return 0
  fi
  _ob_detail "no package installed for $shell (ppm install $shell)"
  return 1
}

# Run one step's detect, or the step itself (apply). A package's runs in ppm; anfs's own here.
# True when the step is done. A status past 1 is the step refusing to go on (64: a question
# no option answered), and ends the walk with it.
_ob_step() {
  local name="$1" pkg="$2" mode="$3" fn rc=0
  _ob_set _detail ""
  _ob_set _state ""
  if [[ -z "$pkg" ]]; then
    fn="_onboard_$name"
    [[ "$mode" != detect ]] || fn="${fn}_detect"
    "$fn" || rc=$?
  else
    fn="onboard_${name//-/_}"
    [[ "$mode" != detect ]] || fn="${fn}_detect"
    ANFS_ONBOARD_FACTS="$OB_FACTS" ANFS_ONBOARD_YES="${CLI_OPT[yes]:-false}" \
      tool ppm __onboard "$pkg" "$fn" || rc=$?
  fi
  [[ $rc -le 1 ]] || exit "$rc"
  return $rc
}

complete_step() {
  _ob_discover 2>/dev/null || true
  printf '%s\n' packages ${OB_NAMES[@]+"${OB_NAMES[@]}"}
}

cmd_onboard() {
  local check=${CLI_OPT[check]:-false} name pkg state said rows="" rc=0 i
  local -a want=("$@")

  command -v yq >/dev/null 2>&1 || anfs_die "onboard needs yq, which install.sh installs (is Homebrew on your PATH?)"
  _ob_facts_start
  _ob_wanted() { [[ ${#want[@]} -eq 0 || " ${want[*]} " == *" $1 "* ]]; }

  # First, and whenever --install names something: what is installed here may bring steps of
  # its own, which this same walk then takes (and which may be the very steps that were named)
  if ! $check && { _ob_wanted packages || [[ -n "${CLI_OPT[install]:-}" ]]; }; then
    anfs_info "== packages"
    _ob_step packages "" apply || true
    anfs_info "   $(_ob_get _detail)"
  fi
  _ob_discover
  for name in "$@"; do
    [[ " packages ${OB_NAMES[*]} " == *" $name "* ]] ||
      cli_usage_err "'$name' is not a step (packages ${OB_NAMES[*]})"
  done

  if ! $check; then
    # Every step is looked at, in order, because a later one needs what an earlier one found
    # (GitHub your key, the repo your name); only the named ones may change anything
    for i in "${!OB_NAMES[@]}"; do
      name="${OB_NAMES[$i]}"
      if _ob_wanted "$name"; then
        anfs_info "== $name${OB_SUMMARIES[$i]:+: ${OB_SUMMARIES[$i]}}"
        _ob_step "$name" "${OB_PKGS[$i]}" apply || true
        anfs_info "   $(_ob_get _detail)"
      else
        _ob_step "$name" "${OB_PKGS[$i]}" detect || true
      fi
    done
    anfs_info ""
  fi

  for i in -2 -1 "${!OB_NAMES[@]}"; do
    case "$i" in
      -2) name=shell pkg="" ;;
      -1) name=packages pkg="" ;;
      *) name="${OB_NAMES[$i]}" pkg="${OB_PKGS[$i]}" ;;
    esac
    if _ob_step "$name" "$pkg" detect; then state=ok; else state=todo; fi
    said=$(_ob_get _state)
    [[ -z "$said" ]] || state="$said"
    [[ "$state" != todo ]] || rc=1
    rows+="$(anfs_row "$name" "$pkg" "$state" "$(_ob_get _detail)")"$'\n'
  done
  printf '%s' "$rows" | anfs_table "STEP PACKAGE STATUS DETAIL" "step package status detail"

  if ! $check && ! anfs_json_on; then
    anfs_info ""
    anfs_info "Open a new shell for what was installed to be on your PATH."
  fi
  return $rc
}
