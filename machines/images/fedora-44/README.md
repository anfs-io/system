# fedora-44

Fedora 44 Server, installed unattended from the netinst ISO (packages come from the mirrors, so
a build needs the network).

| File | What it is |
| --- | --- |
| `image.yml` | arm64 and amd64, the ISO ids (`isos/isos.yml` pins their sums), 4 GB for the build, the answer file's `vars:` |
| `kickstart.ks` | Anaconda's answers: one plain partition, `@core`, the user, SELinux enforcing |
| `provision/10-base.sh` | cloud-init, growpart, the guest agent |
| `test.sh` | what `pmm image test fedora-44` checks on a throwaway boot |

`pmm image show fedora-44` lists each with its path, and the ISO each arch installs from.

## What a machine gets

- **User** `pmm`, in `wheel` with passwordless sudo, password locked. Login is by the image's own
  ssh key (`$PMM_DATA_HOME/keys/fedora-44/`). Root is locked.
- **SELinux** enforcing, firewalld with ssh open.
- **Network**: NetworkManager, as Fedora Server ships it.
- **A new machine at every boot of a copy**: pmm's finalize step empties `/etc/machine-id` and
  removes the ssh host keys; they are made again on first boot.

## Building on it

A child (`pmm image new app --from fedora-44`) starts from this build's disk and inherits the
user, the key and this `test.sh`. To change what the installer does, copy it
(`pmm image new my-fedora --copy fedora-44`) and edit `vars:` or `kickstart.ks`.

The build takes longer than Debian's (Anaconda, and every package downloaded): `timeouts.install`
is an hour.
