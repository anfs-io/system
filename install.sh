#!/usr/bin/env bash
#
# anfs install script — bootstraps the anfs toolkit (ppm, pcm, psm, wsm and the anfs command)
#
# WHAT THIS SCRIPT DOES:
#   1. Sources ppm's libraries, so this bootstrap reuses ppm's own os()/platform()/brew_*
#      helpers instead of copies: from the checkout it runs from, an existing clone, or a
#      download (curl ... | bash)
#   2. Installs Homebrew's prerequisites (Debian: apt, Fedora: dnf packages, including git;
#      macOS: Xcode Command Line Tools), asking for sudo only when something is missing
#   3. Installs Homebrew if the machine has none (this user becomes its owner), or uses
#      the existing installation without writing to it when another user owns it
#   4. Installs the base tools from Homebrew: stow, yq, mise (and bash on macOS) — ppm cannot
#      parse a package.yml (yq) or stow anything until these exist, so they stay an imperative
#      bootstrap and never become tracked dependencies
#   5. Clones anfs to ~/.local/share/anfs/sources/core (git is available now) and stows its two
#      base packages into $HOME: anfs (the anfs command, the libraries every tool shares, the
#      default config — anfs.conf and system.list) and ppm (the ppm command, its libraries and
#      shell integration). That is what puts ~/.local/bin/{anfs,ppm} on PATH. Files protected with
#      `ppm file protect` are left alone.
#   6. Adds GitHub's published SSH host keys to ~/.ssh/known_hosts
#   7. Seeds an empty ~/.config/anfs/user.list (your sources) and ~/.config/anfs/anfs.local.conf
#      (machine-local settings)
#   8. With --repo: adds your customization repo as the "user" source (highest priority) and
#      installs its anfs package, which replaces the seeded user.list with a link into it
#   9. Runs 'anfs src update', installs any requested packages, then 'ppm install core/anfs':
#      the whole toolkit — pcm, psm, wsm and the software they run on (podman, varlock, node) —
#      tracked like any package, so `anfs implode` can take it all out again
#
# FILES CREATED:
#   ~/.local/share/anfs/sources/<alias>/  one clone per source; anfs/ is the toolkit's own repo
#   ~/.local/bin/{anfs,ppm,pcm,psm,wsm}   the commands (stowed)
#   ~/.local/lib/{anfs,ppm,pcm}/          their libraries; lib/anfs is what every tool shares
#   ~/.config/anfs/system.list            default sources (stowed from core/anfs)
#   ~/.config/anfs/user.list              your sources (a link into your repo with --repo)
#   ~/.config/anfs/anfs.conf              default settings for every tool (stowed from core/anfs)
#   ~/.config/anfs/anfs.local.conf        machine-local settings
#   ~/.local/state/ppm/installed/         what ppm installed
#
# EXTERNAL FETCHES:
#   https://github.com/anfs-io/system.git                                  the anfs repo
#   https://raw.githubusercontent.com/anfs-io/system/...                  ppm's libraries, only when
#                                                                      piped (no checkout to read)
#   https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh  only when Homebrew is missing
#
# SUDO USAGE:
#   One password prompt to install missing prerequisites or to create the Homebrew prefix, and
#   on Linux one more for the distro's podman. Passwordless sudo is not required.
#
# SUPPORTED PLATFORMS: macOS, Debian 13 (and derivatives that declare ID_LIKE=debian),
#                      Fedora (and derivatives that declare ID_LIKE=fedora)
#
# OPTIONS:
#   --repo <url>    your customization repo (see `ppm customize`), added as the "user" source
#                   (or set ANFS_INSTALL_REPO)
#   --script-only   only clone anfs, stow the base packages and seed config (needs stow)
#   --skip-deps     skip prerequisites and Homebrew setup (you manage them)
#   <package...>    packages to install (or set ANFS_INSTALL_PACKAGES; none by default)
#
# Everything runs from main() on the last line, so a partially downloaded script does nothing.
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BIN_DIR=$HOME/.local/bin
export PATH="$BIN_DIR:$PATH"

