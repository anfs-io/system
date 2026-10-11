#!/usr/bin/env bash
# pim library: installing anfs in an image while it is built (image.yml's anfs: key).
# Sourced by ~/.local/bin/pim; functions only.
#
#   anfs:
#     sources: pushed       install.sh from GitHub; the guest clones every source itself (default)
#            | host         the host's source clones are copied in, in the host's priority order:
#                           the image gets exactly this machine's sources, offline
#     repo: <git url>       a customization repo (install.sh --repo)
#     packages: [stack/zsh]   installed after the toolkit
#
# It runs as the image's user (who has passwordless sudo, so install.sh's prompts don't block),
# after the image's scripts and before finalize.

: "${PIM_ANFS_INSTALLER_URL:=https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh}"

img_has_anfs() { [[ "$(yq -r 'has("anfs")' "$(img_yml "$1")" 2>/dev/null)" == true ]]; }

# What host-sourced anfs content goes into the build key: each source's commit and local changes
anfs_host_fingerprint() {
  local i name dir
  gitsrc_collect
  for i in ${GITSRC_NAMES[@]+"${!GITSRC_NAMES[@]}"}; do
    name="${GITSRC_NAMES[$i]}"
    dir=$(gitsrc_dir "$name")
    [[ -d "$dir" ]] || continue
    printf '%s %s %s\n' "$name" "$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo -)" \
      "$(git -C "$dir" status --porcelain 2>/dev/null | _sha256 | cut -c1-12)"
  done
}

# Usage: build_anfs_step <id> <key> <port> <user> <log>   (called by the build)
build_anfs_step() {
  local id="$1" key="$2" port="$3" user="$4" log="$5" mode repo pkgs script
  img_has_anfs "$id" || return 0
  mode=$(img_get "$id" .anfs.sources pushed)
  repo=$(img_get "$id" .anfs.repo)
  pkgs=$(img_list "$id" .anfs.packages | paste -sd' ' -)
  script="$PIM_STATE_HOME/build/$(img_name "$id")-anfs.sh"

  case "$mode" in
    host)
      local i name dir list=""
      gitsrc_collect
      for i in ${GITSRC_NAMES[@]+"${!GITSRC_NAMES[@]}"}; do
        name="${GITSRC_NAMES[$i]}"
        dir=$(gitsrc_dir "$name")
        [[ -d "$dir" ]] || continue
        printf '== anfs: copying source %s' "$name"
        push_dir "$key" "$port" "$user" "$(cd "$dir" && pwd -P)" ".local/share/anfs/sources/$name" >> "$log" 2>&1 ||
          die "copying source $name into the guest failed"
        echo
        if gitsrc_is_git_url "${GITSRC_URLS[$i]}"; then list+="${GITSRC_URLS[$i]}  $name"$'\n'
        else list+="\$HOME/.local/share/anfs/sources/$name  $name"$'\n'
        fi
      done
      {
        echo 'set -euo pipefail'
        echo 'mkdir -p ~/.config/anfs'
        printf 'cat > ~/.config/anfs/user.list <<LIST\n%sLIST\n' "$list"
        echo "bash ~/.local/share/anfs/sources/core/install.sh ${repo:+--repo $(shq "$repo")} $pkgs"
      } > "$script"
      ;;
    pushed)
      {
        echo 'set -euo pipefail'
        echo "curl -fsSL $(shq "$PIM_ANFS_INSTALLER_URL") | bash -s -- ${repo:+--repo $(shq "$repo")} $pkgs"
      } > "$script"
      ;;
    *) die "$id: anfs.sources must be host or pushed, not '$mode'" ;;
  esac

  # As the user, not root: install.sh refuses root, and the toolkit belongs to the user
  local start rc=0
  start=$(date +%s)
  printf '== anfs install (%s%s)' "$mode" "${pkgs:+: $pkgs}"
  echo "== anfs install ($mode)" >> "$log"
  pim_ssh "$key" "$port" "$user" 'bash -l -s' < "$script" >> "$log" 2>&1 || rc=$?
  rm -f "$script"
  if [[ $rc -ne 0 ]]; then
    echo " FAILED (exit $rc)"
    tail -n 25 "$log" >&2
    die "anfs install failed; the whole output is in $(tilde "$log")"
  fi
  echo " ($(( $(date +%s) - start ))s)"
}
