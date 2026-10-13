---
name: pmm-images
description: Create or edit pmm VM image definitions — the image.yml, answer file (preseed.cfg / kickstart.ks), provision steps, files/, test.sh and README in an anfs source (a repo's machines/images/<name>/, or ~/.config/pmm/machines/images/<name>/). Use when the user wants a new VM image, to add software or configuration to one (a provision step), to change a shipped image such as debian-13 without forking it (from: its own name), to point an image at an ISO, or to make `pmm image validate` pass.
---

# pmm image definitions

pmm builds VM images and runs machines from them, the way instances run from an AMI: an image is
built once, any number of machines run from the build. An **image definition** is one directory,
and it holds everything a build reads. Nothing is hidden in pmm except the last step (finalize).

```
machines/images/<name>/
  image.yml                    what it is
  preseed.cfg | kickstart.ks   a root image's answer file (Debian | Fedora): required
  provision/*.sh               the steps, run in name order as root in the guest
  files/                       copied to the guest for the steps
  test.sh                      what `pmm image test` runs
  README.md                    what the image is for and what a machine gets
```

`pmm image show <image>` prints exactly what a build will read: the answer file, the variables,
the ISO for each arch and whether it is downloaded, every step with its path, the test, the log
directory. Read it before changing an image and again after.

## Where definitions live

pmm reads definitions from **sources**, in priority order. A plain name is the first source that
has it; `source/name` picks one (`pmm image list` shows the shadowed ones):

1. `local`: `~/.config/pmm/machines/images/<name>/` (`$PMM_IMAGES_HOME`), not in git
2. every anfs source with a `machines/images/` directory, in anfs's order: `user.list` entries,
   then `system.list` (`core` ships `debian-13`, `fedora-44`, `anfs-dev`, `anfs-test-macos`)

A source is a clone under `~/.local/share/anfs/sources/<alias>/`. pmm reads definitions straight
from it: `pmm image cd <image>` lands in the repo, and edits are committed there (pmm never
commits). Scratch or machine-only: the local source.

Before writing one, read a shipped image as a model: `pmm image cd debian-13`.

## Two kinds of image

**A child (`from:`)** is a qcow2 overlay on another image's build. It has no ISO and no answer
file: it inherits the parent's user, ssh key, architectures and `test.sh`, and runs only its own
steps on top. This is almost always what is wanted.

    pmm image new web --from debian-13          # image.yml, an empty provision/, a README

**A root** installs from an ISO, unattended, with its own answer file. Start one by copying an
image of the same distro and changing the copy:

    pmm image new my-debian --copy debian-13    # the whole directory under a new name

`image new` writes to the local source; `--source <alias>` writes into a source's clone instead.
It refuses a directory that exists (exit 73).

`from:` resolves like a dependency: to the same or a **lower**-priority source. An image in
`user` may build on `core/debian-13`; `core` cannot build on yours.

## image.yml

```yaml
description: One line on what it is       # not part of the build key
from: debian-13                           # a child. A root has the next four instead:

distro: debian                            # debian | fedora (qemu); macos (tart)
arch: [arm64, amd64]
iso:                                      # ids in the ISO catalogue, one per arch
  arm64: debian-13-arm64
  amd64: debian-13-amd64
vars:                                     # every ${VAR} the answer file uses
  HOSTNAME: debian
  TIMEZONE: UTC

build: {cpus: 2, memory: 2048, disk: 20G} # what the build boots with; disk is the image's size
machine:                                  # for machines run from it; never read by a build
  profile: medium
  min: {cpus: 2, memory: 4G, disk: 20G}
user: {name: pmm, password_hash: <crypt>, authorized_keys: [...]}   # a root's; default pmm, locked
timeouts: {install: 3600, ssh: 600}
anfs: {sources: host}                     # install the anfs toolkit in the image (see anfs-dev)
```

- `build:` is the build's; `machine:` is what `pmm run` gives a machine by default. A machine's
  own settings win over both.
- A child ignores `distro`, `arch`, `iso` and `base` (its root's apply), and `validate` warns.
- `backend: tart` with `base: <oci image>` is a macOS image (Apple silicon); see
  `anfs-test-macos`.

### ISOs

`iso.<arch>` is an **id in the ISO catalogue**, not a URL. The catalogue is `isos/isos.yml` in
each source, with `~/.config/anfs/isos.yml` first; `pmm iso list` shows it.

```yaml
# isos/isos.yml in the image's source (the same or a lower-priority one works too)
- id: debian-13-arm64
  name: Debian 13.7.0 arm64 netinst
  architecture: arm64
  url:                                    # a URL, or a list tried in order
    - https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-13.7.0-arm64-netinst.iso
  checksum: sha256:6e93fa17...            # required for an ISO an image names
```

The entry **must pin `checksum: sha256:<hex>`**: the sum is part of the build key, so a
different file under the same id is a different build. A `checksum_url` alone fails `validate`.
`pmm iso add <url> --id <id> --sha256 <hex>` adds an entry to your own catalogue;
`pmm iso pull <id>` downloads ahead of a build. To use a mirror, repeat the id in
`~/.config/anfs/isos.yml` with another `url` and the same `checksum`.

### Variables and the answer file

`${NAME}` in `preseed.cfg` / `kickstart.ks` is replaced by `vars.NAME`; `$${NAME}` is a literal
`${NAME}`; any other `$` (`$releasever`, `$(cmd)`) is left alone. pmm sets these itself, and
`vars:` cannot override them: `USER`, `FULLNAME`, `PASSWORD_HASH` (preseed), `KS_PASSWORD`
(kickstart), `SSH_PUBKEY`, `IMAGE`, `ARCH`. `HOSTNAME` is the image's name unless `vars:` sets
it. **Nothing else has a default**: a name the file uses that `vars:` does not set is an error
from `validate`, with the file and line. Comments are rendered too, so don't write `${X}` in one.

The answer file must end by powering the VM off (pmm waits for that), create the user, and
authorize the image's key: Debian's copies `/pmm/authorized_keys`, which pmm appends to the
installer's initrd; Fedora's uses `sshkey --username=${USER} "${SSH_PUBKEY}"`. Keep those lines
when editing a copy.

## Provision steps

`provision/*.sh`, run in name order (`10-base.sh`, `50-app.sh`) as root over ssh, after the
install (a root) or on the parent's disk (a child). Each gets `PIM_IMAGE`, `PIM_ARCH`, `PIM_USER`
and, when the image has a `files/` directory, `PIM_FILES`: where it was copied in the guest.

```bash
#!/bin/bash
# web: nginx with this image's site
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q nginx
install -m 644 "$PIM_FILES/site.conf" /etc/nginx/conf.d/site.conf
systemctl enable nginx
```

- A step that fails stops the build, and the end of its output is shown (`-v` shows it all; the
  whole log is in the `logs` directory `image show` prints).
- Don't start what must not run during the build, and don't clean up: every build ends with
  pmm's finalize step (package caches, logs, ssh host keys, machine-id), which an image cannot
  skip or replace.
- Only `*.sh` run today; `validate` warns about anything else in `provision/`, and about an
  empty step.
- An image must leave DHCP running on every ethernet interface: pmm configures nothing in a
  guest. `debian-13` does (dhcpcd); a child inherits it.

## test.sh

Runs as root in a throwaway boot of the build (`-snapshot`: nothing it does is kept). Print
`ok  <what>` lines; a non-zero exit fails the test. An image without one uses the nearest one up
its `from:` chain, so a child's own `test.sh` should repeat what still matters from its parent's
and add its own. With none anywhere, `image test` says so and succeeds.

## Changing a shipped image without forking it

Give a **higher-priority** source an image of the **same name** whose `from:` is that name:

    pmm image new debian-13 --from debian-13            # local; or --source user
    $EDITOR "$(pmm image path debian-13)/provision/50-mine.sh"

`debian-13` now means yours, and `from: debian-13` in it is the next layer down (core's), so
your image is core's plus your steps. `pmm run debian-13` and every image of yours that is
`from: debian-13` get it at their next build. An image in a lower-priority source does not: its
`from:` never resolves upward, so `core/anfs-dev` stays on core's. `pmm image list` shows core's
as `shadowed`; both are built (core's build is recorded beside yours), and
`pmm image show debian-13` lists the steps of each.

This adds to an image. To change what its **installer** does (partitioning, the mirror, the
package set), make a root under a new name with `--copy`.

## Builds and the key

`pmm image build <image>` builds its parents first and is a no-op while the **build key** is
unchanged: a hash of `image.yml` (without `description` and `machine`), the answer file, the
steps, `files/`, the ISO's pinned sum, pmm's finalize step and the parent's key. `README.md` is
not in it. `pmm image list` says `stale` when the definition changed since the build. A machine
stays on the build it was made from until `pmm reset <machine>`.

## Workflow

1. `pmm image new <name> --from <image>` (or `--copy`), then edit.
2. `pmm image validate <name>`: fix every error, read every warning.
3. `pmm image show <name>`: every file you expect a build to read is listed, with the right path.
4. `pmm image build --test <name>`: several minutes for a root (the installer), under a minute
   for a child. `--console` shows the installer when it hangs.
5. `pmm run <name> --rm`, `pmm shell <name>`: look at the result.
6. Write the README: what it is, its user, what a child inherits. Commit in the source's repo.

## What `validate` says

| Message | Fix |
| --- | --- |
| `no answer file: a debian image installs with its own preseed.cfg` | a root needs one: `--copy` a shipped image, or copy its file |
| `preseed.cfg:12: unknown variable ${X}` | set `X` under `vars:`, or write `$${X}` for a literal |
| `iso.arm64: no ISO '<id>' in the catalogue` | add the entry to the source's `isos/isos.yml` (`pmm iso list`) |
| `the catalogue entry '<id>' pins no sha256` | give the entry `checksum: sha256:<hex>` |
| `iso.arm64: an inline url and sha256 are gone` | move them to a catalogue entry and name its id |
| `iso.amd64 is missing` | every arch in `arch:` needs an id, or drop the arch |
| `scripts/ is never run` / `scripts: is gone` | rename the directory `provision/`; delete the key |
| `memory: is build.memory now` | move `cpus`, `memory`, `disk` under `build:` |
| `from: <x> not found in its source or below` | the parent is in a higher-priority source, or misspelt |
| `distro: is ignored on a from: image` | delete it: a child's distro, arch and ISO are its root's |

Only report an image as working after `pmm image validate` passes and `pmm image build --test`
built and tested it. If you could not run the build, say so.