XDG_CONFIG_HOME=$HOME/.config
XDG_DATA_HOME=$HOME/.local/share
XDG_STATE_HOME=$HOME/.local/state

ANFS_CONFIG_HOME=$XDG_CONFIG_HOME/anfs
ANFS_SOURCES_HOME=$XDG_DATA_HOME/anfs/sources

ANFS_REPO_URL=https://github.com/anfs-io/system.git
ANFS_RAW_URL=https://raw.githubusercontent.com/anfs-io/system/refs/heads/main
ANFS_REPO_DIR=$ANFS_SOURCES_HOME/core
# The packages stowed by hand before ppm can run: anfs (what every tool sources) and ppm itself
ANFS_BASE_PACKAGES="anfs ppm"
PPM_LIB_SUBDIR=packages/ppm/home/.local/lib/ppm
PPM_INSTALLED_DIR=$XDG_STATE_HOME/ppm/installed   # read by file.sh (protected.yml)

# What this installer found and what it added, so `anfs implode --all` removes exactly that much
ANFS_BOOTSTRAP_RECORD=$XDG_STATE_HOME/anfs/bootstrap
# Homes the toolkit's software creates outside its own dirs (mise and the tools it installs, the
# podman storage). One that already existed before the first install is never removed.
# The bare XDG dirs are listed too: when the toolkit made them, --all removes them once empty.
ANFS_TOOL_HOMES=".ssh .local/share/mise .local/state/mise .cache/mise .config/mise .rustup .cargo .npm
.cache/aube .cache/sigstore-rust .config/ruby .local/share/containers .config/containers .cache/containers
.cache/Homebrew .homebrew .local/share .local/state .local/bin .local/lib .local .config .cache"

# ppm's libraries this bootstrap reuses: platform/brew helpers, and its own stow (protected files)
PPM_BOOTSTRAP_LIBS="core.sh platform.sh file.sh installer.sh"

# This script's own path; empty when piped (curl ... | bash), a file when run from a checkout
PPM_INSTALLER_PATH="${BASH_SOURCE[0]:-}"
ANFS_USER_LIST=$ANFS_CONFIG_HOME/user.list

# From https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# (verified against api.github.com/meta); written directly instead of trusting ssh-keyscan
GITHUB_KNOWN_HOSTS='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk='


info() { echo -e "${CYAN}==>${NC} $*"; }
warn() { echo -e "${YELLOW}Warning:${NC} $*" >&2; }
die()  { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }


# Clone the anfs repo (which contains the base packages). No linking here — the commands land on
# PATH when the base packages are stowed (stow_base).
clone_anfs() {
  mkdir -p "$BIN_DIR" "$ANFS_SOURCES_HOME" "$ANFS_CONFIG_HOME"
  if [[ ! -e "$ANFS_REPO_DIR" ]]; then
    command -v git >/dev/null 2>&1 || die "git is required to clone anfs (drop --skip-deps to install it)"
    git clone "$ANFS_REPO_URL" "$ANFS_REPO_DIR"
  fi
}


# Download a URL to a file with curl or wget (a fresh machine may have only one)
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    die "curl or wget is required"
  fi
}


# Source ppm's own libraries so this bootstrap reuses os(), platform(), brew_prefix(),
# brew_owner(), brew_env(), system_pkg_*(), brew_missing(), brew_is_owner() instead of
# keeping copies here. This runs before the clone: the prerequisites it installs are what
# provide git. The libraries come from, in order:
#   1. the checkout this script is running from (./install.sh, bash /src/ppm/install.sh)
#   2. an existing clone (a re-run)
#   3. a download from GitHub (curl ... | bash has no checkout)
source_libs() {
  local dir="" tmp f
  [[ -f "$PPM_INSTALLER_PATH" ]] && dir="$(cd "$(dirname "$PPM_INSTALLER_PATH")" && pwd)/$PPM_LIB_SUBDIR"
  [[ -f "$dir/core.sh" ]] || dir="$ANFS_REPO_DIR/$PPM_LIB_SUBDIR"

  # installer.sh defines functions named install and remove; install.sh never runs those
  # commands itself, and child processes (the Homebrew installer) don't inherit them
  if [[ -f "$dir/core.sh" ]]; then
    for f in $PPM_BOOTSTRAP_LIBS; do source "$dir/$f"; done
    return
  fi

  tmp=$(mktemp -d)
  for f in $PPM_BOOTSTRAP_LIBS; do
    fetch "$ANFS_RAW_URL/$PPM_LIB_SUBDIR/$f" "$tmp/$f" || die "Could not download ppm's $f"
  done
  for f in $PPM_BOOTSTRAP_LIBS; do source "$tmp/$f"; done
  rm -rf "$tmp"   # sourcing has read them
}


