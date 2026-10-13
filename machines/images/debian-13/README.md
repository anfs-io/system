# debian-13

Debian 13 (trixie), installed unattended from the netinst ISO. The base image: `anfs-dev` and
other sources' images build on it with `from: debian-13`.

| File | What it is |
| --- | --- |
| `image.yml` | arm64 and amd64, the ISO ids (`isos/isos.yml` pins their sums), the answer file's `vars:` |
| `preseed.cfg` | the installer's answers: one disk, the `standard` and `ssh-server` tasks, the user |
| `provision/10-base.sh` | cloud-init, the guest agent, acpid; dhcpcd on every ethernet interface |
| `test.sh` | what `pmm image test debian-13` checks on a throwaway boot |

`pmm image show debian-13` lists each with its path, and the ISO each arch installs from.

## What a machine gets

- **User** `pmm`, passwordless sudo, password locked. Login is by the image's own ssh key
  (`$PMM_DATA_HOME/keys/debian-13/`), which `pmm shell` and `pmm exec` use. Root has no login.
- **Network**: dhcpcd runs DHCP on every ethernet interface, however many the machine is given.
  pmm configures nothing in a guest, so an image that replaces this must do the same.
- **A new machine at every boot of a copy**: pmm's finalize step empties `/etc/machine-id` and
  removes the ssh host keys, and a unit it installs makes new ones on first boot.
- **cloud-init** is installed (NoCloud first) for wherever an exported image goes next.

## Building on it

A child (`pmm image new web --from debian-13`) starts from this build's disk: the user, the key,
`provision/10-base.sh`'s packages and this `test.sh` are inherited. Its own `provision/` runs on
top, and nothing here runs again.

To change this image for yourself without forking it, give a higher-priority source an image of
the same name that is `from: debian-13` (`pmm image new debian-13 --from debian-13`): `debian-13`
then means yours, built on this one. To change what the installer does (partitioning, mirror,
packages), copy it instead (`pmm image new my-debian --copy debian-13`) and edit `vars:` or
`preseed.cfg`.

A new Debian release is a new image: a new entry in `isos/isos.yml`, a copy of this directory.
