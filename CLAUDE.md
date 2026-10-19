# anfs — Agent Native Full Stack

## What This Is

anfs is a toolkit of bash tools that share one model of where things come from: **sources**.
A source is a git repo (or a local directory) that may hold any of:

| Top-level dir | Tool | What it holds |
| --- | --- | --- |
| `packages/` | `ppm` | software and dotfiles: GNU Stow plus install hooks (most of this file) |
| `containers/` | `pcm` | podman compose services (`containers/<name>/compose.yml`) |
| `machines/` | `pmm` | machines (`machines/<name>/machine.yml`), the VM images they run from (`machines/images/<name>/image.yml`) and the networks they are on (`machines/networks/<name>/network.yml`); see pmm |
| `skills/` | `psm` | agent skills (`skills/<name>/SKILL.md`) |
| `spaces/` | `wsm` | workspaces of spaces (`spaces/<ws>/<space>/space.yml`; see wsm) |

`anfs` owns the sources (`anfs src`) and the commands that span the tools: `anfs install
<source>` installs everything a source holds, tool by tool (ppm, pcm, pmm, psm, wsm), and `anfs
implode` runs every tool's `implode` in reverse, then deletes the sources. Picking single
resources is each tool's own `install` (`ppm install lgat/rails`, `pcm install lgat/postgres`,
`psm install lgat/skill`, `wsm install lgat/main/tech`; `source/` means all of that kind).

**One tool, one top-level directory** (`anfs_tool_dir <tool>` in `paths.sh`); `isos/` is anfs's,
shared. What a tool keeps below its directory is its own: pmm has `machines/images/` and
`machines/networks/` beside the machines, and `pmm install source/` does images, networks,
machines in that order itself. `anfs src list`'s `provides` therefore says `machines` for a
source with any of the three.

What the tools share lives in `lib/anfs/` and nothing else does: paths (`paths.sh`), the
source lists and clones (`sources.sh`), and finding resources plus ordering them by dependency
(`resolve.sh`). What `install` *does* stays in each tool.

## pmm: machines

pmm is the one tool for machines: it runs them, and `pmm image ...` builds what they run from
(pim, which used to build the images, was folded in). An image is built once and any number of
machines run from it, the way instances run from an AMI, each with its own name, disk and
settings. `pmm help` documents the definitions; the shape:

```
machines/<name>/machine.yml    image (or media), profile, cpus, memory, disk, shares, ports, user, arch
machines/profiles.yml          name: {cpus, memory, disk}
machines/images/<name>/        an image: image.yml and everything its build reads (Images, below)
machines/networks/<name>/      a network (network.yml)
```

- **A name is one machine.** A definition is `source/name`; the name alone is the disk, the
  snapshots and the runtime record, so the machine `web1` is the highest-priority source's `web1`.
  A definition a higher one shadows is listed and nothing else.
  `images` and `networks` are not machine names: they are the directories beside the machines,
  and `validate` and `run --name` refuse them. So is `image-...`: a tart machine is the VM
  `pmm-<name>`, and `pmm-image-...` are the builds.
- **A machine is defined or was run from an image.** `pmm run debian-13 --cpus 4` makes a machine
  from the image and starts it: named for the image, then `debian-13-2`, or `--name`. It writes
  no definition. The settings from the command line are `settings:` in the machine's own
  `state.yml`, beside its disk, and go with `pmm remove`; `up`, `down`, `reset`, `shell` and
  `show` read them there. In the code such a machine's id is `-/<name>` and every read of a
  setting goes through `mach_q` (`settings.sh`), so nothing else knows which kind it has.
  `run --no-start` only makes it; `run --rm` removes it at its `pmm down`. `pmm up` starts
  machines that are defined (making one first) or that a `run` made, and takes no `--image`.
- **No command writes a machine or network definition.** `~/.config/pmm/machines/` (the implicit
  `local` source) holds what a person wrote, like a source's `machines/`, and `pmm remove` and
  `pmm network remove` never delete one. `pmm show` and `pmm network show` end with the settings
  as the YAML a definition holds, so keeping something made on the fly is a copy.
- **`shell` logs in, `exec` runs a command** (`pmm exec web1 -- uname -a`); `shell web1 -- cmd`
  is `exec`. **Snapshots are a group**: `pmm snapshot list|create|remove`; `pmm reset <machine>
  [snapshot]` goes back to one.
- **A machine stays on the build it was created from.** `state.yml` beside its disk records the
  image, arch, backend, build key, user and ssh key, and everything after it is made reads that, so
  a machine does not need its image's definition, or its own, to be stopped, reached or removed.
  `pmm reset` moves it onto the image's current build; `pmm show` says when there is a newer one.
- **A qemu machine is a qcow2 overlay on the build**, so the build is kept while the machine, or
  a snapshot taken on it, exists (Images, below). **A tart machine is a clone**, `pmm-<name>` in
  tart's store, and keeps nothing.
- **Making a machine builds its image first** when its build is not current (`pmm image build`).
  Several minutes the first time.
- **Profiles** are found like every other resource: the first source in priority order whose
  `machines/profiles.yml` has the name is the whole profile. `stack` ships `small`, `medium`,
  `large` and `xlarge`. A setting is the first of: the machine's own, its profile's, the profile
  its image names (`machine.profile`), then 2 cpus and 2048 MB (a tart machine: what its build
  has). An image's `machine.min` fails `validate`, `run` and `up`.
- **One catalogue per process** (`catalog.sh`), and pmm has two: `bin/pmm` loads the images' for
  `pmm image ...` and the machines' otherwise. What the machine side needs of an image
  (`image_def_dir`, `image_build`, `image_ensure_built` in `settings.sh`) is asked in a subshell
  that loads the images' catalogue. `__complete` loads neither.
- **Apple allows two macOS guests running at once.** `pmm up` counts tart's running macOS guests,
  whoever started them, and refuses a third before it clones or boots anything.
- `pmm install` (what `anfs install` runs) makes and starts defined machines; `pmm install
  source/` builds the source's images, installs its networks, then its machines.
  `PMM_INSTALL=create` builds and makes but starts nothing, and `PMM_INSTALL=validate` only
  validates, which is what the round trips use (no KVM in a podman box).
- **The sockets of running machines** (QMP, the guest agent) are in `PMM_SOCK_DIR`, by default
  `/tmp/pmm-<uid>`, which `implode` deletes. Anything that runs pmm beside a real one (the bats
  helper, the e2e) sets it to a directory of its own.
- **Media and blank machines** (`lib/pmm/media.sh`). `media:` lists what a person would plug in:
  an `.iso` is a CD, any other file a USB drive (a Ventoy stick's image), each a path or an id in
  the ISO catalogue. `pmm iso` is that catalogue and its store (`lib/anfs/iso.sh`, the same group
  as `anfs iso` and `ventoy iso`): `pmm iso pull` fetches ahead of time what a machine's
  `media:` or a build would otherwise fetch when it needs it, and `pmm iso remove` and
  `pmm iso prune` are what deletes ISOs (`image prune` does not). An image names its ISO by id
  too (`iso: {arm64: debian-13-arm64}`), and core's `isos/isos.yml` holds the entries its images
  name, so a build's ISO is never a stray to `prune`. Media in the definition boot after the disk, so an empty disk falls through
  to the installer and what it installs boots from then on; `pmm up --media` is for one run and
  boots first. A machine with media and no `image:` is blank: an empty disk (`disk:`, 20G), no
  build, no hold, no login, so `up` does not wait for ssh and `shell` refuses. `pmm up --display`
  gives a machine a screen: qemu's window where the host has one (foreground, like `--console`),
  else VNC on 127.0.0.1 (`PMM_DISPLAY=window|vnc` decides otherwise). pmm knows nothing about
  ventoy: its image is a file like any other (`--media "$(ventoy path)"`).
- **Not yet:** extra disks; networks on macOS; installing a blank machine unattended.

### Images

`pmm image list|show|new|build|test|export|remove|prune|path|cd|validate`. An image is
`machines/images/<name>/` in any source, or in `~/.config/pmm/machines/images/` (the implicit
`local` source, `PMM_IMAGES_HOME`). `pmm help` documents the definition; the shape:

```
machines/images/<name>/
  image.yml       backend (qemu|tart), distro, arch, iso.<arch>: <catalogue id> | from: <image> | base,
                  user, vars, build: {cpus, memory, disk}, machine:
  preseed.cfg | kickstart.ks   a root image's answer file (${VAR} templated): required
  provision/*     the steps, in name order after the install, each run by the provisioner its
                  extension names: 10-base.sh (a script, as root in the guest), 50-toolkit.anfs
  files/          copied to the guest for the steps
  test.sh         what `pmm image test` runs on a throwaway boot
  README.md       what the image is for and what a machine gets
```

- **The directory is complete.** Everything a build reads is in it, as in a pcm service
  directory, except `lib/pmm/defaults/finalize.sh`, which is pmm's so that no image can skip it.
  pmm ships no answer file, no step and no test: a root image has its own answer file or fails
  `validate`, and a new root for a distro that has one starts as a copy of it (`image new
  --copy`). `test.sh` is the image's, else the nearest up its `from:` chain; with none,
  `image test` says so and succeeds.
- **Every variable is in `image.yml`.** The answer file's `${VAR}`s are the root's `vars:`, plus
  what an image cannot know and `vars:` cannot override (`tpl_load`: `USER`, `FULLNAME`,
  `PASSWORD_HASH`, `KS_PASSWORD`, `SSH_PUBKEY`, `IMAGE`, `ARCH`), and `HOSTNAME`, the image's name
  unless `vars:` sets it. Nothing else has a default, so a name `vars:` does not set fails
  `validate` and the build. Comments in an answer file are rendered too. A value may have lines
  of its own (`img_vars` carries each in base64); `image show` prints it on one line, `\n` for a
  newline.
- **An ISO is a catalogue id** (`iso.<arch>`, `lib/pmm/iso.sh`), resolved the catalogue's own way
  (`~/.config/anfs/isos.yml`, then the sources in order), so a person's catalogue can point an id
  at a mirror. The entry must pin `checksum: sha256:<hex>`: the sum is in the build key, which is
  what keeps a repointed id honest. `validate` refuses an id the catalogue lacks, an entry with
  only a `checksum_url`, and the inline `{url, sha256}` map that ids replaced. Core has its own
  `isos/isos.yml` because stack's catalogue is not below core in priority.
- **`image show` prints what a build reads**: the answer file, the vars, each arch's ISO (its
  file in the store, present or missing), every step with its path (for a child, its parents'
  first, then its own; one nothing provides is marked), finalize, the test and the log
  directory. `--json` is the same as one object, each step with its `provisioner`. `_image_plan` (`registry.sh`) produces both.
- **`image new <name> --from <image> | --copy <image> [--source <alias>]`** starts a definition
  in `PMM_IMAGES_HOME`, or in a source's clone: a child (`image.yml`, an empty `provision/`, a
  README), or a copy of an image's whole directory (its README and `description:` included, to
  be rewritten). It only creates: an existing directory is 73, neither option without a terminal
  is 64. `--from core/debian-13` writes `from:` with its source, so it is that image and no
  other of the name; a plain name is written plain, and when it is another image from where the
  new one lands (`--source`), that is said.