# Homebrew base tools that ppm itself needs before it can run
base_formulas() {
  if [[ "$(os)" == "macos" ]]; then
    echo "stow yq mise bash"
  else
    echo "stow yq mise"
  fi
}


# Homebrew's prerequisites per Linux distro family (docs.brew.sh/Homebrew-on-Linux#requirements):
# a compiler toolchain, procps, curl, file and git. For Fedora these are individual packages (the
# equivalents of Debian's build-essential) rather than the development-tools group, so each one
# can be checked with rpm.
linux_prereqs() {
  case "$(platform)" in
    debian) echo "build-essential procps curl file git" ;;
    fedora) echo "gcc gcc-c++ make procps-ng curl file git" ;;
  esac
}


setup_prereqs() {
  case "$(platform)" in
    macos)
      # Without Homebrew, its installer installs the Command Line Tools itself
      if [[ -n "$(brew_prefix)" ]] && ! xcode-select -p >/dev/null 2>&1; then
        die "Xcode Command Line Tools are missing. Run: xcode-select --install, then re-run."
      fi
      ;;
    *)
      local missing
      missing=$(system_pkg_missing $(linux_prereqs) | tr '\n' ' ')
      missing="${missing%% }"; missing="${missing## }"
      [[ -z "$missing" ]] && return 0
      info "Installing prerequisites: $missing"
      system_pkg_install $missing || die "Failed to install prerequisites: $missing"
      ;;
  esac
}


# The bootstrap record: KEY=value lines in $ANFS_BOOTSTRAP_RECORD. A value set once is never
# overwritten (a re-run must not turn "installed" into "existing"); bootstrap_add appends words.
bootstrap_get() {
  [[ -f "$ANFS_BOOTSTRAP_RECORD" ]] || return 0
  sed -n "s/^$1=//p" "$ANFS_BOOTSTRAP_RECORD" | head -n1
}

bootstrap_set() {
  mkdir -p "$(dirname "$ANFS_BOOTSTRAP_RECORD")"
  [[ -n "$(bootstrap_get "$1")" ]] && return 0
  echo "$1=$2" >> "$ANFS_BOOTSTRAP_RECORD"
}

bootstrap_add() {
  local key="$1" word current tmp
  shift
  current=$(bootstrap_get "$key")
  for word in "$@"; do
    [[ " $current " == *" $word "* ]] || current="${current:+$current }$word"
  done
  mkdir -p "$(dirname "$ANFS_BOOTSTRAP_RECORD")"
  tmp=$(grep -v "^$key=" "$ANFS_BOOTSTRAP_RECORD" 2>/dev/null || true)
  { [[ -z "$tmp" ]] || printf '%s\n' "$tmp"; echo "$key=$current"; } > "$ANFS_BOOTSTRAP_RECORD"
}

# On the first run only: which of the tool homes are already there, i.e. not ours to remove
record_existing_homes() {
  [[ -n "$(bootstrap_get existing_homes)" ]] && return 0
  local rel found=""
  for rel in $ANFS_TOOL_HOMES; do
    [[ -e "$HOME/$rel" ]] && found="$found $rel"
  done
  # "-" for none, so the first run still counts as recorded
  found="${found# }"
  bootstrap_set existing_homes "${found:--}"
  bootstrap_set checked_homes "$(echo $ANFS_TOOL_HOMES)"
}

