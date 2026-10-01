#!/usr/bin/env bash
# anfs/dev — adds `ppm user`: throwaway users for testing ppm installs from scratch
# Stowed to ~/.local/lib/ppm/ and sourced by ppm, so cmd_user() is the command `ppm user`

cli_cmd user "user <command> ..." "Throwaway users on this machine, to test installs as someone else"

cmd_user() {
  local subcommand="${1:-}"
  shift 2>/dev/null || true

  case "$subcommand" in
    add)     _user_add "$@" ;;
    remove)  _user_remove "$@" ;;
    login)   _user_login "$@" ;;
    install) _user_install "$@" ;;
    setup)   _user_setup "$@" ;;
    *)
      echo "Usage: ppm user <add|remove|login|install|setup>"
      echo "  add <user> [--sudo]    Create a user with your authorized_keys (--sudo: passwordless sudo)"
      echo "  remove <user>          Remove a non-system user and its home directory"
      echo "  login <user> [--ssh]   Open a login shell as the user (--ssh: share your ssh agent)"
      echo "  install <user>         Run the ppm bootstrap installer as the user"
      echo "  setup <user>           add --sudo (if needed), install, then login --ssh"
      [[ -z "$subcommand" ]] || exit 1
      ;;
  esac
}

# Create a user, then log in as them with a fresh ppm install
_user_setup() {
  local userid="${1:-}"
  [[ -n "$userid" ]] || { echo "Usage: ppm user setup <user>"; return 1; }

  if ! id "$userid" &>/dev/null; then
    _user_add "$userid" --sudo
  fi
  _user_install "$userid"
  _user_login "$userid" --ssh
}

# Bootstrap ppm for a user by running the published installer as them
_user_install() {
  local userid="${1:-}"
  [[ -n "$userid" ]] || { echo "Usage: ppm user install <user>"; return 1; }

  _user_run_as "$userid" "curl -fsSL https://raw.githubusercontent.com/maxcole/ppm/refs/heads/main/install.sh | bash"
}

# Open a login shell as a user; --ssh temporarily opens your agent socket to them
_user_login() {
  local userid="" ssh=false arg
  for arg in "$@"; do
    if [[ "$arg" == "--ssh" ]]; then
      ssh=true
    else
      userid="$arg"
    fi
  done
  [[ -n "$userid" ]] || { echo "Usage: ppm user login <user> [--ssh]"; return 1; }

  if ! $ssh; then
    sudo -iu "$userid" || true
    return 0
  fi

  [[ -S "${SSH_AUTH_SOCK:-}" ]] || { echo "Error: no ssh agent socket (SSH_AUTH_SOCK)"; return 1; }
  local sock_dir
  sock_dir="$(dirname "$SSH_AUTH_SOCK")"

  chmod 711 "$sock_dir"
  chmod 666 "$SSH_AUTH_SOCK"
  # The shell's exit status is the user's last command; the socket must be locked down regardless
  sudo --preserve-env=SSH_AUTH_SOCK -iu "$userid" || true
  chmod 700 "$sock_dir"
  chmod 600 "$SSH_AUTH_SOCK"
}

# Create a user and copy your authorized_keys to them
_user_add() {
  local userid="" with_sudo=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --sudo) with_sudo=true ;;
      -*) echo "Unknown option: $1"; return 1 ;;
      *) userid="$1" ;;
    esac
    shift
  done
  [[ -n "$userid" ]] || { echo "Usage: ppm user add <user> [--sudo]"; return 1; }

  if id "$userid" &>/dev/null; then
    echo "User '$userid' already exists"
    return 1
  fi

  if [[ "$(os)" == "macos" ]]; then
    sudo sysadminctl -addUser "$userid" -fullName "$userid" -shell /bin/zsh -password ""
  elif [[ "$(os)" == "linux" ]]; then
    sudo useradd -m -s /bin/bash "$userid"
  else
    echo "Unsupported OS"
    return 1
  fi

  if ! id "$userid" &>/dev/null; then
    echo "Failed to create user '$userid'"
    return 1
  fi
  echo "Created user '$userid'"

  local keys="$HOME/.ssh/authorized_keys"
  if [[ -f "$keys" ]]; then
    local dest
    if [[ "$(os)" == "macos" ]]; then
      dest="/Users/$userid/.ssh"
    else
      dest="/home/$userid/.ssh"
    fi
    sudo mkdir -p "$dest"
    sudo cp "$keys" "$dest/authorized_keys"
    sudo chown -R "$userid":"$(id -gn "$userid")" "$dest"
    sudo chmod 700 "$dest"
    sudo chmod 600 "$dest/authorized_keys"
    echo "Copied authorized_keys to $userid"
  fi

  if $with_sudo; then
    _user_sudo "$userid"
  fi
}

# Remove a user, their sudoers file and home directory (refuses system users)
_user_remove() {
  local userid="${1:-}"
  [[ -n "$userid" ]] || { echo "Usage: ppm user remove <user>"; return 1; }

  if ! id "$userid" &>/dev/null; then
    echo "User '$userid' does not exist"
    return 1
  fi

  local uid
  uid=$(id -u "$userid")
  if [[ "$(os)" == "macos" && "$uid" -lt 501 ]] || [[ "$(os)" == "linux" && "$uid" -lt 1000 ]]; then
    echo "Refusing to remove system user '$userid' (UID $uid)"
    return 1
  fi

  if [[ "$(os)" == "macos" ]]; then
    sudo rm -f "/private/etc/sudoers.d/$userid"
    sudo sysadminctl -deleteUser "$userid"
    sudo rm -rf "/Users/$userid"
  elif [[ "$(os)" == "linux" ]]; then
    sudo rm -f "/etc/sudoers.d/$userid"
    sudo userdel -r "$userid"
  else
    echo "Unsupported OS"
    return 1
  fi

  echo "Removed user '$userid'"
}

# Run a command as a user in a login shell
_user_run_as() {
  local userid="$1" rc=0
  shift
  echo "Running as $userid: $*"
  sudo -iu "$userid" -- bash -c "$*" || rc=$?
  echo "Exit code: $rc"
  return $rc
}

# Give a user passwordless sudo
_user_sudo() {
  local userid="$1" sudoers_file

  if [[ "$(os)" == "macos" ]]; then
    sudoers_file="/private/etc/sudoers.d/$userid"
    sudo dscl . -append /Groups/admin GroupMembership "$userid"
  elif [[ "$(os)" == "linux" ]]; then
    sudoers_file="/etc/sudoers.d/$userid"
  else
    echo "Unsupported OS"
    return 1
  fi

  echo "$userid ALL=(ALL) NOPASSWD:ALL" | sudo tee "$sudoers_file" > /dev/null
  sudo chmod 440 "$sudoers_file"

  if ! sudo visudo -cf "$sudoers_file" &>/dev/null; then
    echo "Error: Invalid sudoers file, removing"
    sudo rm -f "$sudoers_file"
    return 1
  fi

  echo "Configured sudo for user '$userid'"
}
