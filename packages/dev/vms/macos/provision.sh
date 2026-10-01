#!/bin/bash
# Runs as root inside a freshly cloned macOS guest. This is the counterpart of
# containers/<distro>/Containerfile: it turns the stock image into the ppm test box, and what it
# does has to match the containers so the same tests mean the same thing on both.
#
# `ppm vm build` copies this in over ssh, runs it, reboots (for /src), and snapshots the result as
# the base image, so everything here happens once per base rather than once per box.
set -uo pipefail

PUBKEY="${PPM_VM_PUBKEY:?PPM_VM_PUBKEY must be set}"

# owner: admin with a password (so the sudo prompt is testable); other: no admin.
# Same two users, same password rule as the containers.
for spec in "owner:-admin" "other:"; do
  u="${spec%%:*}" admin_flag="${spec#*:}"
  if id "$u" &>/dev/null; then
    echo "user $u already exists"
  else
    # shellcheck disable=SC2086
    sysadminctl -addUser "$u" -fullName "$u" -password "$u" -shell /bin/zsh $admin_flag 2>&1 |
      grep -vE '^20[0-9][0-9]-|IOServiceMatching' | sed 's/^/  /'
    id "$u" &>/dev/null || { echo "FAILED to create $u"; exit 1; }
    [[ -d "/Users/$u" ]] || createhomedir -c -u "$u" >/dev/null
    echo "created $u (uid $(id -u "$u"))"
  fi
done

# Remote Login is on in the stock image but restricted to a group, so new users are locked out
# until they are added to it
if dseditgroup -o read com.apple.access_ssh &>/dev/null; then
  for u in owner other; do dseditgroup -o edit -a "$u" -t user com.apple.access_ssh; done
  echo "granted ssh access to owner and other"
fi

# The harness reaches both users with this key, so no test ever needs the password typed --
# except sudo, which keeps its password on purpose
for u in owner other; do
  h="/Users/$u"
  mkdir -p "$h/.ssh"
  printf '%s\n' "$PUBKEY" > "$h/.ssh/authorized_keys"
  chown -R "$u:staff" "$h/.ssh"
  chmod 700 "$h/.ssh"
  chmod 600 "$h/.ssh/authorized_keys"
done
echo "installed the harness key for owner and other"

# install.sh's _system_sudo primes the credential cache and then relies on `sudo -n`, but macOS
# defaults to a 5 minute timestamp with per-tty tickets and there is no tty over ssh. A cold run
# outlives that and would fail partway. Only the timeout is relaxed: the password stays, because
# the prompt is part of what this box exists to test.
printf 'Defaults timestamp_timeout=240\nDefaults !tty_tickets\n' > /etc/sudoers.d/ppm-vm
chmod 440 /etc/sudoers.d/ppm-vm
visudo -cf /etc/sudoers.d/ppm-vm || { echo "FAILED to write sudoers drop-in"; exit 1; }

# Same two reasons as the Containerfile: the /src mounts are owned by another uid, and large
# fetches from a VM stall on HTTP/2 (Homebrew cloning itself)
printf '[safe]\n\tdirectory = *\n[http]\n\tversion = HTTP/1.1\n' > /etc/gitconfig
echo "wrote /etc/gitconfig"

# tart puts each --dir share under "/Volumes/My Shared Files/<name>", and ppm's source list is
# whitespace-separated (sources.sh: read -r url name), so a source path can never contain spaces.
# / is read-only on macOS, so this link cannot be created directly; synthetic.conf is the
# supported way and takes effect on the next boot. With it the guest sees /src/<alias>, which is
# exactly what the containers present.
if [[ -L /src ]]; then
  echo "/src already links to $(readlink /src)"
else
  printf 'src\t/Volumes/My Shared Files\n' > /etc/synthetic.conf
  echo "wrote /etc/synthetic.conf (a reboot realizes /src)"
fi