# Install Homebrew if needed, load its environment, and make sure the base tools are present.
# Only the owner of the installation installs anything; other users are told what to ask for.
setup_brew() {
  local prefix
  prefix=$(brew_prefix)

  if [[ -z "$prefix" ]]; then
    _system_sudo "create the Homebrew prefix" || die "sudo is required to install Homebrew"
    info "Installing Homebrew; $(id -un) will own it"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
    prefix=$(brew_prefix)
    [[ -n "$prefix" ]] || die "Homebrew was installed but none of these prefixes exist: $PPM_BREW_PREFIXES"
    bootstrap_set homebrew installed
    bootstrap_set homebrew_prefix "$prefix"
  else
    bootstrap_set homebrew existing
  fi

  brew_env

  local missing
  missing=$(brew_missing $(base_formulas) | tr '\n' ' ')
  missing="${missing%% }"; missing="${missing## }"
  [[ -z "$missing" ]] && return 0

  if brew_is_owner; then
    info "Installing base tools: $missing"
    brew install $missing </dev/null
    bootstrap_add formulas $missing
  else
    local owner
    owner=$(brew_owner)
    die "Homebrew at $prefix is owned by $owner and is missing: $missing
       Ask $owner to run: brew install $missing"
  fi
}


# Add GitHub's host keys unless known_hosts already has an entry for github.com
setup_known_hosts() {
  local file="$HOME/.ssh/known_hosts"
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  if [[ -f "$file" ]]; then
    if command -v ssh-keygen >/dev/null 2>&1; then
      # -F also matches hashed entries
      ssh-keygen -F github.com -f "$file" >/dev/null 2>&1 && return 0
    elif grep -q '^github\.com ' "$file"; then
      return 0
    fi
    # Don't join our first line onto a last line without a newline
    [[ -s "$file" && -n "$(tail -c1 "$file")" ]] && echo >> "$file"
  fi

  echo "$GITHUB_KNOWN_HOSTS" >> "$file"
  chmod 600 "$file"
  # The exact lines, so implode --all can take back what was added and nothing else
  mkdir -p "$(dirname "$ANFS_BOOTSTRAP_RECORD")"
  echo "$GITHUB_KNOWN_HOSTS" > "$(dirname "$ANFS_BOOTSTRAP_RECORD")/known_hosts"
  bootstrap_set known_hosts added
}