- **The old shape is an error, not ignored**: a `scripts/` directory, a `scripts:` key, and
  `cpus`, `memory` or `disk` at the top level (they are `build:`'s) each fail `validate` with
  what replaced them, as does an `anfs:` key (it is a step, `provision/50-toolkit.anfs`). So
  does a key `build:` does not have, or a value that is not a number or a size. A `from:` image's `distro`, `iso`, `base`, `arch`, `vars` and `user` are warned about:
  its root's apply.
- **Root images install from an ISO, unattended.** The kernel and initrd are read out of the ISO
  and the rendered answer file (plus the image's public key) is appended to the initrd as one
  more cpio archive, which the kernel unpacks with the rest: no HTTP server, no network
  dependency on the host. The installer powers the VM off (`-no-reboot`), then pmm boots the disk.
- **`from:` images are qcow2 overlays** on their parent's build. `from:` resolves like a
  dependency: to the same or a lower-priority source, so `lgat/machines/images/app` may build on
  `core/machines/images/debian-13` but not the reverse. Naming its own name is the next layer down:
  `user/debian-13` with `from: debian-13` is core's plus its own steps, and is what `debian-13`
  then means. Both are built. A name is one build record (`meta.yml`), so the shadowed
  definition's is `meta@<source>.yml` in the same directory, its disk beside the other's
  (`img_bname`, `registry.sh`); `image prune` keeps the current build of each.
  - Which record a definition has changes when the override is added or removed. The build does
    not: `build_one` finds the disk by its key and `build_adopt` moves the record (with when it
    was built and tested), so the root is not installed again. Removing the override leaves its
    build superseded: `prune` takes it once no machine is on it.
  - `<name>@<source>` names a record and nothing else. A machine's `state.yml` has the image's id
    (`core/debian-13`, `build_read`'s `B_NAME` is the plain name), which is what `holders_of`
    compares, so a machine made from the shadowed definition holds its build like any other.
  - `prune` deletes a `meta@<source>.yml` whose definition is gone.
- **Builds are cached by key**: a hash of `image.yml` (minus `description`, `machine`, `timeouts`,
  `arch` and `iso`: the ids), the arch, the ISO's pinned sha256, the answer file, each step (its
  name, its provisioner and what its `fingerprint` names), `files/`, pmm's finalize step and the
  parent's key. `README.md` is not in it, nor is what
  another arch installs from; `build: {cpus, memory}` are.
  `pmm image build` is a no-op while the key is unchanged; `meta.yml` beside each build records
  it, with `tested_key` (the build `image test` last passed) and `exports`.
- **A disk with a build's key is that build, and is never written twice.** Machines and other
  images' builds are overlays on it, so `build_one` takes a disk that is there as built whatever
  the records say (the definition moved to another source, or is back at an earlier build), and
  `image build -f` refuses while a machine, a snapshot or another build is on the disk it would
  replace.
- **A step is run by a provisioner** (`lib/pmm/provision.sh`): see "Provisioners" below. Every
  file in `provision/` is a step (a directory there is not, nor a dotfile), and one nothing
  provides fails `validate` and the build: declaring a step and silently not running it is the
  outcome ruled out, as with a `package.yml` key that has no handler.
- **Every qemu build ends with `finalize.sh`**: caches, logs, ssh host keys (regenerated at first
  boot by a unit pmm installs), machine-id. An exported image is a new machine wherever it boots.
  A tart build has no finalize step: it ends with a reboot, and `image show` lists none.
- **`test` is not `validate`.** `image validate` checks a definition without booting anything;
  `image test` (and `image build --test`) boots a throwaway copy of the build and runs `test.sh`.
  `image export` writes the build, and any `from:` chain under it, as one standalone qcow2.
- **Access is by key only.** Each root image has its own ed25519 key in `$PMM_DATA_HOME/keys/`;
  the user's password is locked unless `user.password_hash` is set. ssh is forwarded on
  127.0.0.1 only.
- **qemu**: hvf on macOS and kvm on Linux for a guest of the host's arch, TCG emulation
  otherwise (works, slowly). arm64 guests boot UEFI (a per-disk copy of the vars). A guest of the
  host's own arch that falls back to TCG (Linux: `/dev/kvm` missing or not writable, which is a
  user outside the `kvm` group) is warned about once, by `image build`, `run` and `up`
  (`qemu_accel_warn`); a foreign-arch guest is TCG by design and is not.
- **tart** (macOS guests, Apple silicon only) builds from an OCI base image instead of an ISO. A
  build is the VM `pmm-image-<name>-<key>` in tart's store; machines are `pmm-<name>`.
- **What is on a build is found by a scan, not recorded.** `holders_of` (`registry.sh`) reads
  every machine's `state.yml` and every snapshot's copy of it for the build key it is on: `web1`,
  `web1@s1`. `image prune` keeps such a build, `image remove` refuses it without `-f`, exactly as
  for a build another image is an overlay on, and `image list`'s `held` is the same answer.
- **`image list` is one row per built arch**, or one row with a null arch for an image with no
  build. `state` is `built`, `stale` (the definition changed since, or is gone), `unbuilt` or
  `shadowed`.
- `machine:` in `image.yml` (`{profile: medium, min: {cpus, memory, disk}}`) is for the machines
  run from it and never read by a build, so it is left out of the cache key.
- `build: {cpus, memory, disk}` in `image.yml` is the build's: what the installer runs with and
  the size of the image's disk. What a machine gets is its own setting or its profile's. The file
  reads as two blocks: `build:` and `machine:`.
- **Where things are**: builds in `$PMM_DATA_HOME/images/<name>/<arch>/`, keys in
  `$PMM_DATA_HOME/keys/<name>/`, exports in `$PMM_DATA_HOME/exports/`, build workspaces and logs
  in `$PMM_STATE_HOME/{build,logs}`, ISOs in anfs's store (`lib/anfs/iso.sh`). Settings that are
  only about images are `PMM_IMAGE_*` (`PMM_IMAGE_INSTALL_TIMEOUT`, `PMM_IMAGE_SSH_TIMEOUT`).
- **Out of scope:** deploying to hypervisors or clouds (Proxmox, AWS). pmm's job with an image
  ends at a tested build or an exported qcow2; deployment targets are a later kind of their own.

### Provisioners

The provisioner of `provision/<NN>-<name>.<ext>` is `<ext>`: an executable, the first of
`$PMM_CONFIG_HOME/provisioners/<ext>` and `~/.local/lib/pmm/provisioners/<ext>` (pmm's own, and
what another package stows). It is the pattern of pcm's edge providers. pmm ships `sh` and
`anfs`; anything else is a file another package stows, and pmm does not change to gain it. An
ansible one would be a stack package stowing `~/.local/lib/pmm/provisioners/yml` and declaring
`brew: [ansible]`; none is written.

| Verb | Does |
| --- | --- |
| `check` | Prints what is missing on the host (a binary, a version) and fails; nothing printed is ready. `validate` runs it once per provisioner an image uses |
| `fingerprint <step>` | Prints, one per line, the files the step's result depends on, the step first. pmm hashes them into the build key (a directory is walked, sorted, and a link in it is its target's name, not followed; a path is absolute or from the image's directory). One that fails, names what is not there, or does not name the step first fails `validate` and the build (`key_step` is what both read it with), so it is also where a provisioner refuses a step it cannot run |
| `run <step>` | Runs the step against the guest. stdout and stderr are the step's log; a non-zero exit fails the build |

Every verb runs in the image's directory, with an empty stdin, and is told what is being built.
`run` is also given the guest, as a way to run something in it and not an ssh session, so the
same provisioner works wherever the guest is:

| Variable | |
| --- | --- |
| `ANFS_IMAGE_NAME`, `ANFS_IMAGE_ARCH`, `ANFS_IMAGE_BACKEND`, `ANFS_IMAGE_DISTRO` | what is being built |
| `ANFS_IMAGE_USER` | the image's user |
| `ANFS_IMAGE_DIR` | the definition directory |
| `ANFS_IMAGE_WORK` | an empty directory for the call's own files, deleted after it (`anfs` writes the file its `fingerprint` names there) |
| `ANFS_IMAGE_GUEST_EXEC` | `run`: a command line that runs its arguments as root in the guest, stdin passed through (`$ANFS_IMAGE_GUEST_EXEC id -u` prints 0). `sh` needs nothing else |
| `ANFS_IMAGE_GUEST_PUSH` | `run`: a command line that copies a local path to an absolute guest path, as root: a file, or a directory's contents into that directory |
| `ANFS_IMAGE_GUEST_TRANSPORT` | `run`: `ssh` today. With `ssh`, also `ANFS_IMAGE_GUEST_HOST`, `_PORT`, `_USER`, `_KEY`, for a provisioner that brings its own connection (ansible) |
| `ANFS_IMAGE_FILES` | `run`: where `files/` is in the guest, empty when the image has none |
| `ANFS_IMAGE_SSH_PUBKEY` | `run`: the image's public key |

- **The names are tool-neutral on purpose** (`ANFS_IMAGE_*`): a step written today would run in a
  container build that set `GUEST_EXEC` to `buildah run <container> --`. pmm's own settings
  (`PMM_IMAGE_INSTALL_TIMEOUT` and the like) keep pmm's prefix: they configure the tool and a step
  never sees them. Nothing names the old `PIM`-prefixed variables any more (`provision.bats` holds that).
- **The two command lines are scripts pmm writes for the build** (`guest_ssh`, `ssh.sh`), in the
  build's workspace. `exec` quotes each argument for the shell at the other end of ssh, which
  parses the line again, so a provisioner passes argv and never quotes for the guest. They hide
  the one thing that differs between backends: a qemu guest's user has passwordless sudo
  (`sudo -n`); a tart guest's stock account needs its password, so pmm puts an askpass helper in
  the guest before the first step (`_tart_guest`) and takes it out after the last, with
  `files/`. A provisioner never sees the password and does not ask which backend it is on.
- **pmm keeps** the order, pushing `files/`, the log (`_provision`: timing, `-v`, the tail on
  failure) and finalize. Between "waiting for ssh" and the shutdown, a build reaches the guest
  only through those two scripts: finalize and `test.sh` are run by `sh` like any `.sh` step
  (so an `sh` of your own in `$PMM_CONFIG_HOME/provisioners` runs those too), and
  `user.authorized_keys` is appended with `exec` itself, by no provisioner.
- **The provisioner's own file is not in the build key**: a new `sh`, or a package upgrading its
  provisioner, rebuilds nothing. One whose change is another build prints its own path in
  `fingerprint`.
- **The workspace's path cannot hold whitespace** (`guest_ssh` refuses it): the two scripts are
  handed over as unquoted command lines. So `$PMM_STATE_HOME` cannot either, to build or test.
- **`sh`** pipes the script to `bash -s` in the guest with every `ANFS_IMAGE_*` that means
  something there: not the `GUEST` ones, nor `DIR` and `WORK`, which are paths on the host.
- **`anfs`** installs the toolkit: `sources: pushed` (the guest clones them; the default) or
  `host` (this machine's source clones are copied in), `repo:`, `packages:`, `installer:`; any
  other key is refused by `fingerprint`, so by `validate` (a misspelt `sources:` would be the
  default). Each value is quoted for the guest's shell. It is
  the proof that the seam carries a provisioner that runs on the host and has inputs outside
  the image directory: its `fingerprint` names a file it writes with each source's commit and a
  hash of its uncommitted changes' names. It runs `install.sh` as the image's user through
  `su -l`, not a second ssh login, so it needs nothing but `GUEST_EXEC` and `GUEST_PUSH`.
- **A provisioner is an entry point**: it sources `lib/anfs/bash.sh` first (`bash.bats` checks
  pmm's own).
- Provisioners stay in `lib/pmm/provisioners/` until pcm builds images with them; then they move
  to `lib/anfs/provisioners/`.

### Networks (Linux)

`machines/networks/<name>/network.yml` is a kind of its own, below pmm's directory in a source
(and `~/.config/pmm/machines/networks/` locally). `pmm help` documents it; the shape:

```yaml
kind: nat                 # nat | isolated | bridged
subnet: 10.20.0.0/24      # nat, isolated: required
interface: br0            # bridged: a bridge the host already has
domain: lab               # optional
```

- **libvirt is used for networks only.** A nat or isolated network is a libvirt network
  `pmm-<name>` on a bridge of the same name (so a name is at most 11 characters), with libvirt's
  dnsmasq for DHCP and DNS. pmm starts every qemu itself and attaches each interface with
  `-netdev bridge`, through qemu's setuid bridge helper. A bridged network defines nothing: it is
  the name of a host bridge, and **pmm never creates or changes a host bridge**.
- **The host setup is `core/pmm-network`**, one sudo: the libvirt packages, the `libvirt` and
  `kvm` groups, the helper setuid for `kvm` (`dpkg-statoverride`), `libvirt` in `nsswitch.conf`,
  and `/etc/qemu/bridge.conf` including `/etc/qemu/pmm-bridge.conf`, which the `libvirt` group
  writes. pmm adds a network's bridge there itself, so nothing after the package asks for root.
  `net_host_problems` (network.sh) says what a host lacks; validate, install and up all use it.
- **A machine lists `interfaces:`** (`{network, address, mac}`). At create each gets a MAC, kept in
  `state.yml` across `reset`; on a nat or isolated network it also gets an address to keep (its
  own, or the lowest free one; DHCP's own range is the upper half of the subnet), reserved in
  libvirt under the machine's name (`virsh net-update ... ip-dhcp-host`). Nothing is configured in
  the guest, so **an image must run DHCP on every ethernet interface** (pmm's Debian default does:
  dhcpcd's service instead of ifupdown's one stanza).
- **ssh goes to the first interface whose address pmm knows**, and that machine has no user-mode
  nic (`qemu_argv` with no port; `PMM_SSH_HOST` in ssh.sh). A machine whose interfaces are
  all bridged keeps the user-mode nic and its forwarded port; `pmm show` asks the guest agent for
  the LAN's address.
- **A machine's networks are installed with it**, as its image is built with it; `pmm install
  source/` installs the source's networks first. `pmm network remove` is refused while machines
  are on the network.
- **`pmm network create <name> --kind K ...` makes a network with no definition**, as `podman
  network create` does: its record (`$PMM_DATA_HOME/networks/<name>/state.yml`, which every
  installed network has) is all of it, and a machine's `interfaces:` names it like any other
  (`net_known`, `net_setting` in network.sh). It is listed with no source.
- **`~/.ssh/config.d/05-pmm.conf`** holds a `Host` entry per running machine (any backend),
  rewritten by up and down: `ssh web1` works where the config includes that directory (stack/ssh).
- `PMM_NET_BACKEND` is `libvirt` on Linux and `none` elsewhere, where a machine with interfaces
  does not validate. The tests stub `virsh` (`tests/stubs/virsh`) and point `PMM_BRIDGE_CONF`,
  `PMM_BRIDGE_HELPER` and `PMM_SYS_NET` at a temp dir (`setup_net` in the helper).

## wsm: workspaces

A source's `spaces/` holds workspaces, each a directory of spaces: `spaces/<ws>/<space>/`. `wsm
help` documents the commands.

- **Levels are fixed by depth**: `spaces/` is the source level, every directory below it a
  workspace, every directory below a workspace a space. A `space.yml` is optional at each level;
  hidden directories are content, never a level. A space's files are everything below it; a
  workspace's and the source level's are what is not inside a directory below them. The workspace
  and source levels are installed with the first space under them and removed with the last,
  unless the spec named them (`wsm install rws/` with no spaces at all): then the tracker is
  `named: true` and only a `remove` of that level (or above) takes it.
- **`space.yml`**: `repositories: [{url, path?, ref?}]`, cloned into that level's directory (a
  path left out is the one `git clone` would use), and for a space, `depends:`. Install clones the
  repositories of every `space.yml` under the spec, plus those of the spaces it depends on. A
  narrower spec still stows the levels above but does not clone their repositories. It never pulls.
- **`wsm install [SPEC [DIR]]` stows, as ppm does.** It runs `stow --no-folding` per level into
  `<target>/<src>/<ws>/<space>/`, ignoring the directories below (the levels of their own).
  `--no-folding` keeps directories real, so a clone never lands in the source.
  - stow runs with `HOME=$WSM_STATE_HOME/stow`, whose `.stow-global-ignore` is wsm's list
    (`.DS_Store`). stow's built-in list would drop `README.*`, `LICENSE.*` and `.gitignore`. ppm
    still uses the built-in list, so a `README.md` under a package's `home/` is not stowed.
  - With no SPEC, install takes the level at `.`, which must hold a `space.yml`.
- **Targets.** The target is DIR, else `WSM_SPACES_HOME` (`anfs.conf`, default `~/spaces`). A source
  lives in one target. A target inside a source checkout, or inside another source's installed
  tree, is refused.
- **The trackers are the state**: `$WSM_STATE_HOME/installed/<id>.yml`, where id is `src`,
  `src/ws` or `src/ws/space`. Each holds the target, the directory and the stowed files.
- **The tree mirrors the source, both ways.**
  - `wsm new` creates a space in the source. A part left out comes from the current directory,
    either a checkout or an installed tree. If the workspace is installed, the new space is
    installed too.
  - `wsm add` moves files from the tree into the source and links them back. The links are
    relative, as stow's are, because stow treats an absolute link as foreign. It never takes
    clones, repository paths or what the source's `.gitignore` ignores.
  - `wsm status` lists the differences.
  - `wsm ls [SPEC] [-r]` lists the defined levels with where each is installed, or their
    repositories' git state. `wsm cd -s` goes to the source directory instead of the installed one.
  - wsm never commits.
- **Names nest**: `ANFS_NAME_PARTS=2`, so `main/tech` is a name and `lgat/main/tech` a qualified
  one. A bare `depends:` entry is a sibling in the same workspace. Spaces don't layer
  (`ANFS_RESOLVE_FIRST`); layering may come later, which is one reason wsm uses stow.
- `remove`/`implode` unstow, then take any recorded link still pointing at the source's file, then
  the empty directories; clones and the user's files stay.

## Repository Layout

Every source is cloned once under `~/.local/share/anfs/sources/`:

```
~/.local/share/anfs/sources/   (each directory is named by its source alias)
  core/             ← this repo (the toolkit itself; anfs-io/system)
  stack/            ← the other default source (system.list): the packages, containers and skills
  user/             ← your customization repo: the "user" source, highest priority
```

This repo (`core/`) contains:
- `packages/anfs/` — the toolkit's own package: the `anfs` command, the libraries every tool
  sources (`~/.local/lib/anfs`: paths, sources, resolve), the source list and the toolkit's
  settings (`~/.config/anfs/{system.list,anfs.conf}`). It depends on every tool and what they run
  on, so `ppm install core/anfs` is the whole toolkit. Its `tests/` hold the shared-lib bats
  suites and the end-to-end round trip (Testing).
- `packages/ppm/` — ppm itself: the `ppm` command, its libraries (`~/.local/lib/ppm`) and its shell
  integration (`~/.config/{sh,zsh,bash}/{ppm,mise}.*`)
- `packages/{pcm,pmm,psm,wsm,pvm}` — the other tools, each its own package (deps, hooks, tests)
- `packages/{podman,varlock,node,qemu}` — the software the tools run on, part of the base install
- `packages/pmm-network` — the root-owned host setup pmm's networks need (Linux); not part of the
  base install
- dev/test tooling (`anfs work`, `anfs hooks` and the git hooks, `ppm container`, `ppm vm`, `ppm
  user`, `ppm move`) is the `dev` package of the anfs-dev source (`anfs-io/dev-anfs`), not here
- `skills/` — the tools' own skills (`pcm-containers`, `pmm-images`), synced by psm like any source's
- `containers/` — the test boxes (`anfs-test-debian`, `anfs-test-fedora`) as pcm services
- `isos/isos.yml` — the ISOs the base images install from: the catalogue entries their `image.yml`
  names by id, each with a pinned sha256 (`pmm iso pull`)
- `machines/` — the macOS test box (`anfs-test-macos`) as a pmm machine, and in `machines/images/`
  the base VM images (`debian-13`, `fedora-44`), each with its answer file, steps, test and README;
  other sources build on them with `from:`
- `install.sh` — bootstrap installer for new machines (installs the irreducible prereqs —
  Homebrew, stow, yq, mise — clones this repo, stows the base packages `core/anfs` and `core/ppm`,
  installs the login shell's package from stack (`stack/bash` or `stack/zsh`: only a shell
  package's rc file runs `brew shellenv`, so without one `brew` is "not found" in a new shell;
  `--no-shell` skips it, and a shell with no package gets a hint, never a failure), then
  `ppm install core/anfs`)
- Plans and design docs are not here: they are in [anfs-io/docs](https://github.com/anfs-io/docs)

The tools don't declare `depends: [anfs]` although they source `lib/anfs`: anfs depends on them,
and like stow and yq it is base software that is always present.

Every tool, anfs included, keeps to `<dir>/<tool>`: `~/.local/bin/<tool>`, `~/.local/lib/<tool>/`,
and `$XDG_{CONFIG,DATA,STATE,CACHE}_HOME/<tool>/` for its own files. Nothing is namespaced under
anfs except anfs's own (the sources, the lists, `anfs.conf`).

## Configuration: anfs.conf

One file configures the whole toolkit: `~/.config/anfs/anfs.conf` (shipped by `core/anfs`, so a
higher layer — your `user/anfs` — can replace it) and `~/.config/anfs/anfs.local.conf` (this
machine only, seeded by install.sh with `PPM_GROUP_ID`). Every tool loads them through
`lib/anfs/paths.sh` (`anfs_load_conf`):

- Each variable is named for the tool that reads it: `PCM_HEALTH_TIMEOUT`, `PSM_CLI_VERSION`,
  `HOMEBREW_*` (ppm); `ANFS_` for what every tool shares (`ANFS_UPDATE_CACHE_DURATION`,
  `ANFS_QUIET_SKIPPED_REPOS`).
- **The environment wins**, then `anfs.local.conf`, then `anfs.conf`: a variable already set is
  never overwritten, so `PCM_HEALTH_TIMEOUT=300 pcm up x` does what it says.
- The files are read, not sourced: `NAME=value` lines, a value optionally quoted. A setting can't
  run code or clobber a variable a tool set itself.

## Package Structure

Each package is a directory under `<repo>/packages/<n>/`, and every one has a `package.yml`
(the pre-commit hook refuses a commit that would leave one without):

```
packages/<n>/
  package.yml     # required: version, author, depends, categories...
  install.sh      # optional: pre/post_install hooks, OS-specific install
  home/           # optional: stow target → $HOME
```

### package.yml

```yaml
version: 0.1.0
author: rjayroach
depends:
  - ruby
  - node
```

- `version` — semver; the patch level is auto-bumped by ppm's git hook (see Git Hooks)
- `author` — package author
- `depends` — list of package names (resolved across repos in source order)
- No `depends` key if package has no dependencies
- `categories` — list of groups the package belongs to (`categories: [ai]`). Only metadata:
  names, layering and `depends:` never see it, and packages stay flat under `packages/`. A name
  is in a category when any of its layers says so, so a user repo can add packages to one.
  `ppm list @` lists the categories, `ppm list @ai` the layers in one, and `ppm install @ai`
  (or `remove`) expands to its bare names, skipping those whose `platforms` exclude this machine.
- `meta` — free-form map that ppm never reads, for other packages to read. `ai/*` agent packages
  declare `meta: {agent: <skills-cli-id>}` (one id or a list), which `psm` targets. Package
  metadata goes here rather than in a new top-level key, which would be a declared resource.

Software a package needs is declared, not installed from hooks:

```yaml
platforms: [macos]          # optional: macos, linux, debian, fedora; omit = every platform

brew: [tmux, bat]           # list: every platform
cask: [claude-code]         # Homebrew casks install on Linux too; GUI apps need a map (below)

system:                     # distro package manager
  debian: [nfs-kernel-server]
  fedora: [nfs-utils]         # keys are platform() values: debian, fedora (or linux for any distro)

# a map picks per platform: exact platform first, then "linux" on any distro
brew:
  macos: [podman, podman-compose]
system:
  linux: [podman, podman-compose]
cask:
  macos: [ghostty]          # GUI apps: macOS only
```

- A tap-qualified name (`brew: {macos: [openai/tools/tart]}`) is installed from that tap, and
  ppm runs `brew trust <tap>` first: declaring it is the decision to trust the tap, and Homebrew
  otherwise refuses the formula's dependencies from the same tap.
- `ppm install` refuses packages whose `platforms` exclude this machine (`ppm install repo/` and `@category` skip them), then installs what is missing in one batch per manager before any hook runs: system packages (one sudo prompt), brew formulas, casks (on macOS and Linux). Only the Homebrew owner installs brew/cask; other users get the command to ask for.
- A `system` map with entries for other distros but not this one (and no `linux` key) is an error.
- Mise tools: stow `home/.config/mise/conf.d/<tool>.toml`; after stowing, ppm runs `mise install` for the tools named in the resolved packages' toml files. mise itself is a **core ppm component** — `install.sh` brews it alongside stow and yq, and `core/anfs` ships its shell activation — so packages declare the *tools* they want and never `depends: [mise]`.
- Trackers record the formulas/casks ppm installed (`installed_deps`). `ppm remove` uninstalls them when no other installed package recorded or declares them. System packages are never removed.
- `-c` skips all of this, like hooks.

### Declared Resources (a package.yml key ppm core does not own)

ppm owns `version`, `author`, `depends`, `platforms`, `categories`, `brew`, `cask`, `system`, `meta` and `onboard`
(`PPM_CORE_KEYS` in `packages.sh`). **Any other top-level key is a declared resource**: during
`install_single_package`, right after stow and before the `install_<os>`/`post_install` hooks, ppm
calls `ppm_resource_<key> <repo> <package> <package_dir>` — a function another package contributes
by stowing a file into `~/.local/lib/ppm/`. (wsm used to declare spaces this way, with a
`wsm:` key; spaces are now a source's `spaces/` directory, which is the better seam for anything
that is not a package: give it a top-level directory and a tool, not a package.yml key.)

- The handler records what it created with `meta_add_resource <repo> <pkg> <key> <path>`. That
  lands in the tracker under `resources:`, which `meta_mark_installed` preserves across the
  rewrite at the end of the install, and which `ppm show` prints.
- On remove, ppm calls `ppm_resource_<key>_remove <repo> <package>` and the handler reads the
  paths back with `meta_resources`. The keys come from the *tracker*, not from package.yml: the
  package directory may already be gone. With no `_remove` handler, ppm just reports the paths.
- **A key with no handler is reported** in the end-of-run messages, without failing the install:
  since `meta:` is where metadata for other packages belongs, an unowned top-level key is either a
  resource whose provider is not installed (add it to `depends:`) or a typo. Declaring something
  and silently doing nothing is the one outcome worth ruling out.
- A handler that fails is `ppm_fail`ed and the run continues: one unreachable git remote must not
  abandon the rest of the install or skip the tracker write.
- `-c` skips resources entirely, like hooks and declared deps.

Libraries a package stows into `~/.local/lib/ppm/` are **re-sourced as soon as they are
stowed** (`_reload_stowed_libs`), so `ppm install <thing that depends on a handler>` gets the
handler in that same run rather than needing a second one. That applies to contributed commands too.

Load order in that directory is a plain alphabetical glob, so a contributed lib is sourced after
ppm's own and *can* redefine core functions. Don't: `ppm_resource_<key>` is the supported seam,
and a redefinition silently wins over ppm core with no way to tell.

### install.sh Hooks

```bash
pre_install()      # runs before stow
install_macos()    # OS-specific install (brew)
install_linux()    # OS-specific install (apt)
post_install()     # runs after stow + OS install
pre_remove()       # runs before unstow
remove_macos()     # OS-specific removal
remove_linux()     # OS-specific removal
post_remove()      # runs after unstow
```

Hooks are for imperative work (services, generated config, vendor installers). Software a package needs is declared in `package.yml` (`brew`, `cask`, `system`) and installed by ppm before the hooks run.

Available functions packages can call from their hooks:
- `debug "message"` — log debug info (visible with `--debug` flag)
- `user_message "message"` — queue a message for the user (displayed after install completes). Supports `\n` for line breaks. Auto-prefixed with `[repo/package]`.
- `ppm_fail "message"` — signal a non-fatal install failure. Prints to stderr immediately and queues for end-of-run summary. Caller should `return` after calling.
- `_system_sudo "<what>" ["<message>"]` — obtain sudo for a hook that needs root. Returns 0 with the credential cache primed, so the real command can use `sudo -n` and never block an unattended install; on failure it `ppm_fail`s with `<message>` (default: the system-package wording) and returns 1. `stack/bash` uses it to write `/etc/shells`. Call it right before the command that needs root, not once up front: **every `brew` command resets sudo's cached credentials** (Homebrew's `brew.sh` runs `sudo --reset-timestamp`), so a cache primed before the brew phase is gone by the time hooks run. With no terminal it uses `SUDO_ASKPASS` (`sudo -A`) when that is set, as Homebrew's own scripts do; that is how the macOS round trip runs unattended. `anfs implode --all` authenticates the same way right before Homebrew's uninstaller.
- `ppm_register_callback <function>` — call from `post_install` to hear about every later run
  (below). `ppm_unregister_callback` drops it.

### Post-run Callbacks

A package that reacts to *other* packages coming and going registers a function defined in its
own `install.sh`:

```bash
post_install() { ppm_register_callback psm_ppm_changed; }
psm_ppm_changed() { local event="$1"; shift; ... "$@" ... }   # event: install | remove
```

- Once a `ppm install` or `ppm remove` has finished everything (hooks, trackers, `mise install`),
  ppm calls each registered function once with the event and every `repo/pkg` that run installed
  (dependencies included) or removed. The registering package is in the list of the run that
  installs it, so that first callback can do the setup `post_install` would otherwise do.
- It runs like a hook: a subshell with the package's `install.sh` sourced and
  `PPM_CURRENT_PACKAGE` set to the registering package. A failing callback is `ppm_fail`ed and the
  others still run.
- Registrations live in `~/.local/state/anfs/callbacks/ppm.yml` (`repo/pkg: function`). Removing
  the package drops its entry, so it is never called about its own removal. (They used to be in
  ppm's `installed/callbacks.yml`; ppm moves that file once.)
- Not called with `-c`, and `-r`'s internal remove is not a removal.
- For a removal, the package directory normally still exists, so the callback can read the
  removed packages' `package.yml`. It is gone only if its repo was removed first.
- `core/psm` uses this to sync skills when an agent package (`meta.agent`) is installed, and to
  unlink them (`psm agents rm`) when one is removed.

The mechanism is not ppm's: it is `lib/anfs/callbacks.sh`, shared by every tool that emits
events. ppm keeps the package-facing names (`ppm_register_callback`, `ppm_unregister_callback`)
and how a handler is run (`ppm_callback_invoke`: a function of the package's `install.sh`).

### Callbacks Between Tools (lib/anfs/callbacks.sh)

A tool **emits** an event by calling `anfs_callbacks_run <tool> <event> <arg>...` at the end of a
command; a **listener** is whatever registered a handler with that tool. The tool knows nothing
about its listeners.

```bash
anfs_callback_register   <tool> <name> <handler>   # add or replace <name>'s registration
anfs_callback_unregister <tool> <name>
anfs_callbacks_run       <tool> <event> <arg>...   # emit
anfs_callbacks_ls        [tool]                    # tool, name, ok|stale, handler
```

- The library owns the registrations: `$ANFS_STATE_HOME/callbacks/<tool>.yml`, `name: handler`,
  one file per emitting tool. They are anfs's and not the tool's because a registration belongs
  to the listener: it lasts as long as the listener is installed. A tool's own implode deletes
  that tool's state and leaves its listeners installed, so it must not drop them. A listener
  unregisters in its `post_remove`; `anfs implode --all` clears what is left.
- By default a handler is a command line, run as `<handler> <event> <arg>...`. A tool whose
  handlers are something else defines `<tool>_callback_invoke` (ppm does).
- Each handler runs in a subshell. One that fails is reported (`anfs_warn`) and the rest still
  run; one whose command is no longer on PATH is skipped and shows as `stale`.
- **Who emits:** ppm (`install`/`remove`, with the packages) and wsm (`install` for each level
  that became installed, `remove` for each one removed, as `source`, `source/ws`,
  `source/ws/space`). wsm's are tied to the outcome, not the command: `wsm new` emits `install`
  for a space it installs, a re-install of what is installed emits nothing, `--dry-run` emits
  nothing, and `implode` emits `remove` for every level.
  psm, pcm and pmm emit nothing yet: add an emitter when there is a listener.
- A package that listens to another tool registers from its own `install.sh`:

  ```bash
  post_install() { anfs_callback_register wsm "$PPM_CURRENT_PACKAGE" "pvm link apply --event"; }
  post_remove()  { anfs_callback_unregister wsm "$PPM_CURRENT_PACKAGE"; }
  ```
- `anfs callbacks [tool]` lists them. It does not fire events; run the emitting command with `-d`.

### Lists and --json (lib/anfs/table.sh)

Every list a tool prints goes through `anfs_table`: the tool emits rows (`anfs_row <field>...`)
and names the columns, and the library picks the form.

```bash
{ anfs_row "$id" "$dir" "$note"; ... } | anfs_table "ID DIR NOTE" "id dir note"
```

| When | Form |
| --- | --- |
| stdout is a terminal | headers, then the rows, columns aligned |
| piped | the rows, tab-separated, no header |
| `--json` | a JSON array of objects, one per row |

- Cells are the same on a terminal and piped: an empty field is `-`, a path at or under `$HOME`
  starts with `~`. JSON has the raw values: the whole path, `null` for an empty field, a string
  for everything else (a version or an id that looks like a number stays a string). A key
  declared with `[]` (`provides[]`) is a list: its items shown separated by spaces, and an array
  in JSON.
- `--json` is an option `cli.sh` gives every tool, taken anywhere on the line up to a `--`. It is
  not passed on to a tool this one runs. `anfs_result k v ...` is the `--json` answer of a command
  that changes something; `anfs_json_on` asks whether it was given.
- **A tool reads another tool's list with `--json`, never by column.** pvm reads
  `wsm ls --json`; the round trips read `ppm list --json`, `pmm list --json`,
  `pmm image list --json` and `psm skills ls --json`. Keys may be added to a list; renaming or
  removing one breaks its readers. The piped form is for a person's own pipes. There is no
  special flag for another tool's benefit: `pcm list --names` is gone, and `ppm container` and
  `ppm vm` read `list --json` like any reader (`ppm vm ip` is `pmm list`'s `address`).
- Detail views (`pcm inspect`, `ppm show`) are not tables and do not go through this.

The keys, which are the interface:

| Command | Keys |
| --- | --- |
| `wsm list` | `id` (a source's ends in `/`), `dir`, `level` (`source`, `workspace`, `space`), `note` (`stale`, `not in the source`) |
| `wsm list -r` | `path`, `url`, `state` |
| `ppm list`, `ppm list --installed` | `package`, `installed` (the version, null when not installed) |
| `pcm list` | `name`, `source`, `status` |
| `pmm list` | `name`, `source` (null: run from an image, or the definition is gone), `image`, `state` (`running`, `stopped`, `defined`, `shadowed`), `address` |
| `psm skills list` | `status`, `config`, `skill`, `repo` |
| `psm repo list` | `config`, `repo`, `note` |
| `anfs callbacks` | `tool`, `listener`, `state`, `handler` |
| `anfs src list` | `alias`, `url`, `list` (`user`, `system`), `status`, `provides` (a list) |
| `anfs iso list`, `pmm iso list`, `ventoy iso list` | `id` (null: a file no entry names, with `--all`), `name`, `architecture`, `file`, `state` (`present`, `missing`, `unverified`: there, with no recorded sum; `unlisted`; `invalid`: the entry's file name is missing or has a `/`), `size` (bytes in JSON), `catalog` (the `isos.yml` that defines the entry) |
| `pmm ps` | `name`, `arch`, `backend`, `pid`, `ssh` |
| `pmm image list` | `name`, `source` (null: the definition is gone), `arch` (null: not built), `state` (`built`, `stale`, `unbuilt`, `shadowed`), `key`, `disk` (a tart build: its VM's name), `backend`, `user`, `sshkey`, `held` (a list: `web1`, `web1@s1`), `built` (when), `tested` (true when this build passed `image test`) |
| `pmm snapshot list` | `name`, `build` (the build key it is on; null for a tart snapshot) |
| `pmm network list` | `name`, `source` (null: made with `network create`, or the definition is gone), `kind`, `subnet` (a bridged network: its bridge), `state` (`active`, `inactive`, `missing`, `defined`, `shadowed`), `machines` (comma-separated) |

### The Command Line (lib/anfs/cli.sh)

Every tool's commands are declared, once, and everything a person meets comes from the
declaration: the usage line, help, the check of what was typed, and tab completion. Nothing about
a command is written twice.

```bash
cli_cmd remove "Down, then delete everything pcm created for it" \
  --alias rm \
  --opt "-y --yes: Do not ask" \
  --opt "-f --force: Also remove what depends on it" \
  --arg "service..."
cli_group skills "Declared skills and their state"
cli_cmd "skills remove" "Remove skills" --alias rm --arg "skill..."
cli_standard                 # completion and help, last
cli_dispatch "$@"
```

- A two-word name is a sub-command; its function is `cmd_skills_remove`. A group on its own
  prints its sub-commands. No tool writes its own second-level `case`.
- `--opt "-y --yes: help"` is a flag; a word after the names (`--to SPEC`) means it takes a value,
  and the word is its **kind**. `--arg "service..."`, `--arg "[snapshot]"`: `[..]` is optional,
  `...` is one or more, the word is its kind.
- `--passthrough`: options the command does not declare are left for it, in place (`pcm up`,
  `pcm ps`, `pmm shell`: they go on to podman or ssh).
- **The function gets positional arguments as `"$@"` and options in `CLI_OPT`**, keyed by the long
  name without dashes: `${CLI_OPT[yes]:-false}`, `${CLI_OPT[to]:-}`. A value option given twice
  holds both, one per line. No command writes a loop over its own options.
- Options may come anywhere after the command, up to a `--`. Short flags run together (`-cfr`).
- Before the function runs the line is checked. An unknown option, a missing value, too few or
  too many arguments are refused the same way by every tool, with exit 64:

  ```
  pmm: unknown option '--bogus'
  pmm: usage: pmm image build [-f] [-v] [--arch ARCH] [--console] [--test] <image>...
  ```
- `cli_usage_err "message"` is for what a declaration cannot say (`--to` is required). An unknown
  command exits 64 too.
- One command runs another with `cli_call <command> <args...>`, which gives it its own options and
  makes it the running command (its usage line is what `cli_usage_err` prints), and
  puts the caller's back. Tests run a command the same way.
- `cli_before_command`, if the tool defines it, runs between the line being read and the command.
  ppm uses it (below).
- Every tool also takes `-d`/`--debug` and `--trace` before the command, `--json` anywhere,
  `--version` (the package's `package.yml` version unless the tool sets `CLI_VERSION`), `-h`/
  `--help`, `<command> --help` and `help <command>`.
- A `cmd_` function nothing declared still runs, with its arguments untouched: plumbing such as
  `psm path`. *Only* `cmd_` functions run, so a tool's internals are never reachable from its
  command line, and a command can never shadow a system binary in package hooks (`install`, `file`).
- A tool whose tests source its libraries directly keeps its declarations in a library file
  (`lib/pmm/commands.sh`, `lib/pcm/commands.sh`), so the tests have them too.
- `cli_section "<title>"`: the top-level commands declared after it are listed under that heading
  in help, after the others (anfs's "Tools" and "From packages").

**The tools as `anfs <resource>`.** anfs declares one command per tool, named for what it manages,
with the tool's name as an alias, and execs the tool with the rest of the line (output, exit status
and all):

| Command | Alias | Runs |
| --- | --- | --- |
| `anfs package` | `anfs ppm` | `ppm` |
| `anfs container` | `anfs pcm` | `pcm` |
| `anfs machine` | `anfs pmm` | `pmm` |
| `anfs skill` | `anfs psm` | `psm` |
| `anfs space` | `anfs wsm` | `wsm` |
| `anfs vault` | `anfs pvm` | `pvm` |

- `anfs machine image build debian-13` is `pmm image build debian-13`; `anfs help machine` is
  `pmm help`; `anfs __complete machine ...` is `pmm __complete ...`. They are listed under "Tools"
  in `anfs help`.
- The tool is `~/.local/bin/<tool>`, as `anfs install` runs it. One that is not there is
  `pmm is not installed (ppm install core/pmm)`, exit 69.
- `sh/anfs.sh`'s `anfs` function sends each of the six through the tool's own shell function when
  it has one, so `anfs package cd` and the reload after an install work as `ppm`'s do, and `anfs
  space cd`, `anfs machine cd` as `wsm`'s and `pmm`'s. A global option first (`anfs -d package
  ...`) skips the function and goes to anfs, which still runs the tool.

**Commands from packages: `anfs <name>` runs `anfs-<name>`.** For a name anfs does not declare,
anfs execs the executable `~/.local/bin/anfs-<name>` with the rest of the line. That is the only
seam by which a package adds a command, and it is anfs's alone:

- Nothing is sourced into anfs, so a package cannot redefine anything of anfs's. A declared
  command or alias always wins: no package can ship `anfs-src` or `anfs-package`.
- The executable is a `cli.sh` tool like any other and sets `CLI_TOOL="anfs <name>"`, so its
  messages and usage lines read `anfs work: ...`. It sources `bash.sh` first like every entry
  point (`bash.bats` checks every `anfs-*` in core's packages; anfs-dev checks its own).
- `anfs help` lists them by name under "From packages", read from the file names (no process);
  `anfs help <name>` and `anfs <name> --help` are the executable's own. `anfs __complete <name>
  ...` asks `anfs-<name> __complete ...`; the name itself completes in anfs.
- `-d`, `--trace` and `--json` given to anfs are passed on, to a package's command and a tool alike.
- `anfs <name> cd ...` goes through the shell function: it `cd`s to `anfs <name> path ...`.
- The other tools get no such seam. ppm keeps what is about packages: hook helpers a package stows
  into `lib/ppm` (`stack/ruby`'s `install_gem`) and `ppm_resource_<key>` handlers. The `cmd_`
  functions anfs-dev/dev still stows there (`ppm container`, `ppm vm`, `ppm user`, `ppm move`) are
  the last of that use, until anfs-dev's plan 03 replaces them.
- anfs-dev/dev's `anfs work` and `anfs hooks` are the first (`packages/dev/README.md` there).

**The verbs are the same everywhere.** `list` (alias `ls`), `remove` (alias `rm`), `install`,
`show`, `path`, `cd`, `validate`, `implode`, at the top level and in groups (`psm skills list`,
`pvm link remove`, `ppm container remove`, `pmm image list`). `image` is the group for what a
tool's main object runs from, and `pmm image` is the reference for it: besides the shared verbs,
`build`, `test` (boot it and run its test; `validate` only reads the definition), `export` and
`prune`. pcm and pmm keep `up`/`down`/`ps`, the names of what
they wrap, with `stop`/`ssh` as aliases (pmm's `run` is its own command: a machine from an image); wsm's `status` is a different question from `ps`.
Options: `-y, --yes` does not ask, `-f, --force` replaces what is in the way, `-n, --dry-run`
says what would happen.

**ppm's options are its commands' own**, like every tool's: `ppm install -f pkg` or
`ppm install pkg -f`, and `ppm list -f` is refused. Its helpers still read `$force`, `$config`,
`$reinstall`, `$skip_deps` and `$yes` by name through dynamic scoping, because four of those files
are sourced by `install.sh` under bash 3.2, which sets the same variables itself: `main()` declares
them, and `cli_before_command` fills them from `CLI_OPT` once the line is read. The `cmd_`
functions in the bootstrap files did not change.

**Exit codes:** 0 done; 1 what was asked for is not there or could not be done; 2 ambiguous;
64 used wrongly; 69 something this needs is missing; 73 already exists; 75 locked.

**Completion asks the tool.** `<tool> __complete <words...>` answers from the declarations: the
last word is the one being typed, and the answer is candidates, one per line,
`value<TAB>description`, or `:files` / `:dirs`. `<tool> completion zsh` prints a 30-line script
that only calls that, so the copy `zcomp` caches holds nothing about the tool's commands and
cannot go stale.

- A command is offered once, its aliases in its description; an alias is offered itself only when
  what is typed can be nothing else (`rm<TAB>`).
- Options are offered only once a `-` is typed.
- An argument or an option's value completes by its kind: the tool's `complete_<kind>` function
  (one candidate per line), a path for `dir` and `file`, nothing otherwise. The arguments
  already on the line are in `CLI_COMPLETE_ARGS`, for one that depends on them: pmm's
  `complete_snapshot` lists the snapshots of the machine before it.
- **`complete_<kind>` functions must be fast: file names only, no yq, no git, no list command.**
  A tab press starts the tool (25 to 40 ms) and runs one of these; the whole is under 100 ms, and
  `registry.bats` holds the library to that. `wsm ls` takes 240 ms, which is why completion does
  not call it.
- One tool may complete another's things by asking it: pvm's `--to` runs
  `wsm __complete install ""`.

**Shared helpers, used by every tool** (a tool's own `tilde`, `_display`, `confirm` are one-line
aliases of these; don't write another):

- `anfs_confirm "<what this does>" "<the question>"` (cli.sh) asks before something that cannot
  be undone: true at once with `-y`; without a terminal it says to pass `-y` and exits 1; anything
  but a y exits 1 with "nothing done".
- `anfs_display <path>` shows a path with `~` for home, whether it is spelled as `$HOME` or as what
  `$HOME` resolves to; `anfs_canon <dir>` resolves one (paths.sh).
- `anfs_require <command> [hint]` (log.sh) stops with 69 when something is missing.
- **`lib/anfs/catalog.sh`** finds the definitions of one kind across the sources and resolves a
  name to one: `catalog_load <kind> <marker> <local alias> <local dir>`, then `catalog_canon`,
  `catalog_dir`, `catalog_all_ids`, `catalog_effective_ids`. pcm (`containers`, `compose.yml`) and
  pmm (`machines`, `machine.yml`; `machines/images`, `image.yml`) are built on it; a new tool with
  definitions in sources uses it too.
  One catalogue per process: a tool with two kinds loads one, uses it, then loads the other.

### Messages, Debugging and the Log (lib/anfs/log.sh)

Every tool says things through `anfs_info` (stdout), `anfs_warn`, `anfs_die`, `anfs_fail <code>`
and `anfs_debug` (stderr, as `<tool>: <msg>`; the name is `$CLI_TOOL`). A tool's own `warn`/`die`
are one-line aliases of these. Don't `echo "tool: ..." >&2` in new code.

- **`-d`/`--debug` and `--trace` come before the command** on every tool (`--json`, above, goes
  anywhere) (`cli.sh` strips them in
  `cli_dispatch`; a tool that looks at its arguments first calls `cli_globals`). `ppm` also takes
  them after the command, with its other flags. Debugging is `ANFS_DEBUG` (every tool) or
  `<TOOL>_DEBUG` (one); `-d` exports `ANFS_DEBUG`, so a tool run by a callback debugs too.
- **The log is always written**: `~/.local/state/anfs/anfs.log`, one file for every tool, every
  warn/error/debug line plus one `start:` line per invocation, whether or not `-d` is on. `anfs log
  [-f] [tool]` prints or follows it. Past 1 MB it becomes `anfs.log.1`.
- `ANFS_LOG=off` writes no file. Test helpers set it; a test that sources a tool's libraries
  directly must source `log.sh` first (pmm's and ppm's do), since the tool's `warn`/`die` call it.

## Key Files

- `~/.config/anfs/system.list` — default sources, shipped/stowed by `core/anfs` (don't edit)
- `~/.config/anfs/user.list` — your sources (edited by `anfs src`); higher priority than system.list
- `~/.local/share/anfs/sources/<alias>/` — one clone per source; a local-path source is a link here
- `~/.cache/anfs/updated/<alias>` — each source's last successful clone/pull. `ppm install`,
  `pcm up`/`install` and `anfs install` auto-update only the sources older than
  `ANFS_UPDATE_CACHE_DURATION` (default 24h); a source skipped for uncommitted changes stays stale
  on its own and is rechecked next time. Install prints one `Not updated (uncommitted changes):
  <repos>` line for them; `ANFS_QUIET_SKIPPED_REPOS=true` in `anfs.conf` moves it to `--debug`
- `~/.config/anfs/anfs.conf` — settings for every tool (see Configuration)
- `~/.config/anfs/anfs.local.conf` — machine-local settings (not committed)
- `~/.local/state/ppm/installed/<repo>/<pkg>.yml` — per-package install tracker (version, timestamp, stowed files, `installed_deps`, `resources`)
- `~/.local/state/ppm/installed/callbacks.yml` — packages registered for post-run callbacks (`ppm_register_callback`)
- `~/.local/state/ppm/installed/protected.yml` — files `ppm file protect` detached from ppm; seeded into stow's ignore list so they are never re-linked
- `~/.local/bin/<tool>` — each stowed from its package (`core/anfs`, `core/ppm`, `core/pcm`, ...)
- `~/.config/sh/*.sh`, `~/.config/zsh/*.zsh`, `~/.config/bash/*.bash` — package-contributed shell snippets (see Shell Integration). `ppm.*` and `mise.*` come from `core/ppm`, `anfs.sh` from `core/anfs`
- `~/.local/lib/anfs/*.sh` — what every tool sources (paths, sources, resolve)
- `~/.local/lib/ppm/*.sh` — ppm's own libraries (stowed from `core/ppm`) plus package-contributed library extensions. Extensions add helpers for hooks (e.g. `stack/ruby`'s `install_gem`) or, for now, commands: a function named `cmd_foo`, registered with `cli_cmd`, becomes `ppm foo` (anfs-dev/dev's `ppm user`; new commands are `~/.local/bin/anfs-<name>`, run as `anfs <name>`)
- `~/.cache/ppm/brew_last_update`
- Each tool keeps its own state in its own XDG dirs: `$XDG_{CONFIG,DATA,STATE,CACHE}_HOME/<tool>`

## Shell Integration

ppm supports multiple shells by convention, not by machinery: a package ships one file per
shell it supports, and a file for a shell you don't use is simply never sourced. There are
three tiers under `$XDG_CONFIG_HOME`, and a package ships only the ones it needs:

| Path in the package | Sourced by | Holds |
| --- | --- | --- |
| `home/.config/sh/<name>.sh` | the bash **and** zsh rc | portable: aliases, exports, PATH, plain functions |
| `home/.config/zsh/<name>.zsh` | the zsh rc | zsh-only: completions, `mise activate zsh`, `$+functions` |
| `home/.config/bash/<name>.bash` | the bash rc | bash-only: `mise activate bash`, bash completions |
| `home/.config/fish/conf.d/<name>.fish` | fish itself | fish autoloads `conf.d`, so no rc glue is needed |

Rules:

- **Portable first.** Anything that works in both shells goes in `sh/`. Only genuinely
  shell-specific code gets a per-shell file. This is what stops every package from
  triplicating the same aliases.
- **Order is `sh/` then `<shell>/`.** A `sh/` file must not rely on a helper defined in a
  `<shell>/` file at *source* time; calling one at *runtime* is fine. `sh/ppm.sh` does exactly
  that: it defines the `ppm()` wrapper and calls `_ppm_shell_reload` (defined per shell) only
  after a successful `install`/`remove`/`src update`.
- **The rc file belongs to a shell package, never to `core/anfs`.** `stack/zsh` owns
  `.zshrc`/`.zshenv` and its sourcing loop; `stack/bash` owns `.bashrc`/`.bash_profile`. With no
  shell package installed nothing sources anything — `ppm` still works, but `ppm cd` and mise
  activation are absent. A rc that adds the `sh/` tier must also add it to any reload helper it
  ships (`stack/zsh` updates both `.zshrc` and `zsrc`).
- **The rc sets the base environment before it sources any snippet** — XDG vars, `$BIN_DIR`,
  Homebrew, `$BIN_DIR` first on PATH. It must not live in a snippet: snippets guard on
  `command -v <tool>`, so a tool that isn't on PATH yet makes them silently no-op. This is why
  `stack/zsh` keeps that block in `.zshrc` rather than in `aliases.zsh`, and `stack/bash` in
  `.bashrc`. Reloading must stay idempotent (`ensure_path` strips before prepending).
- **Re-assert Homebrew's PATH entries on every rc run, outside the `shellenv` guard.**
  `brew shellenv` forks, so it sits behind `if [ -z "$HOMEBREW_PREFIX" ]` — everything else it
  exports (`HOMEBREW_*`, `FPATH`, `INFOPATH`) survives being inherited, but PATH does not. macOS
  runs `/usr/libexec/path_helper` from `/etc/zprofile` and `/etc/profile` in *every* login shell,
  including nested ones (tmux starts one by default, as do `zsh -l`, ssh to self, and an editor's
  or agent's shell), and it rebuilds PATH with `/etc/paths` in front. A nested login shell
  inherits `$HOMEBREW_PREFIX`, the guard skips `shellenv`, and the demotion stands:
  `/opt/homebrew/bin` below `/bin`, so `bash` silently resolves to Apple's 3.2.57 again. Both rcs
  therefore call `ensure_path` on `$HOMEBREW_PREFIX/sbin`, then `$HOMEBREW_PREFIX/bin`, then
  `$BIN_DIR`, unconditionally. Each call prepends, so that order leaves `~/.local/bin` first.
- **`ensure_path` is rc-provided base API in both shells.** `.zshrc` and `.bashrc` each define it
  before their snippet loop, so a portable `sh/` snippet may call it, not only a `zsh/` or
  `bash/` one (`stack/solana` does today from `.zsh`). The bash copy is written
  for bash 3.2.
- **A shell whose rc path is fixed has to move the distro's file aside.** `~/.bashrc` exists on
  stock Debian and Fedora, so `stack/bash`'s `pre_install` renames it to `.bashrc.pre-ppm` (and
  `post_remove` restores it); otherwise stow aborts the install and `-f` would delete it. Note
  that shipping `~/.bash_profile` also stops login bash from reading `~/.profile`, which is what
  puts `~/.local/bin` on PATH on Debian — another reason the rc owns the base environment.
- **The shell package owns the login shell.** `stack/zsh`'s `post_install` chsh's to the distro
  zsh; `stack/bash`'s does the same for `$(brew_prefix)/bin/bash`, **on macOS only**. There
  `/etc/shells` lists just `/bin/*`, and `chpass` rejects anything unlisted, so the hook
  registers the path first (`grep -qxF`, then `_system_sudo` and `sudo -n tee -a`) and only then
  chsh's — falling back to `sudo -n chsh -s <shell> <user>` because an unprivileged `chsh` cannot
  authenticate without a TTY. A macOS update rewrites `/etc/shells`, so re-running the install is
  what puts the entry back; every step is a no-op once settled. Register the brew *prefix*
  symlink: a `readlink -f` Cellar path breaks on the next `brew upgrade bash`, and
  `command -v bash` is worse still — hooks run under whatever bash won the PATH race, possibly
  the 3.2 being escaped. On Linux the distro bash is already 5.2+ and stays the login shell:
  brew's Linux prefix is under `/home` (may be unmounted at login via autofs or NFS), SELinux
  labels binaries there `user_home_t` not `shell_exec_t`, and brew may link its own glibc.
  Neither package rolls the login shell back on remove — `stack/bash` does not uninstall the
  formula, so the shell keeps working, and `/etc/shells` is machine-wide.
- **The rc only loads for interactive shells** (`case $- in *i*)` in bash, zsh's own rule for
  `.zshrc`). So `ssh host 'ppm ...'` gets the real `ppm` binary from PATH, not the wrapper, and
  no mise activation. Test with `bash -lic`, never `bash -lc`.
- **Glob two levels** (`*.sh` and `*/*.sh`), which is what packages actually use
  (`~/.config/zsh/op/`, `ssh/`, `ruby/`). Don't reach for bash's `globstar`: macOS ships bash
  3.2, which doesn't have it.
- **Guard every helper borrowed from another package.** `core/anfs`'s files use `stack/zsh`'s
  `zcomp`, `zsrc` and `load_conf` when present and degrade silently when not, because ppm must
  not depend on a package repo. The dependency is one-way: `stack/zsh` knows nothing of ppm.
- **Don't declare software the bootstrap owns.** `core/anfs` ships mise's activation but no
  `brew: [mise]`, and `stack/bash` declares no `brew: macos: [bash]` — both are untracked
  `install.sh` bootstrap formulas, and declaring them would let `ppm remove` uninstall what ppm
  itself runs on.

## Source Precedence

Sources come from two lists, read in priority order: `user.list` (yours) first, then
`system.list` (shipped defaults). An alias declared in both is taken from `user.list`.
`anfs src add/remove/ssh` only ever edit `user.list`; `anfs src list` shows both, with what each
source provides. The order is global — one order for every tool — and within it each tool sees
only the sources holding its directory. When a package exists in multiple repos, each copy is a
layer:

- `ppm install git` installs every `git` package in source order (e.g. `user/git`, then `stack/git`). The layers share one stow ignore list (`PPM_IGNORE_ARGS`), so files stowed by a higher-priority layer are skipped by lower ones. This lets personal repos override individual files.
- `ppm install stack/git` installs only that layer. It hits a stow conflict on files owned by a higher layer; this is intended.
- `core` is last in `system.list`, so every other source may layer over its packages and depend
  on what it ships (`depends: [node]` resolves to `core/node`).

## Your Customization Repo

The alias `user` (`PPM_USER_REPO_ALIAS` in `core.sh`) is always your own repo:

- `anfs onboard` (its `repo` step, `lib/anfs/onboard.sh`) creates it locally: `git init` at `~/.local/share/anfs/sources/user`, an `anfs` package holding `user.list` (listing the repo itself, as a local path), registered at the top of `user.list`, then `ppm install -f user/anfs` swaps the plain `user.list` for a link into the repo. `--repo <url>` does what `install.sh --repo` does; `--repo new` is `local` plus stack/git's `publish` step creating it on GitHub and rewriting the `user` line to that URL. This replaced `ppm customize`.
- `anfs onboard [--check] [step...]` is the whole walk from a fresh install, and it is extensible: anfs owns only the runner and two steps, `packages` (what the sources offer and is not installed) and `repo`. Every other step belongs to an installed package:
  - **Declared** in `package.yml` under `onboard:` (a key ppm owns): `offer` (one line, read while the package is *not* installed, so no code of a package you did not choose ever runs), `steps` (`name`, `summary`, `after`, `before`; names nobody has are ignored, so they never require another package) and `options` (the spec strings `cli_cmd --opt` takes; read from every source's packages when the line is about onboard, so `--install op --vault Dev` works in one go).
  - **Implemented** in the package's `install.sh` as `onboard_<step>_detect` (true when done, no side effects: it is all `--check` runs) and `onboard_<step>` (detect, then apply). The contract and the helper functions (`onboard_get/set`, `onboard_opt`, `onboard_detail/state`, `onboard_propose/confirm/ask/choose`, `onboard_user_repo`, `onboard_commit`) are in `lib/ppm/onboard.sh`.
  - **Run** by `ppm __onboard <repo/pkg> <function>`, one process per call, so steps share what they learn through a facts file that lasts for the run. Exit 0 is done, 1 is not done, anything else ends the walk (64: a question no option answered).
  - Nothing is recorded: a rerun does only what is missing. `-y` takes proposals but never installs an offer, authorizes a key, picks a vault or publishes a repo; those need their option.
  - `stack/git` (identity, github, publish), `stack/ssh` (key, access) and `stack/op` (pm, pm-key, pm-github) are the first to use it. Tests: `packages/anfs/tests/onboard.bats` (the runner, with a fixture source) and stack's `packages/git/tests/onboard.bats` (those steps, with `gh`, `op` and `ssh-add` stubbed).
- Its `anfs` package is a layer of `core/anfs`, so files it ships win over the toolkit's defaults: its `user.list`, and its own `anfs.conf` for every tool's settings. One package is all a customization repo needs to configure the toolkit.
- `install.sh --repo <url>` registers that URL as `user` and installs `user/anfs` with `-f`.
- `ppm file claim` defaults to it.
- Local-path sources are never pulled: after pushing it, set the `user` line in `user.list` to the git URL.

## Homebrew Ownership

Homebrew supports one owner per installation (`/opt/homebrew` on Apple silicon macOS, `/home/linuxbrew/.linuxbrew` on Linux; Intel Macs are not supported). The user who installed it owns it and is the only one who installs, updates or upgrades formulas. Other users on the machine run the tools but never write to the prefix. ppm puts brew on PATH itself (`brew_env`), skips `brew update` for non-owners, and uses `brew_require_owner` to tell a non-owner which command the owner has to run.

## Claiming and Protecting Files

Three levels of ownership for an individual file: ppm owns it (default), *you* own it in
*your repo* (`claim`), or *you* own it locally with ppm detached (`protect`).

- `ppm file claim <file...> [--repo REPO] [--package NAME]` copies files into `REPO/NAME/home/` and stows them from there. The default repo is `$PPM_DEFAULT_REPO` (default `user`, settable in `anfs.conf`). The default package has the same name as the owning package. A new package with a different name gets `depends: [<owner>]`.
- `ppm file add <repo/package> <file...>` is `claim` for files no package owns yet (`ppm file claim <file...> --package repo/package`; `--package` accepts that form everywhere). The target is mandatory and the package is created if missing. Directories are refused: pass `dir/*` and let the shell expand it, so exactly the named files move. Stow's `--no-folding` keeps the directory real with a link per file, so files a tool creates there later stay local until added too.
- **Never put a space in a package**: a space is `spaces/<ws>/<space>/` in a source, and wsm links it into its target and records it (and implode unlinks it). A space stowed by ppm would be files no tool can remove. Files in a wsm tree go into the source with `wsm add`, not `ppm file add`.
- Protected files are refused by `claim`/`add` (unprotect first): claim's stow does not use the protected ignore list.
- `ppm file reset <file...>` deletes the claimed copy, restores the owner's link, and removes the claimant package if it becomes empty.
- `ppm file protect <file...>` turns a package-managed symlink into a plain local copy (preserving its content) and records it in `protected.yml`. ppm then never re-links or force-removes it — including under `-f` — so you can customize it without a repo. The file is also dropped from its package's tracker.
- `ppm file unprotect <file...>` removes it from `protected.yml`; the next `ppm install -f <package>` re-links it.
- Claims are recorded in `~/.local/state/ppm/installed/claims.yml` (file → claimant, owner); protections in `~/.local/state/ppm/installed/protected.yml` (a plain list of `$HOME`-relative paths). The per-package trackers are updated to match.
- None of these touch git. Commit the changes in the repo yourself.
- `ppm install -f` never deletes a file of yours. `force_remove_conflicts` (`installer.sh`) deletes only a link into the sources; anything else in stow's way is moved to `~/.local/state/ppm/backup/files/<path>` and recorded in `backup/manifest` (`repo/pkg<TAB>path`). `ppm remove` of that package puts it back (`_backup_restore`, skipped by a reinstall), and `ppm implode` restores whatever is left before it deletes the state dir, beside the path as `<path>.pre-ppm` when the path is taken. The first backup of a path is the pre-ppm original and is never replaced. `packages/ppm/tests/backup.bats`.

## Dependencies

- `yq` (mikefarah/yq) — for YAML parsing of package.yml and tracker files
- `stow` — GNU Stow for symlink management
- `git` — repo cloning and updates

## Development

Plans are in [anfs-io/docs](https://github.com/anfs-io/docs) (`units/`, cloned in the `anfs`
wsm space). Follow the Chorus methodology:
1. Read the unit `.md` for objectives
2. Read the plan's `plan.md` for implementation spec
3. Implement and test
4. Write `log.md` on completion

### Git Hooks

`core/dev` ships a `pre-commit` hook that bumps a package's patch version when a commit touches
it, and creates `package.yml` for a package that has none. It then refuses the commit if any
directory under `packages/` would be left without a `package.yml` (a `package.yml` deleted on its
own) or with one that is not a YAML map with `categories`, if present, a list (checked when `yq`
is installed). The files live in the package at
`packages/dev/home/.config/git/ppm-hooks/` and are stowed to `~/.config/git/ppm-hooks/`. (The
`dev` package is in the anfs-dev source now.)

`anfs hooks` (the package's `anfs-hooks`) wires them up, because **git does not carry hooks
through a clone** — so this is an install step, not repo content:

```
anfs hooks status [--all] [repo...]
anfs hooks install [--all] [repo...]
anfs hooks uninstall [--all] [repo...]
```

With no repo names it acts on the `system.list` repos; `--all` adds your `user.list` ones.
The package's `post_install` runs `anfs hooks install`, and its `post_remove` runs
`anfs hooks uninstall --all`. Re-run `anfs hooks install` after `anfs src add`, since `post_install`
can't know about a repo added later. `anfs work new` wires the hooks into a job's worktrees itself.

How it is wired, and why:

- Each repo gets **`core.hooksPath` set locally**, pointed at the stowed directory. Pointing at
  the stowed path (not into the package) means editing a hook takes effect in every repo at once,
  and a higher-priority layer can override a single hook file through stow.
- **Never set `core.hooksPath` globally.** A global value applies to every repo on the machine
  *and* suppresses each repo's own `.git/hooks`, which would silently disable husky/lefthook/
  overcommit in unrelated projects. `init.templateDir` is no good either: it copies at
  `git init`/`clone` only, isn't retroactive, and the copies go stale.
- `core.hooksPath` replaces a repo's `.git/hooks` wholesale, so `anfs hooks install` warns when
  the repo already has real hooks there, and leaves a `core.hooksPath` it didn't set alone.
  `uninstall` only unsets the value it wrote.
- A `core.hooksPath` pointing at a missing directory is harmless — git finds no hooks and commits
  normally — so a leftover setting can never block a commit.

The bump rule is **once per unpushed series**: the hook compares the working version against the
version at the push base (`@{upstream}`, else `origin/HEAD`/`main`/`master`) and only bumps when
they match. So a run of commits before one push bumps once, `git commit --amend` doesn't bump
again, and a version you set by hand is respected. A repo with nothing pushed yet has had zero
pushes, so it gets zero bumps: a new package settles at `0.1.0` and stays until its first push.
A version that isn't `N.N.N` is left alone rather than mangled.

`lib/package-meta.sh` next to the hook is deliberately standalone — it uses `sed` rather than
`yq` so a hook never depends on ppm's environment, and it stays out of `~/.local/lib/ppm/`
because its `meta_*` names would share a namespace with `packages.sh`'s.

### Moving a Package Between Repos

`core/dev` ships `ppm move`, which relocates a package from one source repo to another. The files
live in the package at `packages/dev/home/.local/lib/ppm/move.sh`, stowed to
`~/.local/lib/ppm/move.sh` — a function named `move` there becomes `ppm move`, like `ppm user`
(the old seam; a new command is an `anfs-<name>`, see "The Command Line").

```
ppm move <repo/package> <target-repo>      # e.g. ppm move stack/rails user
  -f, --force   move despite uncommitted changes or a broken dependency
```

It unstows the package, moves the directory, stows it again from its new home, moves the install
tracker (`installed/<repo>/<pkg>.yml`, keeping its version, files and `installed_deps`), repoints
any `claims.yml` entry that names the package as claimant or owner, and commits both repos. The
source spec must be fully qualified: a bare name matches a layer in every repo.

- **Install hooks are not re-run.** The package's content is unchanged, only its path, so
  `pre_remove`/`post_install` would tear down services and rewrite generated config for nothing.
- **Restowing is not a plain `stow_package`.** `stow -D` only removed the links that point into
  *this* package dir, so re-stowing the whole directory would collide with the files a
  higher-priority layer owns. The tracker lists what this layer actually had, so `move` stows with
  the *complement* as the ignore list — which also leaves `ppm file protect`ed files alone. stow
  aborts the whole operation on the first conflict, so a failed stow rolls the move back; if the
  same conflict then fails the restore, it says to run `ppm install -f <pkg>`.
- **It refuses a move that would break a dependent**, unless `-f`. `_resolve_one` passes the
  depending layer's repo index as `min_index`, so a dependency only ever resolves to the same or a
  lower-priority repo — moving a package *up* in priority orphans anything below it that depends
  on it. `depends:` names a package, not a repo, so no dependent needs editing otherwise; there is
  deliberately no rename.
- **It refuses a repo with uncommitted changes**, unless `-f`. The commits are pathspec-limited to
  `packages/<pkg>`, so even under `-f` unrelated changes stay out of them, and the index is
  re-added afterwards because a partial commit leaves the pre-hook content staged for whatever the
  `pre-commit` hook rewrote (the version bump).
- **An existing package of that name in the target is refused outright**, `-f` included: `-f` must
  never overwrite package sources.

### Lib Structure

ppm is the `core/ppm` package: the `ppm` script and its libraries live under
`packages/ppm/home/` and are stowed to `~/.local/bin/ppm` and `~/.local/lib/ppm/`
(its shell snippets go to `~/.config/{sh,zsh,bash}/` — see Shell Integration). What every tool
shares is the `core/anfs` package's `~/.local/lib/anfs/`.
The `ppm` script holds only bootstrap: paths, library sourcing, flag parsing and dispatch. Each
command lives in the lib file for its area, next to its helpers:

```
packages/anfs/home/.local/lib/anfs/     what every tool sources
  bash.sh      # the bash floor (5.2): re-exec under a newer bash, or exit 69. Sourced first by
               # every entry point, and the one file here that must run under bash 3.2
  log.sh       # anfs_info/warn/die/fail/debug, the log file (anfs log), ANFS_DEBUG, ANFS_TRACE
  callbacks.sh # anfs_callback_register/unregister, anfs_callbacks_run (emit), anfs_callbacks_ls
  catalog.sh   # the definitions of one kind across the sources (pcm's services, pmm's images):
               # catalog_load, catalog_canon, catalog_all_ids
  iso.sh       # install ISOs: the store ($ANFS_ISO_HOME, ~/.cache/anfs/isos), anfs_iso_fetch (resume,
               # mirrors, sha256 or the publisher's checksum file), and the catalogue layered over the
               # sources (isos/isos.yml, ~/.config/anfs/isos.yml first): anfs_iso_ids, anfs_iso_fetch_id.
               # pmm (its images pin a sha256; media:) and stack's ventoy use it.
               # anfs_iso_cli declares the `iso` group, written once here (cmd_iso_*, complete_iso):
               # list [--all], show, pull (alias get), add <url|file>, remove [--entry], path, prune.
               # A tool adopts it with that one call beside its own declarations: anfs, pmm, ventoy.
               # prune is refused while a catalogue is not a list of entries (anfs_iso_bad_catalogs)
               # or there is no entry at all: an unreadable catalogue is otherwise read as empty,
               # and every file it names would be a stray. A filename with a / is never used
  table.sh     # anfs_row, anfs_table (aligned on a terminal, tab-separated piped, --json),
               # anfs_result, anfs_json_on
  paths.sh     # ANFS_* paths, anfs_tool_paths <tool> (<TOOL>_{CONFIG,DATA,STATE,CACHE}_HOME),
               # anfs_load_conf (anfs.local.conf, anfs.conf; the environment wins)
  sources.sh   # gitsrc_*: source lists, clone/pull/link, status, provides, the `src` command;
               # anfs_gitsrc_env points it at anfs's lists
  cli.sh       # the command line: cli_cmd / cli_group declarations, and from them help, the
               # check of the line (CLI_OPT), `__complete`, cli_call, anfs_confirm
  resolve.sh   # anfs_sources <dir>, anfs_find, anfs_list, anfs_resolve <dir> <deps_fn> (layered
               # topo sort with the same-or-lower-priority dependency rule; ANFS_RESOLVE_FIRST for
               # kinds that don't layer, ANFS_NAME_PARTS=2 for names that nest: wsm's <ws>/<space>)
packages/ppm/home/.local/lib/ppm/
  core.sh        # API for package hooks: os(), arch(), add_to_file(), remove_from_file(),
                 # debug(), user_message(), ppm_fail()
  platform.sh    # platform() (macos/debian/fedora), system_pkg_*() (apt/dnf), _system_sudo(), brew_prefix(), brew_env(), brew_owner(),
                 # brew_is_owner(), brew_require_owner(), update_brew_if_needed()
  sources.sh     # collect_repos() (the sources holding packages/), update_ppm_if_needed()
  packages.sh    # list, show, path, deps; collect_packages(), find_package_dirs() and resolve_deps()
                 # (over resolve.sh), package.yml reads, install trackers
  installer.sh   # install, remove; install_single_package(), remover(), stow_package(), PPM_IGNORE_ARGS,
                 # _install_declared_resources()/_remove_declared_resources(), _reload_stowed_libs()
  file.sh        # file claim|reset|protect|unprotect (file_command), claims.yml, protected.yml
  implode.sh     # implode: every installed package removed, dependents first, then ppm's dirs
  completion.sh  # completion
```

Rules for `lib/anfs`: it only defines functions (and paths.sh its variables), depends on no tool, takes its configuration from its own variables (`GITSRC_*`),
and runs under `set -euo pipefail`. Every tool sources it from `~/.local/lib/anfs` and nowhere
else.

**The bash floor is 5.2.** The tools and `lib/anfs` are written for it: associative arrays,
`mapfile`, namerefs. macOS ships 3.2 and always will, so `lib/anfs/bash.sh` is what makes the
floor true there, and every entry point sources it first, at top level, before anything else:

```bash
source "$HOME/.local/lib/anfs/bash.sh"
```

- Under 5.2 or newer it does nothing. Under an older bash it re-execs the script with a newer one
  found **by path** (`$HOMEBREW_PREFIX/bin/bash`, `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`,
  linuxbrew's), or exits 69 saying how to get one. Never `command -v bash`: the reason the guard
  exists is that PATH puts `/bin` first in nested login shells and non-interactive ones (see Shell
  Integration), so `env bash` finds 3.2 on a machine that has 5.
- An entry point is anything that starts its own bash process: the six tools, pcm's edge
  providers (`lib/pcm/edges/*`), pmm's provisioners (`lib/pmm/provisioners/*`), the `pre-commit`
  hook. A library a tool sources needs no guard,
  and neither does a package's `install.sh`: ppm sources it, so it runs under ppm's bash.
- `anfs` and `ppm` source it only if it exists. `lib/anfs` is stowed file by file, so a pulled
  source has the file before an install links it, and those two are what repair that.
- **The bootstrap set stays on 3.2**: `install.sh`, the four ppm libraries it sources
  (`PPM_BOOTSTRAP_LIBS`: `core.sh`, `platform.sh`, `file.sh`, `installer.sh`) and `bash.sh` itself.
  They run on a vanilla Mac before Homebrew's bash exists, so no bash 4+ syntax in them. Each says
  so in its header, and `packages/anfs/tests/bash.bats` parses them under `/bin/bash`. They may
  call functions from bash 5 libraries, as long as that only happens once the real `ppm` runs.
- Code that predates the floor (wsm, ppm's `packages.sh`, pmm's `image.sh`) still uses parallel
  arrays. Convert it when it is next changed, not for its own sake.
- **Do not run `ppm install -r core/anfs`** to pick up a new `lib/anfs` file. `-r` removes the
  package first, which unlinks `lib/anfs`, and ppm cannot run without it to put it back.

**Every tool's command line is `cli.sh`'s**: see "The Command Line" above. An extension declares
its commands where it defines them: `core/dev`'s `container.sh` calls `cli_group container` and
`cli_cmd "container up" ...` next to `cmd_container_up`.

Library sourcing in `ppm`: every `*.sh` in `$PPM_LIB_DIR` (`~/.local/lib/ppm/`) is
sourced. That directory holds both ppm's own core libraries (stowed from `core/ppm`)
and package-contributed extensions (e.g. anfs-dev/dev's `container.sh` and `vm.sh`). During a fresh
install `install.sh` sources the core libs directly from the clone and stows `core/anfs` and `core/ppm`
so they are present before `ppm` first runs.

### Testing

Unit tests are bats, no network (local bare repos over file://):

```
bats packages/anfs/tests     # lib/anfs: sources.sh, resolve.sh, bash.sh (the floor, the bootstrap set),
                             # log.sh, callbacks.sh, table.sh, cli.sh (registry.bats), anfs callbacks/log
                             # Run bats with </dev/null: pmm's ssh stub reads stdin, and a test
                             # run that inherits an open one waits on it forever
bats packages/ppm/tests      # ppm: callbacks, meta
bats packages/pcm/tests      # pcm: sources, validate, remove
bats packages/psm/tests      # psm: skills from sources, install, implode (skills CLI stubbed)
bats packages/wsm/tests      # wsm: install (stow, levels, targets, dependencies, repositories), ls/path/remove/new/add/status/implode, events
bats packages/pmm/tests      # pmm: images (sources, templates, validate, qemu argv, build, provisioners, list,
                             # what is on a build), machines (sources, profiles, validate, run/up/exec/snapshots/reset/
                             # remove, the macOS limit, media), networks and interfaces. qemu, ssh, tart
                             # and virsh are stubbed, and PMM_SOCK_DIR is the suite's own
```

End to end, on a fresh Linux box:

```
packages/anfs/tests/roundtrip [debian|fedora] [source...]
    # install.sh, ppm install stack/pi, anfs install acme (or the named sources), checks,
    # anfs implode, then $HOME diffed against its pre-install state
```

On macOS (Apple silicon), in a tart VM from `ppm vm build macos`'s vanilla base:

```
packages/anfs/tests/roundtrip-macos [--all]
    # the same sequence on a Mac with no Homebrew or CLT: install.sh installs both. Checks the CLT,
    # /opt/homebrew, a cask (acme/acme-mac), the bash floor under /bin/bash, and with --all the
    # login-shell guard (stack/bash makes Homebrew's bash the login shell; implode --all refuses)
```

pcm cannot run containers in the macOS VM: a macOS guest gets no nested virtualization, so the
podman machine cannot start (the check is that pcm reports it and implode leaves nothing).

pmm, for real (qemu, hvf/kvm; a few minutes for Debian on Apple silicon):

```
packages/pmm/tests/e2e [debian|fedora]
    # the image: validate, show (every file the build reads), build --test, a cache-hit rebuild,
    # export -c, qemu-img check; a child (image new --from, one step) built on it and run; then two
    # machines from the one build (a profile, a share, run), exec, down, up again (the disk and
    # the settings persist), snapshot/reset, reset onto the build, the build kept while a machine
    # or a snapshot is on it (image remove is refused), prune, rm, implode
```

It runs the working tree's pmm under a temp `HOME` with its own `PMM_SOCK_DIR` and the repo as
the source `core` (its images, and the catalogue their ISOs are in); only the ISO store is the
real one.

**Jobs testing at once** (anfs-dev's `anfs work`: a job is `~/work/<job>/`, worktrees on one
branch). `anfs work run <job> [repo] -- <cmd>` sets the job's variables, from its number `n`, and
runs the command in the job's directory or that repo's worktree (`anfs work run a core -- bats
packages/pmm/tests`); the tests use the variables when they are set:

| Variable | Value | Used by |
| --- | --- | --- |
| `ANFS_WORK_JOB`, `ANFS_WORK_NUMBER` | the job's name and number | the harness's box names (`anfs-test-<distro>-<n>`), the tart lock's holder |
| `ROUNDTRIP_SRC_ROOT` | `~/work/<job>` | the round trips: the job's trees |
| `PMM_SOCK_DIR` | `/tmp/pmm-work-<uid>-<n>` | pmm's helper (`<dir>/bats`) and e2e (a fresh `<dir>/e2e.*`) |
| `PMM_SSH_PORT_BASE` | `2222 + 100 × n` | pmm's helper (machine suites from it, image suites 50 above) and e2e |
| `TMPDIR` | `/tmp/anfs-work-<uid>-<n>` | every `mktemp` |

- The ISO store is shared and read-only to tests: the bats helpers use a temp one, only an e2e
  reads the real store.
- tart allows two macOS guests in all: `roundtrip-macos` takes `$ANFS_STATE_HOME/work/tart.lock`
  (exit 75 while another run holds it, naming the pid and the job).
- **No test may name `/tmp/pmm-<uid>`, point a `*_HOME` at a real home, write under the real `~`,
  or kill by pattern** (`pkill`, `killall`). `packages/anfs/tests/isolation.bats` greps every
  suite's bats files, helpers, stubs and e2e scripts for those; the round trips and the harness,
  whose `~` is a box's, are not covered. What no grep sees, a suite that never sets
  `PMM_SOCK_DIR`, pmm refuses itself: under bats (`BATS_TEST_TMPDIR` set) the live directory, set
  or defaulted, is exit 69 before any command (`sock_dir_path`, `lib/pmm/core.sh`).

- `packages/anfs/tests/harness` builds and runs the same boxes as `ppm container` (the repo's
  `containers/anfs-test-<distro>/Containerfile`) with podman alone, so changing anfs — pcm
  included — can never break the thing that tests it. `--nested` runs the box privileged with
  `/dev/fuse`, which is what rootless podman inside it needs (pcm's containers really start in
  the round trip).
- `--all` holds `$HOME` to the stricter standard of `anfs implode --all`, and `--scratch` starts
  from a bare image so install.sh installs Homebrew itself (and `--all` must remove it).
- `packages/anfs/tests/fixtures/acme` is a stand-in org source with every resource kind: a package depending on
  another source's, a container, a skill, and spaces that depend on each other.
- The round trip starts from a `bootstrap` snapshot (Homebrew, stow, yq, mise; passwordless sudo),
  built on first use, and tests a copy of the checkouts in `ROUNDTRIP_SRC_ROOT`: a job's directory
  under `anfs work run`, by default the directory the running core checkout is in. Of core and
  stack, one the root does not hold is the installed source (`roundtrip-sources`).
- Anything the diff reports is a tool writing outside its own directories, or an implode missing
  it. What implode keeps on purpose (Homebrew and its caches, mise's tools, podman's storage,
  GitHub's host keys, space contents) is listed in the script's `IGNORE_RE`.

`core/dev` provides the throwaway machines to validate them on. `ppm container` (Debian, Fedora; the
boxes are pcm services, `containers/anfs-test-<distro>`) and
`ppm vm` (macOS on Apple silicon; the boxes are pmm machines, `machines/anfs-test-<target>`, from
the image of the same name on the tart backend) share one contract: two test users, `owner` (sudo with
a password) and `other` (none), and the host's source repos mounted **read-only at `/src/<alias>`**,
so a box tests the working tree rather than the pushed repos. `ppm user` makes a throwaway user on
the host instead, which is the cheapest way to exercise the non-owner Homebrew path.

Both harnesses link the mounted sources into `~/.local/share/anfs/sources` and list them in
`~/.config/anfs/user.list` *before* `install.sh` runs, which would otherwise clone anfs from GitHub
and test the pushed repo instead of the mount.

`ppm vm` differs from `ppm container` in four places, each forced by the platform rather than by
taste (the first two live in the image, `machines/images/anfs-test-macos/provision/10-provision.sh`; the
second two in the tart backend: pmm's `tart.sh`, and its machine and snapshot code over it):

- **`/src` comes from `/etc/synthetic.conf`**, realized at boot. tart mounts shares under
  `/Volumes/My Shared Files/<name>`, and `collect_repos` splits source lines on whitespace, so a
  path with spaces is unusable; `/` is read-only, so the link cannot be made directly.
- **A snapshot recreates the box rather than restarting it.** `tart clone` of a stopped VM captures
  its state correctly, but the restarted original has been observed to come back without those
  writes. The tart backend (`_tart_shutdown`) also shuts the guest down from inside and waits, because `tart stop` can
  return while writes are still buffered and the clone then catches an older APFS checkpoint.
- **Provisioning raises sudo's `timestamp_timeout`.** `_system_sudo` primes the cache then uses
  `sudo -n`, but macOS defaults to 5 minutes with per-tty tickets and there is no tty over ssh, so
  a cold run outlives it. The password stays — the prompt is part of what is being tested.
- **ssh re-parses the remote command line** where `podman exec` passes argv straight through, so
  multi-word values travel as env vars, not positional arguments.

pmm runs under `set -euo pipefail`, so every best-effort `tart` call needs an explicit guard
(`tart delete` on a missing VM exits 2 and would otherwise kill the command mid-run). The same
option is why **a list is never piped into `grep -q`**: grep leaves at its first match, the writer
is cut short, and pipefail turns a match into a failure, now and then (`tart_exists` reads the
names into a variable first).
