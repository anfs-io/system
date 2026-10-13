---
name: pmm-images
description: Create or edit pmm VM image definitions — the image.yml, answer file (preseed.cfg / kickstart.ks), provision steps, files/, test.sh and README in an anfs source (a repo's machines/images/<name>/, or ~/.config/pmm/machines/images/<name>/). Use when the user wants a new VM image, to add software or configuration to one (a provision step), to change a shipped image such as debian-13 without forking it (from: its own name), to point an image at an ISO, to write a provisioner (what runs a kind of step, e.g. ansible), or to make `pmm image validate` pass.
---

# pmm image definitions

pmm builds VM images and runs machines from them, the way instances run from an AMI: an image is
built once, any number of machines run from the build. An **image definition** is one directory,
and it holds everything a build reads. Nothing is hidden in pmm except the last step (finalize).

```
machines/images/<name>/
  image.yml                    what it is
  preseed.cfg | kickstart.ks   a root image's answer file (Debian | Fedora): required
  provision/*                  the steps, run in name order, each by its extension's provisioner
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

Every file in `provision/` is a step, run in name order (`10-base.sh`, `50-app.sh`) after the
install (a root) or on the parent's disk (a child). A step's **extension names the provisioner**
that runs it. pmm ships two:

- **`.sh`**: a script, run as root in the guest. It sees `ANFS_IMAGE_NAME`, `ANFS_IMAGE_ARCH`,
  `ANFS_IMAGE_BACKEND`, `ANFS_IMAGE_DISTRO`, `ANFS_IMAGE_USER`, `ANFS_IMAGE_SSH_PUBKEY` and
  `ANFS_IMAGE_FILES`: where `files/` was copied in the guest, empty when the image has none.
- **`.anfs`**: installs the anfs toolkit as the image's user. A YAML file, not a script (see
  `anfs-dev`):

  ```yaml
  # provision/50-toolkit.anfs
  sources: host            # this machine's source clones are copied in | pushed (the default):
                           # the guest fetches install.sh and clones them itself
  repo: git@github.com:me/dots.git    # optional: install.sh --repo
  packages: [stack/zsh]               # optional: installed after the toolkit
  ```

A `.sh` step:

```bash
#!/bin/bash
# web: nginx with this image's site
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q nginx
install -m 644 "$ANFS_IMAGE_FILES/site.conf" /etc/nginx/conf.d/site.conf
systemctl enable nginx
```

- A step that fails stops the build, and the end of its output is shown (`-v` shows it all; the
  whole log is in the `logs` directory `image show` prints).
- Don't start what must not run during the build, and don't clean up: every qemu build ends
  with pmm's finalize step (package caches, logs, ssh host keys, machine-id), which an image
  cannot skip or replace. (A tart build has none: it ends with a reboot.)
- A step nothing provides (`50-site.yml` with no `yml` provisioner installed) fails `validate`,
  and so does a file with no extension: nothing in `provision/` is silently skipped. A directory
  there is not a step. `validate` warns about an empty one.
- An image must leave DHCP running on every ethernet interface: pmm configures nothing in a
  guest. `debian-13` does (dhcpcd); a child inherits it.

## Writing a provisioner

A provisioner is an executable named for the extension it runs: `yml` runs `provision/*.yml`.
pmm looks in `~/.config/pmm/provisioners/<ext>` (yours), then `~/.local/lib/pmm/provisioners/<ext>`
(pmm's `sh` and `anfs`, and where a package stows one: `packages/<pkg>/home/.local/lib/pmm/provisioners/yml`,
with what it needs declared in `package.yml`, e.g. `brew: [ansible]`). pmm does not change to gain
one. Read `sh` (twenty lines) and `anfs` first: `ls "$(dirname "$(command -v pmm)")/../lib/pmm/provisioners"`.

It is called with a verb, in the image's directory, with an empty stdin:

| Verb | Does |
| --- | --- |
| `check` | Print what is missing on the host (a binary, a version) and exit non-zero; print nothing when ready. `validate` shows the text |
| `fingerprint <step>` | Print, one per line, every file the step's result depends on, the step first. A directory is the whole tree under it; a path is absolute or from the image's directory. pmm hashes them into the build key, so leave one out and a change to it rebuilds nothing. Exit non-zero (with why on stderr) for a step you cannot run: `validate` reports it |
| `run <step>` | Run the step against the guest. stdout and stderr are the step's log; a non-zero exit fails the build |

What it is told, in its environment:

| Variable | |
| --- | --- |
| `ANFS_IMAGE_NAME`, `ANFS_IMAGE_ARCH`, `ANFS_IMAGE_BACKEND`, `ANFS_IMAGE_DISTRO` | what is being built |
| `ANFS_IMAGE_USER` | the image's user |
| `ANFS_IMAGE_DIR` | the definition directory |
| `ANFS_IMAGE_WORK` | an empty directory for this call, deleted after it. A `fingerprint` whose inputs are not files writes one here and prints its path |
| `ANFS_IMAGE_GUEST_EXEC` | `run` only, like the rest: a command line that runs its arguments as root in the guest, stdin passed through |
| `ANFS_IMAGE_GUEST_PUSH` | a command line: `<local path> <absolute guest path>`, copied as root (a directory: its contents into that directory) |
| `ANFS_IMAGE_GUEST_TRANSPORT` | `ssh`, and then `ANFS_IMAGE_GUEST_HOST`, `_PORT`, `_USER`, `_KEY` |
| `ANFS_IMAGE_FILES` | where `files/` is in the guest; empty when the image has none |
| `ANFS_IMAGE_SSH_PUBKEY` | the image's public key |

```bash
#!/usr/bin/env bash
# tgz: pmm provisioner for .tgz steps: the archive, unpacked over / in the guest
set -euo pipefail
source "$HOME/.local/lib/anfs/bash.sh"     # every anfs entry point: the bash floor, first
case "${1:-}" in
  check)       command -v tar >/dev/null || { echo "tar is not installed"; exit 1; } ;;
  fingerprint) echo "$2" ;;
  run)         $ANFS_IMAGE_GUEST_EXEC tar -C / --no-same-owner -xzf - < "$2" ;;
  *)           echo "tgz: unknown verb '${1:-}'" >&2; exit 1 ;;
esac
```

- **Use `ANFS_IMAGE_GUEST_EXEC` and `ANFS_IMAGE_GUEST_PUSH`, unquoted, and nothing else to reach
  the guest** unless the tool brings its own connection. They are the same on every backend (a
  tart guest's sudo needs a password; pmm deals with it), and pass arguments as given: no
  quoting for the far shell. Use the `GUEST_HOST`, `_PORT`, `_USER` and `_KEY` only after
  checking `ANFS_IMAGE_GUEST_TRANSPORT` is `ssh`; that user is not root, and on a tart guest is
  the stock account, not the image's user.
- **A provisioner that runs on the host** (ansible against the guest) lists its whole input tree
  in `fingerprint`: the playbook, `roles/`, the vars files.
- pmm keeps the order of the steps, `files/`, the log and finalize. Don't clean up the guest.
- Test it with a throwaway child: `pmm image new t --from debian-13`, one step, `pmm image
  validate t`, `pmm image build -v t`.

## test.sh

Runs as root in a throwaway boot of the build (`-snapshot`: nothing it does is kept), with the
`ANFS_IMAGE_*` a `.sh` step sees (`ANFS_IMAGE_FILES` is empty: `files/` is not copied). Print
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

- Adding the override does not rebuild core's: its build is found by its key and stays the disk
  that machines and other images are already on. Machines made before it stay on core's build
  until `pmm reset <machine>`.
- Removing the override (delete the directory) makes `debian-13` core's again, on that same
  build. Yours is then superseded: `pmm image prune` deletes it once no machine is on it.
- `pmm image build -f debian-13` is refused while a machine or another image's build is on the
  disk it would replace. Change the definition instead (a new key is a new disk), or remove
  what is on it first.

This adds to an image. To change what its **installer** does (partitioning, the mirror, the
package set), make a root under a new name with `--copy`.

## Builds and the key

`pmm image build <image>` builds its parents first and is a no-op while the **build key** is
unchanged: a hash of `image.yml` (without `description`, `machine`, `timeouts`, and the `arch`
and `iso` lists), the answer file, each step (what its provisioner's `fingerprint` names), `files/`, the pinned sum of the ISO this arch
installs from, pmm's finalize step and the parent's key. `README.md` is not in it. `pmm image list` says `stale` when the definition changed since the build. A machine
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
| `anfs: is gone: a step holds it now` | move the key's contents to `provision/50-toolkit.anfs` |
| `nothing provides .yml steps` | install the package that ships that provisioner, or the file is not a step: move it out of `provision/` |
| `provision/README has no extension` | a step's extension names its provisioner; notes go in `README.md` |
| `.yml steps: ansible is not installed` | what that provisioner's `check` printed: install it |
| `memory: is build.memory now` | move `cpus`, `memory`, `disk` under `build:` |
| `from: <x> not found in its source or below` | the parent is in a higher-priority source, or misspelt |
| `distro: is ignored on a from: image` | delete it: a child's distro, arch, ISO, `vars:` and `user:` are its root's |
| `build.mem is not a setting` | `build:` has `cpus`, `memory` (MB) and `disk` (`20G`) |

Only report an image as working after `pmm image validate` passes and `pmm image build --test`
built and tested it. If you could not run the build, say so.