# Stow the base packages, anfs and ppm, into $HOME: this is what puts ~/.local/bin/{anfs,ppm} on
# PATH and ~/.local/lib/{anfs,ppm} in place, so `anfs` and `ppm` become runnable. Idempotent (stow
# re-links). Uses ppm's own stow_package, seeded with the files `ppm file protect` detached, so a
# re-run leaves protected files alone exactly as `ppm install` does.
stow_base() {
  command -v stow >/dev/null 2>&1 || die "stow is required to link anfs (install it or drop --skip-deps)"
  # Clear the stale links among the paths a base package ships, derived from the package rather
  # than hardcoded so the list follows whatever it ships. Two kinds are cleared, both of which
  # would otherwise make stow abort the whole run:
  #   - a dangling link, left when a file moved out of the package, or out of a package that is
  #     gone (mise.zsh used to come from stack/mise)
  #   - a link already pointing into the package, i.e. one of ours from an earlier run
  # A live link into any *other* package is left alone: it belongs to a higher-priority layer
  # (user/anfs's anfs.conf is the documented case), and stow should report that as a real conflict
  # rather than have the bootstrap silently downgrade it. Plain files are never touched, which is
  # how `ppm file protect` and the user's own files survive.
  local pkg dir rel target
  local force=false   # read by stow_package; the bootstrap never force-removes
  for pkg in $ANFS_BASE_PACKAGES; do
    dir="$ANFS_REPO_DIR/packages/$pkg"
    while IFS= read -r rel; do
      target="$HOME/$rel"
      [[ -L "$target" ]] || continue
      if [[ ! -e "$target" ]] || [[ "$(readlink -f "$target" 2>/dev/null)" == "$(cd -P "$dir" && pwd)"/* ]]; then
        rm -f "$target"
      fi
    done < <(package_links "$dir/home")
    _reset_ignore_args
    stow_package "$dir"
  done
}


# Seed the machine's own config. anfs.conf and system.list come from stowing core/anfs; here we
# seed an empty user.list the user can add repos to, and machine-local settings. A repo's
# package can later replace user.list with a link into that repo (install_repo).
install_configs() {
  if [[ ! -e "$ANFS_USER_LIST" ]]; then
    printf '# Your anfs sources (highest priority). Add with: anfs src add <git-url> [alias]\n' \
      > "$ANFS_USER_LIST"
  fi

  if [[ ! -f "$ANFS_CONFIG_HOME/anfs.local.conf" ]]; then
    printf '# Settings for this machine only; they win over anfs.conf\nPPM_GROUP_ID=%s\n' "$(os)" \
      > "$ANFS_CONFIG_HOME/anfs.local.conf"
  fi
}


# --repo: your customization repo (see `ppm customize`), always registered as the "user" source
# (highest priority). Its anfs package is a layer of core/anfs; installing it with -f swaps the
# seeded user.list for the repo's copy, which lists the repo itself, and puts its anfs.conf (if it
# ships one) over the default.
install_repo() {
  local alias="$PPM_USER_REPO_ALIAS"
  local pkg_dir="$ANFS_SOURCES_HOME/$alias/packages/anfs"

  anfs src add --top "$repo_url" "$alias"
  anfs src update "$alias"

  if [[ ! -d "$pkg_dir" ]]; then
    warn "$repo_url has no anfs package; ~/.config/anfs keeps the seeded config files"
    return 0
  fi

  ppm install -f "$alias/anfs"

  if [[ -e "$pkg_dir/home/.config/anfs/user.list" && ! -L "$ANFS_USER_LIST" ]]; then
    warn "$ANFS_USER_LIST is not a link into your repo; edits there won't be saved in it"
  fi
}


install_packages() {
  local pkg
  for pkg in "$@"; do
    ppm install "$pkg"
  done
  # The toolkit: core/anfs depends on ppm, pcm, psm, wsm and the software they run on, so this
  # installs them all and records them in the tracker (re-stowing the base packages)
  ppm install core/anfs
}


main() {
  local skip_deps=false script_only=false
  repo_url="${ANFS_INSTALL_REPO:-}"
  local packages=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-deps) skip_deps=true ;;
      --script-only) script_only=true ;;
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a URL"
        repo_url="$2"
        shift
        ;;
      -*) die "Unknown option: $1" ;;
      *) packages+=("$1") ;;
    esac
    shift
  done

  echo -e "${CYAN}"
  cat << "EOF"
    _    _   _ _____ ____
   / \  | \ | |  ___/ ___|
  / _ \ |  \| | |_  \___ \
 / ___ \| |\  |  _|  ___) |
/_/   \_\_| \_|_|   |____/

EOF
  echo -e "Agent Native Full Stack${NC}"

  [[ "$(id -u)" -ne 0 ]] || die "Run as your normal user, not root (Homebrew refuses to run as root)"

  source_libs

  if $script_only; then
    clone_anfs
    brew_env   # put an existing Homebrew (hence stow) on PATH if there is one
    stow_base
    install_configs
    exit 0
  fi

  [[ "$(platform)" != "unsupported" ]] || die "Unsupported platform. Supported: macOS, Debian 13, Fedora"

  if [[ ${#packages[@]} -eq 0 && -n "${ANFS_INSTALL_PACKAGES:-}" ]]; then
    read -ra packages <<< "$ANFS_INSTALL_PACKAGES"
  fi

  record_existing_homes
  if $skip_deps; then
    brew_env
  else
    setup_prereqs
    setup_brew
    { command -v yq >/dev/null 2>&1 && command -v stow >/dev/null 2>&1; } ||
      die "ppm needs yq and stow on PATH after setup; check the Homebrew install above"
  fi

  clone_anfs   # after the prerequisites: they are what provide git
  stow_base
  install_configs
  setup_known_hosts
  [[ -z "$repo_url" ]] || install_repo
  anfs src update || warn "anfs src update skipped or failed for one or more sources"
  install_packages ${packages[@]+"${packages[@]}"}

  echo -e "\n${GREEN}Installation complete!${NC}"
  # echo -e "Open a new shell or run: ${CYAN}source ~/.zshrc${NC}"
}

main "$@"
