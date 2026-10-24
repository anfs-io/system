# anfs — Agent Native Full Stack

## What This Is

anfs is a toolkit of bash tools that share one model of where things come from: **sources**.
A source is a git repo (or a local directory) that may hold any of:

| Top-level dir | Tool | What it holds |
| --- | --- | --- |
| `packages/` | `ppm` | software and dotfiles: files linked into place (`lib/anfs/link.sh`) plus install hooks (most of this file) |
| `containers/` | `pcm` | podman compose services (`containers/<name>/compose.yml`) |
| `machines/` | `pmm` | machines (`machines/<name>/machine.yml`), the VM images they run from (`machines/images/<name>/image.yml`) and the networks they are on (`machines/networks/<name>/network.yml`); see pmm |
| `skills/` | `psm` | agent skills (`skills/<name>/SKILL.md`) |
| `spaces/` | `wsm` | spaces (`spaces/**/space.yml`: any directory with one, at any depth; see wsm) |
| `stacks/` | `anfs` | stacks: manifests of the others, applied together (`stacks/<name>/stack.yml`; see "Stacks") |

`anfs` owns the sources (`anfs src`), its own resource the stack (`stacks/`, see "Stacks") and
the commands that span the tools: `anfs src install <source>` installs everything a source holds,
tool by tool (ppm, pcm, pmm, psm, wsm), `anfs install <stack>` what a stack declares, and `anfs
implode` is `anfs remove system` (the toolkit is the stack `core/system`) with every other stack
and every tool's `implode` around it, then deletes the sources. Picking single
resources is each tool's own `install` (`ppm install lgat/rails`, `pcm install lgat/postgres`,
`psm install lgat/skill`, `wsm install lgat/tech`; `source/` means all of that kind).

**One tool, one top-level directory** (`anfs_tool_dir <tool>` in `paths.sh`); `isos/` is anfs's,
shared. What a tool keeps below its directory is its own: pmm has `machines/images/` and
`machines/networks/` beside the machines, and `pmm install source/` does images, networks,
machines in that order itself. `anfs src list`'s `provides` therefore says `machines` for a
source with any of the three.

What the tools share lives in `lib/anfs/` and nothing else does: paths (`paths.sh`), the
source lists and clones (`sources.sh`), and finding resources plus ordering them by dependency
(`resolve.sh`). What `install` *does* stays in each tool.

## Stacks (lib/anfs/stacks.sh)

A stack is a manifest of resources to install together: `stacks/<name>/stack.yml` in a source,
resolved like any resource (`source/name`, or a bare name through the priority order). It names
no target. Use one for anything non-trivial: an install that is repeated, or that spans more than
one resource.

```yaml
version: 0.2.0
description: LGAT's rails app and what it runs on
stacks: [lgat/base]                      # installed first
packages: [stack/ruby, stack/rails]
skills: [lgat/rails-conventions]
spaces:
  - lgat/: { status: installed }         # installed|cloned
containers:
  - core/ui: { status: running }         # running|stopped
machines: []                             # running|stopped
```

- **Keys**: `version`, `description`, `stacks` and the resource directories (`packages skills
  spaces containers machines`). Anything else is 64, naming it (`show` and `install`).
- **An entry** is a string (`source/name`, what the tool's list prints, or a bare name) or a
  one-key map whose value may hold `status:` and nothing else. `status:` is checked against the
  kind: `running|stopped` for containers and machines, `installed|cloned` for spaces; other kinds
  take none (64). Absent means the tool's default after install.
- **`stacks:`** resolve recursively with ppm's layering rule (a stack depends on its own source or
  a lower-priority one); a cycle is 1, naming the chain. The order is depth-first, each stack
  once, dependencies first; then the kinds in anfs's order, not the manifest's: packages, skills,
  spaces, containers, machines. Remove is the reverse.

| Command | What |
| --- | --- |
| `anfs list` (`ls`) | `STACK STATUS VERSION`: every stack in every source (and installed ones whose definition is gone); STATUS `installed`, `partial`, `-` |
| `anfs show <stack>` | `KIND RESOURCE DECLARED ACTUAL FROM`, the stacks it depends on first, after a `<stack> <version>: <description>` line (not in `--json`) |
| `anfs install <stack>... [-y] [-t host] [--build]` | prints the plan, confirms (a stack is a group), installs kind by kind, then applies `status:` (`pcm up\|stop`, `pmm up\|stop`, `wsm repo install` for `cloned`) |
| `anfs remove <stack>... [-y] [-t host]` (`rm`) | the reverse, from the record: lists what it removes and what it keeps (and why), confirms |
| `anfs path <stack>` | the stack's directory |
| `anfs src install <source>...` | every resource of a source, tool by tool (what `anfs install <source>` was) |

**`system`** (`stacks/system/stack.yml`) is the toolkit: `core/anfs`, `ppm`, `pcm`, `psm`, `wsm`
and `podman`, `node`, `varlock`, and the dashboard `core/ui` (`status: running`: started on
install; it reaches the tools through the toolkit API). `install.sh` ends with `anfs install system -y` (then any extra
packages). pmm and qemu are not in it: `ppm install core/pmm`. `anfs implode`, in order:
every other installed stack removed (last installed first, from the records' `installed_at`), each
installed tool's implode but ppm's (wsm psm pmm pcm; a tool that is not installed is never
called), `anfs remove system` with `core/ppm` and `core/anfs` kept (`STACK_REMOVE_KEEP`), then
`ppm implode` (those two, packages installed outside a stack, ppm's dirs), then the sources and
anfs's dirs. A machine installed before stacks has no record: then `ppm implode` is what removes
the toolkit, as before. `anfs install system` once on such a machine writes the record (nothing is
reinstalled: what is there is recorded as `before`, so `anfs remove system` would keep it; implode
removes it anyway). Tests: `packages/anfs/tests/system.bats`.

- Each tool runs once per kind with every resource of that kind still missing (`ppm install -y a
  b c`, `psm install`, `wsm install`, `pcm install`, `pmm install`). A resource already there is
  not reinstalled; a `partial` spaces entry is (wsm links what is missing).
- A `spaces:` entry is a wsm spec: an id (`lgat/tech`) or a prefix (`lgat/`). A prefix is
  `installed` when it has spaces and every one is, `partial` when some are, absent when none.
- A tool not installed for a kind the stack has is 69 (`ppm install core/<tool>`), checked with
  the plan, before anything runs.
- `--build` installs only packages and skills (what belongs in an image), no `status:`; the record
  says `build: true`.
- `-t/--target` takes only `host` for now; anything else is 64 (container: and machine: are plan
  `stacks/04-boxes`).
- `anfs install <source>` with a source's name is 64: "did you mean anfs src install <source>".
- What is there is asked of each tool with `--json` ("Lists and --json"): `ppm list --installed`
  (`status` not null), `psm list` (`ok`, `partial`), `wsm list` (`ok`, `partial`; every row, for prefixes), `pcm list`
  (`status` not null nor `shadowed`), `pmm list` (`running`, `stopped`). A bare name matches any
  source's.

**The record**, `$ANFS_STATE_HOME/stacks/<source>/<name>.yml`, one per stack installed, the stacks
it depends on included (installing `b` that depends on `a` records both). It is written as the
install goes, kind by kind, so a failed install leaves a record of what it did:

```yaml
stack: lgat/rails
version: "0.2.0"
installed_at: 2026-10-19T12:00:00Z
build: false
resources:
  - { kind: packages, resource: "stack/ruby", from: "lgat/rails", before: false }
  - { kind: packages, resource: "stack/git", from: "core/system", before: true }
```

- `before: true` when the resource was there before this install and no other stack's record
  holds it (what another stack installed is anfs's, protected by that record instead).
- **The remove rule**: `anfs remove <stack>` removes a resource only if `before: false` and no
  other record holds it. A resource removed by hand since is skipped. The record is deleted at the
  end; when a tool fails it is kept, to remove again.
- Re-running `install` installs what is missing and updates the record; it never flips `before`
  from true to false.

## pcm: containers

A service is a directory, `containers/<name>/`, with a `compose.yml` (plain compose plus the
`x-pcm` block) and, beside it, its manifest `container.yml`, as a package has `package.yml`:

```yaml
version: 0.1.0                              # bumped by the pre-commit hook (anfs-dev/dev)
description: Postgres, for the services that need a database
upstream: docker.io/library/postgres:17     # what it is built from (attribution)
license: PostgreSQL
url: https://www.postgresql.org
memory: 512m                                # what it needs; also its limit
toolkit: write                              # the toolkit API (anfs rpc): read or write; absent, none
```

- Every key but `version` is optional; an unknown key is a `pcm validate` error. Nothing anfs
  needs goes into `compose.yml`: it stays plain compose (`x-pcm` aside). A service without a
  `container.yml` is still valid (version `-`), with a warning. Leave a field out rather than
  guess it.
- `pcm list` has `VERSION`; its `--json` adds `version`, `description`, `upstream`, `license`,
  `url`, `memory`, `toolkit`. `pcm show` prints, all derived: the fields, each compose service's image (or
  `built from <context>/Containerfile`), ports, data (`$PCM_VOLUMES_HOME/<name>/` and its bind
  mounts), the `.env.schema` names (`@sensitive` ones as `secrets`, never values), deps,
  ingress and privileges; so a container README keeps only what it can't derive.
- **`memory:` is the limit**: pcm's override sets it as every compose service's `mem_limit`,
  whatever compose says, and validate errors when compose sets a different `mem_limit`.
- **`pcm up` checks there is room**, adding up `memory:` (a service without one counts 0):
  on Linux what starts against the host's available memory (`free`); on macOS what runs plus
  what starts against the podman machine's memory. On macOS with too little and nothing
  running, pcm resizes the machine (stop, `set --memory`, start) to the sum plus
  `PCM_MACHINE_HEADROOM` (MiB, default 1024), and says so; with something running it refuses
  (exit 1) with the numbers, the containers a resize would stop, and `pcm machine resize <size>`.
  Nothing shrinks the machine. `pcm machine resize [size]` does it by hand: no size is what runs
  needs plus headroom; it confirms when containers run (`-y`).
- **`toolkit: read|write`** gives the service the toolkit API (`anfs rpc`, below) with that grant;
  absent, nothing. On macOS the override sets `ANFS_RPC_URL=tcp://host.containers.internal:<port>`
  (the port core/anfs wrote, `$ANFS_STATE_HOME/rpc/port`) and `ANFS_RPC_TOKEN: "${ANFS_RPC_TOKEN:-}"`:
  the grant's token is only in the environment compose runs with (`compose_run`), never in a file
  pcm writes. On Linux the grant's socket (`$XDG_RUNTIME_DIR/anfs/rpc.sock` or `rpc-write.sock`)
  is mounted at `/run/anfs/rpc.sock` and `ANFS_RPC_URL=unix:///run/anfs/rpc.sock`. `pcm show` says
  `toolkit write`, never the token; validate errors on any other value. The code is
  `lib/pcm/runtime.sh` (`toolkit_*`).
- The code is `lib/pcm/manifest.sh`.
- **The local source and a container's settings**: `~/.config/pcm/containers/<name>/`
  (`$PCM_CONTAINERS_HOME`) is the unversioned, highest-priority source, and a directory there is a
  definition only when it has a `compose.yml`. This machine's settings for a container are
  `~/.config/pcm/containers/<name>/local.env` (`pcm_local_env`, `KEY=value` lines read by
  `anfs_conf_read`, never sourced, nothing expanded), keyed by the name, so they apply to whichever
  source's definition of it runs. A directory with only `local.env` is settings, not a definition:
  it is in no list, shadows nothing and is not completed; a name resolves through the sources.
  Beside a local definition's `compose.yml` it is the same file. Precedence: the environment >
  `local.env` > the definition's `.env.schema` defaults (`export_env_overrides` exports it before
  varlock runs). `pcm show` prints `settings <file>` when it exists; `pcm validate` warns about a
  `local.env` for a name no source defines and a directory with neither file. A command that
  writes a container's setting for the person writes `local.env`; nothing does yet.
- **What pcm records for a container** is `$PCM_STATE_HOME/containers/<name>/state.env`
  (`pcm_state_env`): today the cloudflare-tunnel edge's `TUNNEL_TOKEN`, fetched on `pcm up` and
  written mode 0600 in a 0700 directory (the edge gets `PCM_STATE_HOME` from `bin/pcm`'s
  export). `export_env_overrides` reads it after `local.env`, each name only when unset:
  environment > `local.env` > `state.env` > `.env.schema` defaults. `pcm show` prints `state
  <file>` (never a value); `pcm remove` deletes the directory (the next `up` fetches it again);
  `pcm implode` deletes `$PCM_STATE_HOME`. `pcm up` writes nothing under `~/.config/pcm`.
- **One-offs** (`pcm run <service> [--] <cmd>...`, `lib/pcm/run.sh`): `podman compose run` with
  what `up` gives the service, through its own override (`<name>.run.override.yml`: labelled
  `io.pcm.oneoff=true`, no ingress labels, no network alias), named `<name>-run-<hex>`, `--rm`
  unless `--keep`, `--no-deps` (run starts the `x-pcm.depends_on` services and the compose
  service's own `depends_on` first, as `up` would; not an ingress service's proxy or edges). Code
  that means a service's own containers filters `label!=io.pcm.oneoff` (`project_containers`,
  `pcm_containers`, `_box_container`); `ps` shows one-offs, `show` names kept ones, `remove` and
  `implode` delete them. There is no `pcm run <image>`: a stock image is `podman run --rm`.
- **Logs** (`pcm logs <service> [-s NAME] [-f] [--tail N] [--since T] [-- opts]`,
  `lib/pcm/logs.sh`): `compose_run ... logs` with `compose_flags`, as `up` runs compose, so all of
  a project's compose services without `-s`; compose logs reads the containers the file defines,
  so one-offs are out unless `-s` names one (then `podman logs`). No containers is 1. The zsh
  `podman compose --pcm logs` goes through `compose_wrapper` to it. Agents use `pcm logs`.
- **Provisioning for a consumer outside pcm** (`pcm provision|deprovision <service> [--as NAME]
  [key=value...]`, `lib/pcm/provision.sh`): the hook through `hook_run` (`lib/pcm/deps.sh`), the
  one `up` and `remove` use for a dependent, with `PCM_DEPENDENT` the `--as` name (`external`).
  provision starts the service with `compose_command up` when it is not running, then
  `wait_healthy`; stdout is `hook_pairs` (the KEY=VALUE lines), `--json` an object. Values are
  never logged, only key names. deprovision never starts the service (exit 1, left in place).
- Core's own service is `containers/ui` (anfs-ui, see Repository Layout): built from its
  `Containerfile` (`build: target: dev`), the service directory mounted read-only at `/app`, its
  port on `127.0.0.1` unless its `.env.schema`'s `ANFS_UI_BIND` says otherwise; `toolkit: write`.

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
- `pmm install` (what `anfs src install` and a stack's `machines:` run) makes and starts defined machines; `pmm install
  source/` builds the source's images, installs its networks, then its machines.
  `PMM_INSTALL=create` builds and makes but starts nothing, and `PMM_INSTALL=validate` only
  validates, which is what the round trips use (no KVM in a podman box).
- **The sockets of running machines** (QMP, the guest agent) are RUNTIME, in `PMM_SOCK_DIR`, by
  default `$XDG_RUNTIME_DIR/pmm` on Linux when that is a directory, else (and on macOS)
  `/tmp/pmm-<uid>` (`sock_dir_default`, `lib/pmm/core.sh`); `implode` deletes it. Anything that
  runs pmm beside a real one (the bats helper, the e2e, `anfs work`) sets it to a directory of its
  own; under bats both defaults are refused.
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
- **`$PMM_STATE_HOME/ssh_config`** (`PMM_SSH_CONFIG`) holds a `Host` entry per running machine
  (any backend), rewritten by up and down. core/pmm links `~/.ssh/config.d/05-pmm.conf`, one
  `Include ~/.local/state/pmm/ssh_config` line, so `ssh web1` works where `~/.ssh/config`
  includes that directory (stack/ssh) and pmm never writes into `~/.ssh`. implode deletes the
  state file; `ppm remove core/pmm` unlinks the fragment. A moved `XDG_STATE_HOME` needs the
  fragment claimed and pointed there (`ppm file claim`).
- `PMM_NET_BACKEND` is `libvirt` on Linux and `none` elsewhere, where a machine with interfaces
  does not validate. The tests stub `virsh` (`tests/stubs/virsh`) and point `PMM_BRIDGE_CONF`,
  `PMM_BRIDGE_HELPER` and `PMM_SYS_NET` at a temp dir (`setup_net` in the helper).

## wsm: spaces

A **space** is any directory of a source's `spaces/` that holds a `space.yml`, at any depth. `wsm
help` documents the commands.

- **Ids are paths.** A space's id is its source and its path below `spaces/`: `spaces/space.yml`
  is the space `lgat` (the source's root space), `spaces/tech/web/space.yml` is `lgat/tech/web`.
  A directory without a `space.yml` is only a directory (`spaces/a/b/c/space.yml` alone makes one
  space, `lgat/a/b/c`); hidden directories are content like any other, and a `space.yml` in one
  makes it a space. There are no levels and no other constraint on how `spaces/` is organized.
- **A file belongs to the nearest enclosing space**: the closest directory above it with a
  `space.yml`. A child space's files are its own, not its parent's. A file under no space is not
  linked, and is warned about once per run (`not in any space, not linked: <source>/<path> (and N
  more)`).
- **Specs are ids or prefixes.** `lgat/tech` is that space only; `lgat/` or `lgat/tech/` (a
  trailing `/`) is every space at or under it. The first segment is the source when it is the
  alias of a source with `spaces/` (an alias wins over another source's top-level directory of the
  same name); otherwise the spec is a path, from the highest-priority source that has it.
  Installing a space installs its dependencies, never the spaces above it. A spec that names
  nothing fails before anything is touched.
- **`space.yml`**: `depends:` (ids, or paths resolved from the declaring source down, as ppm's
  layering rule; a bare `org` is `<this source>/org`, never a sibling) and `repositories: [{url,
  path?, ref?}]`, cloned into the space's directory (a path left out is git's name for it). A
  repository's id is `<space id>/<path>`; a path that leaves the space, lies inside a child space or
  holds one is `invalid` (warned, counted as failed), so the longest prefix of an id that is a
  space is its space (`_repo_split`). Cloned with `anfs_repo_clone` (`lib/anfs/repo.sh`; a failed
  clone or checkout of the ref leaves nothing). Install never pulls (wsm never calls
  `anfs_repo_update`: what is checked out is the user's), and never deletes a clone.
- **`space.yml`'s `links:` and `files:`** are a package's vocabulary (`lib/anfs/manifest.sh`,
  "package.yml" above), over the space's own files: `docs/` is one link, `{path, platforms}` only
  on those platforms, `{src, dest?}` a link out of the tree, `files:` copies.
  - `{src, dest?}`: `src` has `~` and `$NAME`/`${NAME}` expanded from the environment (no `eval`),
    a relative one is from the space's directory; `dest` defaults to `src`'s basename and must
    stay inside the space. Made **relative** with `anfs_link_one`; an absolute link that resolves
    to `src` (one made before) reads `ok` and is not rewritten. States (`anfs_link_src_state`):
    `ok`, `missing`, `missing src` (said at install, not made, not a failure, not counted),
    `wrong` (a link elsewhere), `in the way`, `invalid` (an entry wrong on its own: an unset
    variable, a `dest` that leaves the space, a link to `/`; warned and skipped, the rest of the
    space installed, `wsm install` exits 1; not counted in `wsm ls`'s NOTE, in `--json`'s
    `links`). Install makes them after the clones; `wrong` and `in
    the way` fail the entry, `-f` moves them aside as for files. `remove` deletes one only while it
    still resolves to `src`. They overlap with ovm's vault links into a space; a dest and an ovm
    link at one path meet as `in the way` on whichever comes second.
  - `files:` are copied when missing (after the links, before the clones), never touched again,
    left by `remove`. A missing or in-the-way copy counts in `wsm ls` (`partial`); one that
    differs does not. `wsm ls <id> --json` adds `copies: [{path, status}]`.
  - A refused manifest (every refusal of a package's, plus wsm's own:
    a directory link that holds, is or lies in a child space or a repository; a directory link
    at a hidden directory when the space declares `skills:`, where the CLI writes; `space.yml` in
    `files:` or a path entry) makes the space `invalid` in `wsm ls` (its first error the NOTE) and
    `wsm install` fails it with every error, nothing linked.
  - The leftover walk never enters a directory link (a mirror that is a link is skipped).
- **`space.yml`'s `skills:`** (`[{repo, skills?}]`): agent skills installed into the space's
  directory by the skills CLI (`lib/anfs/skill.sh` with the space's directory as the scope, `npx
  skills` without `-g`). `repo` is what the CLI takes (`owner/repo`, a URL, a path); a relative
  path is from the `space.yml`'s directory in the source, resolved with `cd -P`. `skills` left out
  is every skill: a path's by name (each gets a real status), a remote's as `*`. The agents are the
  detected ones (ppm packages with `meta.agent`). **Only the declaring space**: a child space's
  directory is never a scope for its parent's skills (Claude Code itself loads `.claude/skills`
  from parent directories up to the repository root: `packages/psm/AGENTS.md`).
  - Install ends with them (after files, clones, `links:`): a path's skills are copied again every
    run (they are the space's own, edits arrive that way), a remote's when missing for an agent.
    No agent yet is `waiting`; no npx is one warning. Neither fails. A space with no `skills:`
    never runs npx.
  - `wsm skill install [SPEC] [-n]` is that half alone; `wsm skill ls [SPEC]` (`SKILL STATUS
    REPO`) runs one `skills list` per installed space that declares any; `wsm skill rm SPEC...`
    takes a space's declared skills from it, or one (`<space id>/<name>`), asking first.
  - `remove` and `implode` take a space's skills first. **Never an unscoped `skills remove` in a
    space**: in a project it sweeps every agent's directory, `skills/<name>` and
    `data/skills/<name>` included (a space's own files, or the user's). wsm removes with `-a` for
    the agents the skill is on, then deletes what the CLI keeps for universal agents: the copy in
    `.agents/skills/<name>` and its `skills-lock.json` entry. A skill the space does not declare (a
    `npx skills add` by hand, a `*` repo's that the lock does not trace to it) is never removed.
  - What the CLI writes is wsm's to step around: `wsm add` skips (refuses when named)
    `skills-lock.json` and the files of the skills that lock names under `.agents/skills/<name>/`
    and `<.agent dir>[/<sub>]/skills/<name>/`, read with yq, no npx. Then `remove` deletes a
    `skills-lock.json` whose `skills` is empty and the empty skill directories (`rmdir` only).
  - Agents come and go: `wsm_ppm_changed` (wsm's `install.sh`, registered with ppm like psm's) runs
    `wsm skill install` when a package in an install run declares `meta.agent`, and on a remove
    unlinks each removed id no installed package still declares from every installed space's
    declared skills (`wsm __agents_rm <id>...`, plumbing). wsm's own: it needs neither psm nor psm
    it.
  - `wsm list` never runs the CLI: skills are not in its STATUS.
  - Every links:/skills: function acts only in a space's directory that is set, below the root and
    a real directory (`_home_ok`), and `anfs_skill_cli` refuses a scope that is not an existing
    absolute directory (`cd ""` would leave the CLI in the cwd).
- **`wsm install [SPEC...] [-n] [-f] [-y]` links, as ppm does** (`lib/anfs/link.sh`): each space's
  files into `$WSM_SPACES_HOME/<source>/<path>/`, one relative link per file (a directory link one
  link), so directories stay real and a clone never lands in the source. Every file is linked but `.DS_Store`, `README.*`
  and `.gitignore` included. Then its leftovers go, then its repositories are cloned. Several specs
  in one run (`anfs src install a b` passes every source to one `wsm install`); a prefix asks.
  With no SPEC, the space at `.`, which must hold a `space.yml`.
  - Anything in the way (the plan's `other` and `conflict`) fails the space before anything is
    linked, every file named. A link into the source's `spaces/` (moved, renamed, absolute,
    dangling) is the plan's `replace`. **`-f` moves what is in the way aside**, as ppm does: to
    `$WSM_STATE_HOME/backup/<source>/<path>` (`.1`, `.2` when taken). Nothing restores it, not
    `remove` (there is no record). An obstacle on the way (a file where a directory goes) is never
    moved.
- **One root**: `WSM_SPACES_HOME` (`wsm.env`, default `~/spaces`, `~` and `$HOME` expanded). A
  source's spaces are always under `<root>/<source>/`; there is no DIR argument. A root inside a
  source checkout is refused.
- **Nothing is recorded.** The sources' `spaces/` say what exists (one `find` per source per run,
  `_spaces_load`); the links say what is installed. `$WSM_STATE_HOME` holds only `backup/`.
  - A space is **installed** when `<root>/<source>/<path>/space.yml` is a link to its
    `space.yml`. Each file's state is `anfs_link_check`'s: `ok`, `missing`, `wrong`, `in the way`,
    one check (one `readlink` for every link) per source.
  - A **leftover** is a dangling link into the source's `spaces/` that no file of the source owns.
    The walk (`_leftovers_scan`) lists only the directories of `<root>/<source>/` that mirror a
    directory of the source's `spaces/` (bash globs, no `find`), and for an entry that is a real
    directory and no mirror, only `<entry>/space.yml`: the one level that notices a vanished space.
    So a clone of any size costs one directory entry. **The limit is kept on purpose**: a space
    that vanished two or more levels below the nearest mirrored directory, and the links under a
    directory the source no longer has, are not seen. A leftover counts against the nearest
    installed space above it; a dangling `space.yml` where the source has no space is a `not in the
    source` row.
  - The old `~/.local/state/wsm/installed/` trackers are neither read nor deleted.
- **`wsm ls [SPEC]`**: `SPACE STATUS DIR NOTE`. STATUS is null (not installed), `ok`, `partial`
  (NOTE counts `missing`, `wrong`, `in the way`, `leftover`; `links:` and `files:` count in the
  first three), `invalid` (its manifest is refused; NOTE is the first error) or `not in the
  source`. `wsm ls <id> --json` adds `files: [{file, status}]` (the check's states
  plus `leftover`, relative to the space) and `links: [{dest, src, status}]`. The installed
  spaces' `links:` are read with one yq per run. `copies` (`[{path, status}]`) is the space's
  `files:`. `wsm status` is gone; drift across the machine is `anfs status` (linker plan 03).
- **wsm acts only on what it derives from the source**: the spaces' files (links), their
  leftovers, the repository paths, `links:` dests, `files:` copies (made when missing, never
  changed or removed after), the skill directories and lock the skills CLI writes for declared
  skills, and `space.yml`. The user's files, their links and other tools' (ovm's links into
  vaults) are never listed, changed or removed.
- **A space's id** (`id:` in `space.yml`, "Events" below): `wsm new` writes one, `wsm id [SPEC]`
  prints it (no SPEC: the space around `.`; a prefix: `SPACE ID` rows), `wsm id --new SPEC`
  writes one into each space that has none and never changes one (`SPACE STATUS ID`; `commit it
  in <source>`), before the first line that is not a comment. `wsm ls` says `no id`, `invalid id`
  or `duplicate id (also <space>)` in NOTE, after the counts, and leaves STATUS alone. `wsm events
  ls [SPEC...]` is the event log of the space around `.` or of the spaces SPEC names.
- **`space.yml`'s `access:`, `agents:`, `dispatch:` and `dispatcher:`** are anfsd's ("Dispatch"
  below): what the space's dispatched agents may reach beyond their job, the roles it runs, which
  event starts which, and whether anfsd dispatches the space at all (`dispatcher: anfsd`, the
  default, or `none`, for a space another tool dispatches). wsm links the file (and a rule's `prompt_file:`, as any file) and neither reads nor checks
  them: `anfs agents rules` does, through anfsd.
- **The tree mirrors the source, both ways.**
  - `wsm new [SOURCE/]PATH` creates a space in the source: a qualified id anywhere, a bare path
    below where you are (in the tree, or below a checkout's `spaces/`). It is installed when the
    nearest space around it is; a space made inside one takes the files below it, whose links are
    already right.
  - `wsm add` moves files from the tree into the source and links them back, relative
    (`anfs_link_one`), so the next install's plan keeps them. The file's space (its nearest) must be
    installed. It never takes clones, repository paths, what the source's `.gitignore` ignores, or
    a file under no space; a copy where the source has the file goes back only when named.
  - `wsm repo ls [SPEC]` is the repositories' git state (`anfs_repo_status`), `wsm repo install
    [SPEC|REPOSITORY]` clones what an installed space declares and is missing (install's clone
    half), and `wsm repo ssh [SPEC]` switches each clone's GitHub https origin to ssh, as `anfs src
    ssh` (`<id>: origin -> git@...`); `space.yml` is the source's and is not edited, an https URL
    in it is noted (`<id>: https in space.yml`). `wsm repo push [SPEC|REPOSITORY...|--all] [-n]` is
    `anfs src push` over the repositories (the same helper, below); an argument is an exact
    repository name, else a spec resolved as `repo ls` does (`_spec_parse`/`_spec_match`), expanded
    in list order to its clones with an upstream (pushed when ahead, `up to date` when not),
    deduplicated. A bare id whose space has none but whose children do: `did you mean <id>/?`, 1. The group follows `anfs src`
    where it is cheap: no `update` (space repositories are never pulled), no `add`/`remove` (a
    repository is declared in the source's `space.yml`).
  - `wsm path`/`cd [-s] [QUERY]`: an installed id, else the installed ids that end in `/QUERY`
    (`web`, `tech/web`; several: exit 2), else a source names `<root>/<source>`; no QUERY, the
    deepest installed space around `.`. `path`, `cd`, `new`, `add` and `repo` read only the
    `space.yml` links, never the full check. `-s` gives the directory in the source.
  - wsm commits only in `wsm move` ("Moving a resource between sources").
- `remove` takes, per space: its files' links that are still `ok`, its leftovers, then
  `space.yml` last (an interrupted remove leaves it `partial`), then the directories that leaves
  empty up to `<root>/<source>`; clones, the user's files and a child space's links keep a
  directory alive. A `not in the source` space is removed by walking its directory for dangling
  links into the source (not into clones or live spaces). `implode` does that for every space,
  then deletes `$WSM_STATE_HOME`, backups included.
- Names nest to any depth in `resolve.sh` (`ANFS_NAME_NEST`, `ANFS_RESOLVE_MARKER=space.yml`);
  spaces don't layer (`ANFS_RESOLVE_FIRST`).

## The toolkit API (anfs rpc)

`anfs rpc [--grant read|write]` is the toolkit as an API, for a program (anfs-ui) rather than a
person: a JSON request per line on stdin, a JSON answer per line on stdout, until EOF. bash and
yq only. A socket-activated listener puts it in reach of containers (below); the grant comes from
the caller's `container.yml` (`toolkit: read|write`, pcm above).

| Request | Answer |
| --- | --- |
| `{"run":["ppm","list"]}` | `{"exit":0,"data":<the --json output, parsed>}`, or `{"exit":0,"out":"..."}` for text |
| `{"run":[...],"stream":true}` | `{"out":"<line>"}` per line of stdout and stderr, then `{"exit":N}` |
| `{"run":[...],"yes":true}` | the same with `-y` (before a `--`, else last) |
| `{"version":true}` | `{"anfs":"0.2.9","tools":{"ppm":"0.2.5",...}}`, the installed tools |
| anything else | `{"error":"..."}`; the next line is still read |

- **Only the toolkit's tools**: `run[0]` is `anfs` or one of `ANFS_TOOLS`, run from
  `$ANFS_BIN_DIR` (never `PATH`); the rest is an argv, never a shell string or `eval`. Refused:
  `anfs rpc`, any tool's `implode`.
- **The grant**: a read is a tool's `list|ls`, `show`, `status`, `path`, `validate`, `--version`,
  `version` (in a group too, `pmm image list`; through anfs, `anfs package list`), `logs` without
  `-f` (`anfs bus logs`), plus `version`. Everything else is a write, refused under `--grant read` (the default).
- **Each run**: stdin `/dev/null`, `ANFS_RPC=1`, a timeout of `ANFS_RPC_TIMEOUT` seconds (60;
  `{"exit":124,...}`; a stream has none). A read gets `--json` and `ANFS_LOG=off` (a poll is not
  an event). A failure is `{"exit":N,"error":"<last stderr line>"}`.
- **77, needs a terminal**: a confirm without `yes`, or sudo that cannot run unattended (under
  `ANFS_RPC` there is never a terminal), answers
  `{"exit":77,"needs":"terminal","command":[...],"error":"..."}`, for a UI to say "run this in a
  terminal".

### The listener (lib/anfs/listener.sh)

Nothing runs between connections: each connection starts one `anfs rpc` with the connection as
its stdin and stdout. core/anfs's `post_install` writes and loads it, `post_remove` unloads and
deletes it, and `anfs implode` does that first, before anything else, and deletes the tokens.
The unit files are written (absolute paths and the install's `PATH`, which launchd cannot
expand), not stowed.

| | macOS | Linux |
| --- | --- | --- |
| Unit | `~/Library/LaunchAgents/io.anfs.rpc.plist`: `Sockets`, `inetdCompatibility` `Wait` false | `~/.config/systemd/user/anfs-rpc{,-write}.socket` (`Accept=yes`) and `anfs-rpc{,-write}@.service` |
| Listens on | TCP `127.0.0.1:$ANFS_RPC_PORT` (47100), one port | `$XDG_RUNTIME_DIR/anfs/rpc.sock` (read), `rpc-write.sock` (write), mode 0600 |
| Runs | `anfs rpc --token` | `anfs rpc --grant read` / `--grant write` |
| Who may call | whoever has a token | the user (file permissions) |

- **The token (macOS)**: loopback is open to every local process, a container included (it sees
  `127.0.0.1`). `$ANFS_STATE_HOME/rpc/token.read` and `token.write`, 64 hex, 0600 in a 0700 dir,
  made once (a reinstall keeps them; `ppm remove core/anfs` keeps them too, implode deletes
  them). Under `--token` the first line must be `{"token":"..."}` (that key only); the token that
  matches is the grant, whatever `--grant` says; anything else answers
  `{"error":"unauthorized: ..."}` and closes (exit 1). Without `--token` (a unix socket, a pipe)
  a first token line is read and ignored, so a client sends it either way.
- `$ANFS_STATE_HOME/rpc/port` is the port the agent was written with (pcm reads it); the agent's
  stderr goes to `$ANFS_STATE_HOME/rpc/rpc.err`.
- Loading never fails an install: no GUI session (`launchctl bootstrap gui/<uid>`) or no systemd
  user manager is a warning; launchd loads the agent at the next login, and on Linux
  `systemctl --user enable --now anfs-rpc.socket anfs-rpc-write.socket` does it by hand. Unloading is done only when
  this `$HOME`'s unit file exists (the launchd label is per user, not per `$HOME`).
- Try it: `printf '{"token":"%s"}\n{"run":["ppm","list"]}\n' "$(cat ~/.local/state/anfs/rpc/token.read)" | nc 127.0.0.1 47100`
  (Linux: `... | nc -U $XDG_RUNTIME_DIR/anfs/rpc.sock`). Tests stub `launchctl` and `systemctl`
  (`ANFS_RPC_OS` picks the platform): never the real ones.

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
  settings (`~/.config/anfs/{system.list,anfs.env}`). It depends on what the `anfs` command runs
  and nothing else (`ppm`); the whole toolkit is the stack `core/system` (`stacks/system/`). Its `tests/` hold the shared-lib bats
  suites (Testing; the round trips are anfs-dev's).
- `packages/ppm/` — ppm itself: the `ppm` command, its libraries (`~/.local/lib/ppm`) and its shell
  integration (`~/.config/{sh,zsh,bash}/{ppm,mise}.*`)
- `packages/{pcm,pmm,psm,wsm}` — the other tools, each its own package (deps, hooks, tests)
- `packages/{podman,varlock,node}` — the software the tools run on, part of the base install;
  `packages/qemu` is pmm's, installed with it
- `packages/{nats,anfsd}` — the bus: NATS with JetStream (pinned binaries) and anfsd (anfs-io/runtime's
  daemon, pinned or built from source), each a service of the user's, and `anfs bus` (core/anfsd).
  Not part of the base install yet ("The bus")
- `stacks/system/` — the toolkit as a stack: `core/anfs`, `core/ppm`, `core/pcm`, `core/psm`,
  `core/wsm` and `podman`, `node`, `varlock`, and `core/ui` running. Not pmm or qemu
  (`ppm install core/pmm`)
- `packages/pmm-network` — the root-owned host setup pmm's networks need (Linux); not part of the
  base install
- dev/test tooling (`anfs work`, `anfs hooks` and the git hooks, `ppm container`, `ppm vm`, `ppm
  user`), the round trips and the test boxes are the anfs-dev source's
  (`anfs-io/dev-anfs`), not here
- `skills/` — the tools' own skills (`pcm-containers`, `pmm-images`), synced by psm like any source's
- `isos/isos.yml` — the ISOs the base images install from: the catalogue entries their `image.yml`
  names by id, each with a pinned sha256 (`pmm iso pull`)
- `machines/images/` — the base VM images (`debian-13`, `fedora-44`), each with its answer file,
  steps, test and README; other sources build on them with `from:`. Core has no machine
  definitions: the test boxes are anfs-dev's
- `containers/ui/` — anfs-ui, the toolkit's dashboard (Roda, Phlex, Puma), a pcm service in the
  `system` stack. Its `Containerfile` has a `dev` target (Ruby and the gems; compose mounts the
  directory read-only at `/app` and `views/` reload) and a `release` one (the source copied in).
  Its own suite: `cd containers/ui && bundle exec rspec && bundle exec rubocop`. In a container it
  reaches the tools through the toolkit API (`lib/anfs/rpc.rb`, `ANFS_RPC_URL`/`ANFS_RPC_TOKEN`:
  lists, commands streamed with `yes`); without `ANFS_RPC_URL` it runs them from `ANFS_BIN` (on
  the host). It hears what changes from the bus, as NATS's `reader` (`lib/anfs/bus.rb`, the durable
  consumer `ui` on `ANFS`; the password a read-only mount of `users/reader`, the address
  `ANFS_UI_BUS_URL`), updates only the kind an event names (container.* from the event's data;
  `source.updated` and `podman.*` with one list of that kind; the 2 s guard on both), and lists
  every kind again every 5 minutes. The bus is required: unreachable, it says so on the page and
  retries (1, 2, 5, 10, 30, then 60 s). `/events` shows the latest events
- `install.sh` — bootstrap installer for new machines (installs the irreducible prereqs —
  Homebrew, yq, mise — clones this repo, links the base packages `core/anfs` and `core/ppm`,
  installs the login shell's package from stack (`stack/bash` or `stack/zsh`: only a shell
  package's rc file runs `brew shellenv`, so without one `brew` is "not found" in a new shell;
  `--no-shell` skips it, and a shell with no package gets a hint, never a failure), then
  `anfs install system -y`, then any extra packages)
- Plans and design docs are not here: they are in [anfs-io/docs](https://github.com/anfs-io/docs)

The tools don't declare `depends: [anfs]` although they source `lib/anfs`: anfs depends on them,
and like yq it is base software that is always present.

Every tool, anfs included, keeps to `<dir>/<tool>`: `~/.local/bin/<tool>`, `~/.local/lib/<tool>/`,
and `$XDG_{CONFIG,DATA,STATE,CACHE}_HOME/<tool>/` for its own files, each kind in its own
directory ("Where files go", next). Nothing is namespaced under anfs except anfs's own (the
sources, the lists, `anfs.env`). A tool's settings are `~/.config/<tool>/<tool>.env`
(Configuration).

## Where files go (the XDG rule)

What a file is decides where it goes. A tool writes into a config directory only what the
person declared.

| Kind | Holds | Where | Examples |
| --- | --- | --- | --- |
| CONFIG | what the person declares: by hand, or by an explicit `set`/`add` command; **never** as a side effect of another command or an install. Also what a package links there (a declaration in a repo) and the local definition directories | `$XDG_CONFIG_HOME/<tool>` (`<TOOL>_CONFIG_HOME`) | `<tool>.env` (linked), `<tool>.local.env` (`config set`), `user.list` (`anfs src add`), `isos.yml` (`iso add`), pcm's `containers/` and pmm's `machines/` (the `local` source, like Quadlet's `~/.config/containers/systemd`) |
| STATE | what a tool records about what it did | `$XDG_STATE_HOME/<tool>` | trackers, stack records, backups, a machine's run (`run/<name>/`, its pid with it), pmm's `ssh_config`, pcm's `containers/<name>/state.env` (a fetched tunnel token), the event log and the reports' records (`anfs/events/`, `anfs/reports/`), anfsd's runs (`anfsd/runs/<run id>/`) |
| DATA | content a tool manages | `$XDG_DATA_HOME/<tool>` | sources, volumes, disks, builds, keys, ruby's `default-gems` (a list packages add to) |
| CACHE | what can be rebuilt | `$XDG_CACHE_HOME/<tool>` | compose overrides, ISOs, update stamps |
| RUNTIME | sockets and temp files that die with the session | Linux: `$XDG_RUNTIME_DIR`; macOS: `/tmp` (socket paths are short) or `$TMPDIR`; always overridable for tests | pmm's sockets (`PMM_SOCK_DIR`, default `$XDG_RUNTIME_DIR/pmm` on Linux, `/tmp/pmm-<uid>` on macOS), anfs's RPC sockets (systemd's `%t`), ppm's message file (`$TMPDIR`) |

- **A side effect never writes CONFIG.** An install hook makes no empty directory, seeds no
  template and writes no default there; a command that runs (`up`, `install`) records what it
  learned in STATE. A file another command needs is made by the command that writes it
  (`anfs src add` makes `user.list`, `pmm image new` makes `machines/images/`), and every reader
  takes a missing one as empty.
- **Secrets a tool fetches are STATE** (mode 0600 in a 0700 directory), read below the person's
  own file: pcm reads a container's `local.env`, then `state.env`.
- **A config file someone else dictates is not written as it runs.** Where the location is fixed
  (`~/.ssh/config.d/`), the package links a static file that includes the tool's STATE
  (core/pmm's `05-pmm.conf`: `Include ~/.local/state/pmm/ssh_config`).
- **Accepted exceptions**, each with its reason:
  - platform locations the OS or another program dictates: the RPC listener's launchd plist and
    systemd user units (core/anfs), the bus's (core/nats's `io.anfs.nats` / `anfs-nats.service`,
    core/anfsd's `io.anfs.anfsd` / `anfsd.service`: lib/anfs/service.sh), podman's machine (`pcm
    up` on macOS);
  - stack/ssh's one `Include config.d/*.conf` line appended to `~/.ssh/config` (it is what makes
    `config.d/` work; idempotent), and stack/gam's `gam.cfg` (GAM fixes the place): future
    `setup:` steps;
  - stack/firstmate's trust entry in Claude Code's `~/.claude.json` (that tool's file, mostly its
    state; its README says so);
  - pmm's pid files stay with the record of the run they belong to (`$PMM_STATE_HOME/run/<name>/`),
    guarded by `pid_alive`: moving them would split one record across two places;
  - anfs-dev's git hooks under `~/.config/git/ppm-hooks` (in docs' BACKLOG).
- **How it is held**: a new write into a config directory in review is held to this table. The
  audit of every write (2026-10-22) is `units/config/05-xdg-rule/log.md` in anfs-io/docs; the
  tests are `packages/anfs/tests/xdg.bats` (core's hooks), `pcm-local-env.bats` (the token),
  `pmm-runtime.bats` (sockets, ssh) and `isolation.bats` (no suite names either live socket
  directory).

## Configuration: `<tool>.env`

Each tool owns its settings, beside its other config (`lib/anfs/paths.sh`, "Settings"):

- **`~/.config/<tool>/<tool>.env`**, shipped by the tool's package and linked like any file: every
  setting the tool reads, each a comment saying what it does and then `#NAME=default` (the
  documented built-in default), or `NAME=value` where the package sets one
  (`ANFS_UPDATE_CACHE_DURATION`, Homebrew's two, `PPM_BREW_UPDATE_CACHE_DURATION`).
  `packages/anfs/tests/settings.bats` holds each core tool to it: a `${<TOOL>_X:-…}` the code reads
  with a default has its line, a line names something the code reads.
- **`~/.config/<tool>/<tool>.local.env`** beside it: this machine's values. The person's file:
  nothing writes it as a side effect (install.sh seeds no settings file); `<tool> config set` is
  the one command that does.
- **anfs's own** are `~/.config/anfs/anfs.env` and `anfs.local.env`: `ANFS_*` (what more than one
  tool shares: the sources' TTL, `ANFS_SKILLS_CLI_VERSION` for psm and wsm, the API's port) and
  Homebrew's `HOMEBREW_NO_AUTO_UPDATE`, `HOMEBREW_NO_ENV_HINTS`, which every tool runs brew with.
- **Precedence**: the environment, then `<tool>.local.env`, then `<tool>.env`, then the code's
  default. A variable already set is never overwritten, so `PCM_HEALTH_TIMEOUT=300 pcm up x` does
  what it says.
- **Who loads what**: sourcing `paths.sh` loads anfs's (every tool); `anfs_tool_paths <tool>` loads
  the tool's. Nothing else: a tool not installed contributes nothing, and pcm's settings never
  reach ppm. **A package hook that needs its tool's setting calls `anfs_load_conf <tool>` itself**
  (hooks run inside ppm: stack/tailscale's `TSM_AUTOJOIN`). The values are exported, so what a
  tool runs (pcm's edges, pmm's provisioners) sees them.
- **Format**: `NAME=value` lines, read and never sourced: a setting can't run code or clobber a
  variable a tool set itself. Blanks and `#` comments skipped, a leading `export ` allowed, one
  pair of matching quotes stripped. **One expansion**: a value that is exactly `~`, or starts with
  `~/`, has that `~` replaced by `$HOME` when loaded (`anfs_conf_expand`); nothing else (no
  `$VAR`, no `~user`, no globbing, no `~` past the start), so `REMOTEFS_MOUNT_HOME=~/mnt` works
  and `$HOME/mnt` does not. `anfs_conf_read` returns values as written.
- **Environment-only** (`anfs_conf_env_only`): every `*_{CONFIG,DATA,STATE,CACHE}_HOME` (they
  locate the files: `PCM_CONFIG_HOME` pointed at a temp dir moves pcm's two files there),
  `ANFS_WORK`, `ANFS_WORK_HOME`, `ANFS_WORK_TMP`. A line naming one is ignored with a warning
  (`anfs: <file>: <NAME> is read from the environment only`).
- Names: a tool's settings carry its prefix (`PCM_`, `OPM_`); `ANFS_` is for what tools share.
  Paths that locate a tree (`PCM_CONTAINERS_HOME`), test hooks and internal switches (`*_IN_FNOX`,
  `*_BASH_REEXEC`, `*_LIB`, `*_BIN`) are not settings and are not listed.
- The API, for code that reads or writes the files (`lib/anfs/config.sh`, pcm's per-container
  settings): `anfs_conf_files <tool>` (the two paths, local first), `anfs_conf_read <file>`
  (`NAME<TAB>value` per line as written, nothing exported), `anfs_conf_expand <value>` (what the
  loader exports, into `REPLY`), `anfs_conf_env_only <name>`, `anfs_load_conf [tool]`, and
  `ANFS_CONF_LOADED` (the names the loader exported in this process; not exported).
- A layer (`user/anfs`) may ship its own `anfs.env`, which replaces core's whole; a machine's
  values belong in `anfs.local.env`. The one file for every tool's settings is gone: nothing
  reads a settings file but the two of anfs's and the two of the running tool's.

**`<tool> config`** (`lib/anfs/config.sh`): every tool that ships a `<tool>.env` has the group,
scoped to its own settings, so `pcm config set PCM_HEALTH_TIMEOUT=300` (or `anfs container config
set ...`, through the seam) writes `~/.config/pcm/pcm.local.env`.

| Command | Does |
| --- | --- |
| `<tool> config list` | `NAME VALUE FROM`: every setting the tool declares, its effective value (a file's `~` expanded) and where it is from |
| `<tool> config list --export` | `export NAME='value'` per setting, for `eval "$(pcm config list --export)"`; what is from `env` (and an empty default) left out |
| `<tool> config get NAME` | the value `list` shows; exit 1, nothing printed, when it has none (an empty default) |
| `<tool> config set NAME=VALUE...` | into `<tool>.local.env`: the line replaced in place or appended, the file created with a header line; a value that is not plain is single-quoted; atomic (a temp file beside it, then `mv`; through a link, its target). A warning when the environment sets the name too (it wins) |
| `<tool> config unset NAME...` | the name's lines out of `<tool>.local.env` (never the shipped file); not there: a note, exit 0 |
| `anfs config list --all` | anfs's, then every installed tool's (each `$XDG_CONFIG_HOME/<d>/<d>.env`, and a tool whose `<TOOL>_CONFIG_HOME` the environment sets), with a leading `TOOL`; read in anfs's process, nothing of the other tool runs |

- **FROM**, the first that applies: `env` (exported by the environment the tool started in, not by
  the loader: a tool run by another inherits the parent's settings, and they are `env` there),
  `local` (a line in `<tool>.local.env`), `shipped` (an active line in `<tool>.env`), `default`
  (the commented `#NAME=value`: the documented built-in default). FROM is not a state (rule 5 of
  "Lists and --json").
- **Declared names only**: a tool's settings are the names its shipped file has a line for, active
  or commented (`#NAME=`, no space after the `#`; a prose comment is not one). `get` and `set`
  refuse anything else (64, `pcm config: PMM_INSTALL is not a pcm setting (pcm config list)`);
  there is no owner lookup by prefix. A name only in the local file is listed (FROM `local`) so a
  stray line is seen, and `unset` takes it away.
- `set` refuses (64) a malformed name, `ANFS_WORK` and the environment-only `*_HOME` names, and a
  value with a single quote (the reader strips one pair of quotes and has no escapes) or a newline.
- `anfs config list` also has `ANFS_WORK` when it is set (FROM `env`; never in a file).
- `config` is not in the toolkit API's `RPC_GROUPS`: through `anfs rpc` it is a write, refused
  under `--grant read`.

## Package Structure

Each package is a directory under `<repo>/packages/<n>/`, and every one has a `package.yml`
(the pre-commit hook refuses a commit that would leave one without):

```
packages/<n>/
  package.yml     # required: version, author, depends, categories...
  install.sh      # optional: pre/post_install hooks, OS-specific install
  home/           # optional: linked into $HOME (the only directory of a package that is)
```

A package that ships a tool with settings ships `home/.config/<tool>/<tool>.env` documenting every
one of them (Configuration).

A `macos/` or `linux/` beside `home/` is not linked and not warned about: what is per platform is
said in `package.yml` (`links:`, below). `PPM_GROUP_ID` is gone.

### package.yml

```yaml
version: 0.1.0
author: rjayroach
depends:
  - ruby
  - node
```

- `version` — semver; the patch level is auto-bumped by ppm's git hook (anfs-dev's AGENTS.md, "Git Hooks")
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

**How the files are placed: `links:`, `files:`, `platforms:`** (`lib/anfs/manifest.sh`; the same
vocabulary in a space's `space.yml`, see wsm). Everything under `home/` is linked file by file,
relative, unless an entry says otherwise:

```yaml
platforms: [macos]                 # the whole package (unchanged)
links:
  - .local/lib/anfs/               # a directory (a trailing /), as one link
  - {path: .ssh/config.d/99-op.conf, platforms: [macos]}     # only on those platforms
  - {path: .config/mise/conf.d/op.toml, platforms: [linux]}
  - {src: ~/Library/Mobile Documents/x/apex, dest: vaults/apex, platforms: [macos]}  # out of the tree
files:
  - .config/foo/defaults.conf      # copied when missing, never again: then it is yours
  - {path: .config/foo/local.conf, platforms: [debian]}
```

| Entry | Means |
| --- | --- |
| `<dir>/` | the directory as **one link** at the same path: a file added upstream is there after a pull, no reinstall |
| `{path, platforms}` | only on those platforms: a file; a directory without `/` per file; with `/` one link |
| `{src, dest?, platforms?}` | a link at `dest` (default: `src`'s basename) to `src`, relative; `~` and `$NAME`/`${NAME}` expanded (no eval); `src` must be absolute here (a space's may be relative); `missing src` is said, not made. An entry wrong on its own (an unset variable, a relative `src`, a `dest` outside `$HOME`, a link to `/`) is `invalid`: said (`ppm_fail`, `-n` and `ppm show` list it), skipped, the rest of the package installed |
| `files:` `<path>` or `{path, platforms}` | copied (mode kept) when nothing is there, never again; `-n` says `differs` when yours changed; remove leaves it |

- `platforms:` is `macos`, `linux` (any distro), `debian`, `fedora`, matched as the package's own.
  What another platform's entry leaves out is `off` in `ppm install -n`.
- **Refused** (the package is not installed, every error said; the rest of the run goes on): a
  `links:` string without a trailing `/` or a `{path}` without platforms (they say nothing the
  default does not), a path not in `home/`, absolute or with `..`, a trailing `/` on a file, a
  `files:` directory, a directory link inside another, **a platform entry or a `files:` entry
  inside a directory link** (it brings the whole directory), the same path twice, an unknown
  platform or `platforms: []`, a map with both `path` and `src` (or neither, or another key).
  (A `src:` entry wrong on its own is only `invalid`, above.) Checked wherever the manifest is read: `ppm install`
  (and `-n`), `ppm show`.
- **One plan** over the links, the copies and the links out of the tree before anything changes:
  everything in the way is in the one `WARNING! ... would cause conflicts` block. `-f` moves it
  aside (`_backup_file`; a whole directory where a directory link goes, when it holds only this
  package's links); a copy that `differs` is never touched; nothing on the way (a file where a
  directory goes, a link out of `$HOME`, a path through another package's directory link, a
  directory holding another package's links) is ever cleared.
- The tracker's `files` are the links made, a directory link as one path; `links:` holds the links
  out of the tree (`{dest, src}`); copies are not recorded. All three join `PPM_SKIP_FILE`.
- Each tool says which entry kinds it takes (`ANFS_MF_KINDS`); ppm and wsm take all of them.

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
- Mise tools: link `home/.config/mise/conf.d/<tool>.toml`; after linking, ppm runs `mise install` for the tools named in the toml files the run's layers actually linked (`PPM_MISE_TOMLS`): a toml another platform's entry leaves out (stack/op's Linux-only `op.toml` on macOS) or that a higher layer replaced is not read. mise itself is a **core ppm component** — `install.sh` brews it alongside yq, and `core/anfs` ships its shell activation — so packages declare the *tools* they want and never `depends: [mise]`.
- Trackers record the formulas/casks ppm installed (`installed_deps`). `ppm remove` uninstalls them when no other installed package recorded or declares them. System packages are never removed.
- `-c` skips all of this, like hooks.

### Declared Resources (a package.yml key ppm core does not own)

ppm owns `version`, `author`, `depends`, `platforms`, `categories`, `brew`, `cask`, `system`, `meta`, `onboard`,
`links` and `files` (`PPM_CORE_KEYS` in `packages.sh`). **Any other top-level key is a declared resource**: during
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
  unlink them (`psm agents rm`) when one is removed. Every remove either makes is scoped with `-a`
  (`anfs_skill_remove`). `core/wsm` does the same for the spaces'
  skills (`wsm_ppm_changed`: `wsm skill install`, `wsm __agents_rm`). Both read the ids with
  `anfs_skill_package_agents` (`lib/anfs/skill.sh`).

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
- **Who emits:** ppm (`install`/`remove`, with the packages) and wsm (`install` for each space
  that became installed, `remove` for each one removed, by id: `lgat` for a source's root space,
  `lgat/tech/web`, no trailing `/`). wsm's are tied to the outcome, not the command: `wsm new`
  emits `install` for a space it installs, a re-install of what is installed emits nothing,
  `--dry-run` emits nothing, and `implode` emits `remove` for every space.
  psm, pcm and pmm emit nothing yet: add an emitter when there is a listener.
- A package that listens to another tool registers from its own `install.sh` (stack's
  `obsidian`, for `ovm`):

  ```bash
  post_install() { anfs_callback_register wsm "$PPM_CURRENT_PACKAGE" "ovm link apply --event"; }
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
- **A tool reads another tool's list with `--json`, never by column.** stack's ovm reads
  `wsm ls --json`; anfs-dev's `anfs work` reads `wsm repo ls`, `ppm container` and
  `ppm vm` read `pcm list` and `pmm list`; the round trips read `ppm list --json`, `pmm list
  --json`, `pmm image list --json`, `pmm network list --json` and `psm ls --json`. Keys may be added to a list; renaming or
  removing one breaks its readers. The piped form is for a person's own pipes. There is no
  special flag for another tool's benefit: `pcm list --names` is gone, and `ppm container` and
  `ppm vm` read `list --json` like any reader (`ppm vm ip` is `pmm list`'s `address`).
- Detail views (`pcm inspect`, `ppm show`) are not tables and do not go through this.
- `anfs_sorted` sorts rows by a leading key field and drops it: a list by name whose first column
  is `source/name` keeps a name's rows (the winner, then what it shadows) together.

**Every list has one shape**, so whoever reads one tool's lists reads them all:

1. **The first column is the resource**, headed by its kind in the singular, holding
   `source/name`: `PACKAGE`, `CONTAINER`, `MACHINE`, `IMAGE`, `NETWORK`, `SKILL`, `SPACE`,
   `REPOSITORY`, `SOURCE`, `ISO`. There is no separate `SOURCE` column. Its JSON key is the kind in
   lower case (`container`, `skill`), the qualified value.
2. **`STATUS`** (key `status`) wherever a list says what state a thing is in, in the second
   column. Never `STATE` or `NOTE`.
3. **`local` is a reserved source alias**: the tool's own config directory, the implicit source
   pcm, pmm and psm have. `anfs src add` refuses it (64).
4. **What has no definition has no source**: a machine made by `pmm run`, a network made with
   `network create`, a build whose definition is gone. Its first column is its plain name (`web1`);
   a defined one is `core/web1`, and a shadowed definition's row is its own `source/name`.
5. **Lists that are not of a source's resources** (`pmm ps`, `pmm snapshot list`, `anfs
   callbacks`, `anfs report check`, `events ls`, `anfs bus status`, `anfs agents ls`, `anfs agents
   rules`, onboard's, stack's ovm's, `anfs work list`, `<tool> config list`) take rule 2 only.

`registry.bats` holds every `anfs_table` header in core's tools to rules 1, 2 and 5. A column a
person does not need can be in `--json` only: name more keys than headers (`psm list`'s `config`
and `repo`, `iso list`'s `catalog`).

The keys, which are the interface:

| Command | Keys |
| --- | --- |
| `ppm list`, `ppm list --installed` | `package` (`source/name`), `status` (`installed`, `outdated`: the source's `package.yml` version is newer; null: not installed), `version` (the installed one, else the source's) |
| `pcm list` | `container` (`source/name`), `status` (`running`, `stopped`, either with `, shadowed`, or `shadowed`; null: never started); `version`, `description`, `upstream`, `license`, `url`, `memory` (from `container.yml`) |
| `pmm list` | `machine` (`source/name`; the plain name: run from an image, or the definition is gone), `status` (`running`, `stopped`, `defined`, `shadowed`), `image`, `address` |
| `pmm image list` | `image` (`source/name`; the plain name: the definition is gone), `status` (`built`, `stale`, `unbuilt`, `shadowed`), `arch` (null: not built), `key`, `disk` (a tart build: its VM's name), `backend`, `user`, `sshkey`, `held` (a list: `web1`, `web1@s1`), `built` (when), `tested` (true when this build passed `image test`) |
| `pmm network list` | `network` (`source/name`; the plain name: made with `network create`, or the definition is gone), `status` (`active`, `inactive`, `missing`, `defined`, `shadowed`), `kind`, `subnet` (a bridged network: its bridge), `machines` (comma-separated) |
| `psm list` | `skill` (`<config>/<skill>`: the source's alias, or the config's name; `<config>/*` for a whole repo), `status` (`ok`, `partial`, `missing`, `*`), `config`, `repo` |
| `psm repo list` | `repository` (the repo: a path or URL), `status` (`missing`: a local path that is gone), `config` |
| `wsm list` | `space` (the id: `lgat`, `lgat/tech/web`), `status` (`ok`, `partial`, `not in the source`; null: not installed), `dir` (null: not installed), `note` (`2 missing, 1 leftover`; then `no id`, `invalid id`, `duplicate id (also <space>)`), `missing`, `wrong`, `in_the_way`, `leftover` (counts, `--json` only), `id` (the space's `id:`; null: none); `wsm list <id> --json` adds `files` (`[{file, status}]`) and `links` (`[{dest, src, status}]`: `ok`, `missing`, `missing src`, `wrong`, `in the way`, `invalid`) |
| `wsm skill list` | `skill` (`<space id>/<name>`; `<space id>/*` for a whole remote repo), `status` (`ok`, `partial`, `missing`, `waiting`: no agent yet, `*`; null: the space is not installed), `repo` (as the CLI is given it: a path resolved), `space`, `name` (the last three `--json` only) |
| `wsm repo list` | `repository` (`<space id>/<path>`), `status` (a clone's state, below; `missing`, `not a repo`, `not installed`, `no path`, `invalid`), `url`, `ahead`, `space`, `path`, `dir` (the clone's path; null while its space is not installed) (the last four `--json` only) |
| `anfs list` | `stack` (`source/name`), `status` (`installed`; `partial`: a record whose resources are not all there; null: not installed), `version` (the source's stack.yml) |
| `anfs show <stack>` | `kind` (`stacks`, then the resource kinds in install order), `resource`, `declared` (the manifest's `status:`, null when none), `actual` (the tool's word: `installed`, `running`, `stopped`, `partial`; null: not there), `from` (the stack that brought it in) |
| `anfs src list` | `source` (the alias), `status` (a clone's state, below; `local`: not a git repo; `missing`), `url` (the clone's `origin`; the list's URL when it is not cloned), `list` (`user`, `system`), `provides` (a list), `ahead` (`--json` only) |
| `anfs src push`, `wsm repo push` | `source` / `repository` (as the tool's list names it), `status` (`pushed N`, `pushed N (uncommitted changes left)`, `up to date`, `no upstream`, `detached`, `rejected`, `not cloned`; `-n`: `would push N`), `branch`, `upstream` (null: none), `commits` (ahead of the upstream), `error` (git's first error line when rejected) (the last two `--json` only). Exit 1 when one was not pushed (`up to date` is not a failure). `lib/anfs/repo.sh`'s `anfs_repo_push_cli` is both commands: names (resolved before anything is pushed) or `--all` (every one ahead), neither is a usage error that lists the ones ahead |
| `anfs iso list`, `pmm iso list`, `ventoy iso list` | `iso` (the entry's id, one namespace across catalogues; null: a file no entry names, with `--all`), `status` (`present`, `missing`, `unverified`: there, with no recorded sum; `unlisted`; `invalid`: the entry's file name is missing or has a `/`), `name`, `architecture`, `file`, `size` (bytes in JSON), `catalog` (the `isos.yml` that defines the entry) |
| `anfs callbacks` | `tool`, `listener`, `status`, `handler` |
| `<tool> config list` | `name`, `value` (the effective value; null: empty), `from` (`env`, `local`, `shipped`, `default`), `file` (the file it is from; the shipped one for `default`; null for `env`); with `anfs config list --all` a leading `tool` |
| `wsm id <prefix>/`, `wsm id --new` | `space`, `status` (`--new` only: `new`, `kept`, `invalid id`, `not written`), `id` |
| `wsm events ls`, `anfs events ls` | `--json` is not this table's array: the event lines as stored, one per line; the rows' keys are `event`, `subject`, `space`, `by` |
| `anfs report check` | `check` (`report-to`, `file`, `gh`, `gh-auth`, `origin core`, `origin stack`, `skill`), `status` (`ok`, `fail`), `detail` |
| `anfs bus status` | `service` (`nats`, `jetstream`, `anfsd`, `shipper`, `dispatch`, `harness <name>`, `linger`), `status` (`ok`, `fail`, `stopped`, `not installed`, `lag`, `off`), `detail` |
| `anfs agents ls` | `run` (the run id's last 8), `status` (the state, and a failure's or rejection's reason: `failed (timeout)`), `rule`, `role`, `space` (the path), `harness`, `job` (null: `job: none`), `age` (since submitted), `id` (the whole run id), `state`, `reason` (the last three `--json` only) |
| `anfs agents rules` | `rule`, `status` (`ok`, `invalid`, `disabled`, `unenforced`, `partial`), `space`, `on` (`report.filed package=core/* to=file`), `as`, `harness`, `reason` (why it is invalid), `job` (its name template), `space_id` (the last three `--json` only) |
| `pmm ps` | `name`, `arch`, `backend`, `pid`, `ssh` |
| `pmm snapshot list` | `name`, `build` (the build key it is on; null for a tart snapshot) |

A clone's state (`anfs_repo_status` in `lib/anfs/repo.sh`, for `anfs src list` and `wsm repo list`): `clean`, `dirty`
(uncommitted or untracked changes), `unpushed` (commits its upstream lacks, as of the last fetch;
nothing is fetched), `no upstream` (a branch that tracks none, or a detached HEAD), or `dirty, `
followed by either of the last two. `ahead` is the count of unpushed commits (null: no upstream,
or not a clone).

On a terminal (not piped, not `--json`, `NO_COLOR` unset) `anfs_table` colors a `STATUS` cell
that needs attention: `dirty` (alone or first) and push's `rejected` red, `unpushed`, `no upstream`
and push's `detached` yellow. The map
is `_anfs_tone` in `table.sh`; a state added there is colored in every list.

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
cli_group repo "The repos skills come from"
cli_cmd "repo remove" "Remove a repo's config" --alias rm --arg "dir"
cli_standard                 # completion and help, last
cli_dispatch "$@"
```

- A two-word name is a sub-command; its function is `cmd_skills_remove`. A group on its own
  prints its sub-commands. No tool writes its own second-level `case`.
- `cli_group <name> "<summary>" --default <sub>`: an option where the sub-command would be (not
  `-h`/`--help`) goes to `<name> <sub>`, so `anfs report --title x` is `anfs report new --title
  x`; the group alone still prints its sub-commands, and its help says where options go.
- `--opt "-y --yes: help"` is a flag; a word after the names (`--to SPEC`) means it takes a value,
  and the word is its **kind**. `--arg "service..."`, `--arg "[snapshot]"`: `[..]` is optional,
  `...` is one or more, the word is its kind.
- `--passthrough`: options the command does not declare are left for it, in place (`pcm up`,
  `pcm ps`, `pmm shell`: they go on to podman or ssh). `-y` and `-i` are never passed on: they are the tool's.
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
  `psm path`; in a group, only a sub-command named `__<name>` does (`anfs report __sink` is
  `cmd_report___sink`). *Only* `cmd_` functions run, so a tool's internals are never reachable from its
  command line, and a command can never shadow a system binary in package hooks (`install`, `file`).
- A tool whose tests source its libraries directly keeps its declarations in a library file
  (`lib/pmm/commands.sh`, `lib/pcm/commands.sh`), so the tests have them too.
- `cli_section "<title>"`: the top-level commands declared after it are listed under that heading
  in help, after the others (anfs's "Tools" and "From packages").
- **A tool with settings calls `anfs_config_declare`** (`lib/anfs/config.sh`) among its
  declarations, before `cli_standard`: that is its `config` group (Configuration). A tool ships
  `<tool>.env` if and only if it declares the group (`registry.bats`); psm has neither.

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

- `anfs machine image build debian-13` is `pmm image build debian-13`; `anfs help machine` is
  `pmm help`; `anfs __complete machine ...` is `pmm __complete ...`. They are listed under "Tools"
  in `anfs help`.
- The tool is `~/.local/bin/<tool>`, as `anfs install` and `anfs src install` run it. One that is not there is
  `pmm is not installed (ppm install core/pmm)`, exit 69.
- `sh/anfs.sh`'s `anfs` function sends each of the five through the tool's own shell function when
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
  functions anfs-dev/dev still stows there (`ppm container`, `ppm vm`, `ppm user`) are
  the last of that use, until anfs-dev's plan 03 replaces them.
- anfs-dev/dev's `anfs work` and `anfs hooks` are the first (`packages/dev/README.md` there).

**The verbs are the same everywhere.** `list` (alias `ls`), `remove` (alias `rm`), `install`,
`show`, `path`, `cd`, `validate`, `implode`, at the top level and in groups (`psm repo list`,
`wsm repo install`, `anfs src remove`, `ppm container remove`, `pmm image list`). `image` is the group for what a
tool's main object runs from, and `pmm image` is the reference for it: besides the shared verbs,
`build`, `test` (boot it and run its test; `validate` only reads the definition), `export` and
`prune`. pcm and pmm keep `up`/`down`/`ps`, the names of what
they wrap, with `stop`/`ssh` as aliases (pmm's `run` is its own command: a machine from an image).
Options: `-y, --yes` does not ask, `-f, --force` replaces what is in the way, `-n, --dry-run`
says what would happen. **Every command takes `-y`** (cli.sh adds it to each), so a script or the
toolkit API's `yes` never has to know which commands ask; one with nothing to ask ignores it. A
command that asks still declares it, so its help says what `-y` skips. A command asks
(`anfs_confirm`) when it destroys or replaces something, or acts on more than was named (a whole
source, a group, dependents); starting, installing and cloning what was named do not ask. So every
`remove`, `reset`, `prune` and `implode` asks, and so do `install source/` (and ppm's `repo/` and
`@category`), `anfs src install`, a snapshot or an `-o` file that would be replaced, `ppm file reset`
`anfs src remove` and `anfs install <stack>` (a stack is a group: it prints the plan, then asks). A tool calling another after it asked, or
unattended (stacks.sh, `anfs src install`, implode), passes `-y`.

**Every command takes `-i, --interactive`** too (cli.sh, as `-y`; `CLI_OPT[interactive]`): after
the options are read and before the argument count is checked, it asks for each positional argument
not given, in order, then each declared value option not given (flags are not asked). The question
is the option's help and its kind (`Where (SPEC):`), or the argument as the usage line writes it
(`<thing>:`, `[snapshot]:`); a kind's `complete_<kind>` candidates are listed first (up to 20), and
a lone one is the default. Enter leaves an optional one out; a required argument is asked again; a
`...` argument is asked once and split on spaces. The answers go into `CLI_POS` and `CLI_OPT` as if
typed. `-i` with no terminal exits 77; `-i -y` is a usage error (64). `cli_call` does not pass it
on: a command that runs another passes `-i` itself, and only when it was given one. Without `-i`
nothing asks for a missing value: it is a usage error, as before. Tests pipe the answers in with
`ANFS_TEST_TERMINAL=1`, which makes stdin count as a terminal for `-i`.

A tool's main resource is at its top level (`psm list`, `pcm list`, `pmm list`; anfs's is the
stack, `anfs list`), never in a group
of its own name; a group is for another kind of thing the tool manages (`psm repo`, `psm agents`,
`wsm repo`, `pmm image`, `pmm network`). The same kind takes the same group name in every tool:
`repo` is where a tool's repositories are listed and installed.

**ppm's options are its commands' own**, like every tool's: `ppm install -f pkg` or
`ppm install pkg -f`, and `ppm list -f` is refused. Its helpers still read `$force`, `$config`,
`$reinstall`, `$skip_deps` and `$yes` by name through dynamic scoping, because four of those files
are sourced by `install.sh` under bash 3.2, which sets the same variables itself: `main()` declares
them, and `cli_before_command` fills them from `CLI_OPT` once the line is read. The `cmd_`
functions in the bootstrap files did not change.

**Exit codes:** 0 done; 1 what was asked for is not there or could not be done; 2 ambiguous;
64 used wrongly; 69 something this needs is missing; 73 already exists; 75 locked (busy);
77 needs a person at a terminal (`anfs_confirm` with no terminal and no `-y`, `-i` with no terminal, sudo with no
terminal and no `SUDO_ASKPASS`: ppm's `_system_sudo`, anfs's `implode --all`).

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
  `registry.bats` holds the library to that. `wsm ls` checks every link of every space, which
  is why completion does not call it: wsm's completion is one `find` over the sources' `spaces/`
  for `space.yml` (ids and prefixes), and a `-L` per space for the installed ones.
- One tool may complete another's things by asking it: stack's ovm's `--to` runs
  `wsm __complete install ""`.

**Shared helpers, used by every tool** (a tool's own `tilde`, `_display`, `confirm` are one-line
aliases of these; don't write another):

- `anfs_confirm "<what this does>" "<the question>"` (cli.sh) asks before something that cannot
  be undone: true at once with `-y`; without a terminal it says to pass `-y` and exits 77; anything
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
  warn/error/debug line plus a `start: <id> <args>` and an `end: <id> <exit>` line per invocation
  (id `<pid>-<epoch>`; the end line is an EXIT trap chained with the tool's own, so a tool that
  sets `trap ... EXIT` inside a command loses it), whether or not `-d` is on. `anfs log
  [-f] [tool]` prints or follows it. Past 1 MB it becomes `anfs.log.1`.
- `ANFS_LOG=off` writes no file, and `ANFS_EVENTS=off` no event (lib/anfs/events.sh). Test
  helpers set both; a test that sources a tool's libraries
  directly must source `log.sh` first (pmm's and ppm's do), since the tool's `warn`/`die` call it.

## Reporting a bug: anfs report

`lib/anfs/report.sh`. An agent (or a person) that hits a bug in an anfs tool describes it; where
it goes is the machine's setting, so the caller never needs to know. The skill that tells an agent
to use it is `skills/anfs-bug-report` (it only runs `anfs report`, never `gh`).

| Command | Does |
| --- | --- |
| `anfs report [new] --title T [--package PKG] [--expected] [--actual] [--steps] [--body-file F\|-] [-n] [-y]` | the report: `Package:`, the body file's text, the three sections, then `report diag`'s block; filed, its id printed. A group with a default: options and no sub-command are `new` |
| `anfs report diag` | the diagnostics: anfs's version (and `ANFS_WORK`), platform, bash, git, podman, each source's short commit and `anfs_repo_status`, each ppm tracker's version, and the log's last 10 failures (an `error:` line, or a failed run's `start:` and non-zero `end:`) |
| `anfs report check` | `CHECK STATUS DETAIL`, `ok`/`fail` per row; exit 1 when one fails. The value of `ANFS_REPORT_TO` and its FROM; a file target writable or creatable; or `gh`, `gh auth status` (its only network call), core's and stack's origins on GitHub; and the skill installed for every detected agent (`lib/anfs/skill.sh`, read-only) |
| `anfs report status <id>` | `open`, `fixed` (closed; the commit not in this host's checkout), `available` (the commit an ancestor of HEAD in the source's live checkout, or with `ANFS_WORK` the job's worktree); exit 0 available, 1 otherwise, 2 an unknown id. A file report's state is its record's |
| `anfs report show <id>` | the report: a file report's record; a GitHub issue through `gh issue view` (`--comments`; `--json` its fields). `--json` for a record: `id`, `status`, `record`, `file`, `report` |
| `anfs report close <id> --commit SHA [--source S]` | the fix recorded: a file's `Status:` line rewritten; GitHub: a `Fixed in <source> <sha>` comment, then `gh issue close` |
| `anfs report wait <id> [--timeout 3600]` | until `available` (0) or the timeout (1); 2 an unknown id. On events, not a timer: the state once, then the report's scope and the host scope followed (events.sh's `anfs_events_follow`), the state read again only on this report's `report.closed` or a `source.updated` (one `git merge-base` per event, none per tick). A GitHub issue closed by hand emits nothing: seen at the next `source.updated`. An agent runs it in the background |

- **`ANFS_REPORT_TO`** (anfs.env, commented: `github`): `github`, or a path (a leading `~/`
  expanded; it must be absolute). Set per machine in `anfs.local.env`.
- **A file report's record** (agents/02b) is `$ANFS_STATE_HOME/reports/<space id>/<id>.md`, the
  space the one around the file (`host` when none has an id): `## r-<YYYYMMDD>-<n> <title>`,
  `Status: open`, the body. Made exclusively (`set -C`) as the next free `<n>` of the day in that
  space, the records and the file's `## r-` headings both counted, so two sink files or two writers
  in one space never share an id (ten `new` at once: ten ids). `close` rewrites the record's
  `Status:` line only (`fixed in <source> <sha> (<date>)`); `status`, `show` and `wait` read the
  record.
- **The file is a view of the records**: anfsd's consumer `anfsd-sink-report` (`anfs.*.report.>`)
  runs `anfs report __sink` (plumbing) with each event on stdin, one at a time (a failure delivered
  again, 5 tries in all, then logged): on `report.filed` it appends the record unless a `## <id> `
  heading is there; on `report.closed` it rewrites that section's `Status:` line from the record
  (appending the record when the file lacks it), atomically, under a `mkdir` lock beside the file
  (`.<name>.lock`, its holder's pid inside; a dead holder's is taken over). Only records of the
  file's own space are rendered. When anfsd is not running (no live pid in `anfsd.pid`) or events
  are off, `new` and `close` render themselves: the render is idempotent, so a daemon that comes up
  later changes nothing. **Never edit a report's section in the file**: it is rewritten from the
  record. Sections written before the records have none: they stay text, `status` and `close` say
  so (2), and they are closed by editing their `Status:` line by hand.
- **github**: the owner is the `--package`'s source (core when none); its clone's `origin` must be
  a GitHub URL (`git@github.com:`, `ssh://git@github.com/`, `https://github.com/`), else 1, saying
  to set a file. Duplicates are searched (`gh issue list --search "<title> in:title"`) and shown,
  then `anfs_confirm` (77 without a terminal or `-y`), then `gh issue create`. The id is
  `owner/repo#N`; `status` reads `gh issue view`'s state and the last `Fixed in` comment.
- `-n` calls no `gh` and makes no record. `--json`: `new` is one object (`id`, `to`, `repo`, `file`, `url`,
  `title`, `filed`, `duplicates` as `[{number, state, title, url}]`, `report`); `diag`
  `{"diagnostics": ...}`; `status`, `wait` and `close` `anfs_result` objects.
- ppm's trackers are read as files (as `onboard.sh` does): a report is wanted most when ppm is
  what is broken.

## Events (lib/anfs/events.sh)

The toolkit's event log: what happened, in which space, by whom. One CloudEvent (1.0, structured
JSON) per line, appended, never rewritten, so `cat`, `grep` and `jq` read it, and from agents/02 a
shipper sends each line as it is to NATS JetStream (the files are its spool). The profile (the
attributes, the rules; language-neutral, for other implementations) is in anfs-io/docs,
`units/agents/01-events/plan.md`.

```
{"specversion":"1.0","id":"<UUIDv7>","source":"/anfs/spaces/<space id>","type":"io.anfs.report.filed",
 "subject":"r-20261023-1","time":"2026-10-23T17:03:17.480Z","datacontenttype":"application/json",
 "actor":"claude:2e9431a0","actorspace":"<space id>","actorrole":"maintainer","spacepath":"anfs-dev",
 "anfsv":1,"data":{"package":"core/pcm","title":"...","to":"file"}}
```

- **Where**: STATE, `$XDG_STATE_HOME/anfs/events/<space id>/<YYYY-MM>.jsonl` (the UTC month);
  `events/host/` for the host scope (`source` `/anfs/host`).
- **A space's id** is `id:` in its `space.yml`: 10 of `a-z0-9` (generated from `a-z2-7`), written
  once (`wsm new`, `wsm id --new`), never changed, moved with the file (`wsm move`). The log is
  filed by it; `spacepath` is only what wsm called the space when the event was written.
- **`anfs_emit [--at DIR|--host] <type> <subject> [key=value...]`**, the one way to write an event:
  `<type>` is short (`report.filed`; written as `io.anfs.report.filed`), data values are strings.
  The space: `--host`; `--at DIR` (the nearest `space.yml` at or above it); else `ANFS_SPACE` (a
  space path); else the nearest `space.yml` at or above the current directory; else the host
  scope. A space with no id: a warning, and the host scope with its `spacepath`.
- **Who**: `actor` is `ANFS_ACTOR`; else detected: Claude Code (`CLAUDECODE=1`) is `claude:<the
  first 8 of CLAUDE_CODE_SESSION_ID>`, a harness that sets `AI_AGENT` its part before the first
  `_`; else `shell:$USER`. Other harnesses set `ANFS_ACTOR` (dispatch does). `ANFS_AS=<space
  path>/<role>` gives `actorspace` (that space's id) and `actorrole`. These are what the writer
  says: a claim. Only for a dispatched run does anyone attest them (next).
- **A dispatched run's events** (02d): anfsd sets `ANFS_EVENTS_SPOOL` to the run's own spool
  (`~/.local/state/anfsd/runs/<run id>/events/`), and `anfs_emit` appends there instead of the log
  (same layout, `<scope>/<YYYY-MM>.jsonl`; a line may then be at most 4096 − 512 bytes, the room
  for the stamp). anfsd moves each line into the log with the run's identity **stamped**: `actor`
  `<harness>:<last 8 of the run id>`, `actorspace` the rule's space, `actorrole` the role, and two
  extensions: **`actorrun`**, the full run id, and **`actorclaimed`**, set only when the line said
  another actor or role: what it said (`shell:roberto as tkj76y3nfx/person`). `actorclaimed` is a
  claim, never an identity; the actor is the stamp. Every other attribute keeps its bytes, `data`
  last. Refused (counted in the run's `run.json`, `events_refused`): `run.*` (anfsd's own), a line
  whose scope directory is not its `source`, more than `ANFSD_RUN_EVENTS_MAX` (1000) lines, and a
  line over 4096 bytes once stamped. A run reads its own events in the log (`events ls`, `report
  wait` read the log, not the spool) a second or so after it wrote them. Cross-space emits are open
  (until `accepts:`): the stamp says who.
- **Atomic, no locks**: a line is at most 4096 bytes (more is refused with a warning) and goes out
  in one `write(2)` with `O_APPEND` (`cat >>`): bash's own `printf` writes through stdio, 1 KB at a
  time on macOS, and parallel writers would interleave.
- **Never fails the caller**: an error is a warning (`event <type> not recorded: ...`).
  `ANFS_EVENTS=off` (anfs.env) writes nothing; **the test helpers set it**, and a test about events
  turns it on for one command.
- The envelope is built in one function (`_anfs_ev_envelope`) and read through one accessor
  (`_anfs_ev_parse`): a change to the profile is one place.
- **Who emits** (01): `anfs report` (`report.filed`: package, title, `to` (`file` or `github`),
  `repo`; `report.closed`: commit, source), into the report file's space, or the host scope for
  GitHub. `-n` emits nothing. (02a) `anfs src update`, and every source update through
  `gitsrc_update` in a tool that sourced events.sh: `source.updated` into the host scope for each
  source whose HEAD moved (subject the alias; `from`, `to` the commits; a clone's `from` empty).
  (02b) anfsd: `run.submitted`, `run.working`, `run.completed`, `run.failed`, `run.canceled`,
  `run.rejected` into the rule's space, subject the run id, actor `anfsd` ("Dispatch"), written by
  its Go writer of the same profile into the same files; (02d) `run.submitted`'s data has `held`
  (`rate` or `queue`) and `detail` for a held run, `redispatch` (who asked) for a redispatched one;
  `run.rejected`'s has `detail`. (02c) anfsd, following `podman events`:
  into the host scope, actor `podman`, subject the container's (or pod's) name:
  `container.created|started|stopped|died|removed|paused|unpaused`, `container.health` (only
  when a container's health changes), `pod.created|started|stopped|removed`; data `id` (12),
  `image`, `pod` (the pod's id, 12), `exit` (died), `health`, `pcm` (the `io.pcm.name` label pcm
  sets). exec, attach, init, sync, cleanup and the rest are not events. The same container,
  status and second are one event; at most 20 a second (the rest counted in anfsd's log).
  `podman.connected` when podman is reached (a subscriber lists once to reconcile; nothing polls
  `podman ps`) and `podman.disconnected` (data `error`) when it goes: on macOS when the podman
  machine stops. `pcm down` of a service is `container.died` then `container.removed` (podman
  reports no `stop` for it); `pcm up` is `container.created`, `container.started`.

**`events ls`**, one helper (`anfs_events_cli`, `anfs_events_ls`), two commands, as `repo push`:

| Command | Reads |
| --- | --- |
| `wsm events ls [SPEC...]` | the space around `.` when no SPEC; a SPEC as wsm resolves it (an id is that space, `x/` the subtree). A space with no id is a warning |
| `anfs events ls [SPEC...] [--all]` | every scope, the host's included, when no SPEC (or `--all`); SPECs through `wsm __event_spaces` (plumbing) |

- `--type GLOB` (short or full: `report.*`, `io.anfs.report.*`), `--subject S` (exact), `--since
  30s|10m|2h|7d|YYYY-MM-DD[THH:MM[:SS]]` (UTC), `--by GLOB` (the actor), `--after ID` (ids sort by
  time), `--json` (the lines as stored, one per line: not an array).
- `EVENT SUBJECT SPACE BY` rows, oldest first: EVENT is `<UTC time>Z <short type>`, SPACE the path
  (or id; `host`), BY the actor and ` as <role>`.
- **`-f`** keeps printing (tab-separated, or JSON lines), the backlog first; **`--once`** (with `-f`)
  prints the first match and exits 0, an existing one included: **how an agent waits**, e.g. on a
  fix: `wsm events ls -f --once --type report.closed --subject <report id>` (the bare form of
  `anfs report wait`, which follows the same way). It keeps one descriptor per scope on its newest
  file and reads what each gained, once a second (`anfs_events_follow <fn> [deadline]`, which a
  caller hands each new line; `anfs_events_follow_init` starts it at the files' ends); a new month's file, a new scope and a file that did not exist yet are
  read from their start. The tick is `read -t 1` on a private FIFO: no process per tick, and a tick
  that returns early falls back to `sleep 1`, so it cannot spin (the 2026-10-23 loop).
- The toolkit API's `watch` is gone (agents/03): a program follows the bus ("The bus").
- **The files are the record; the bus is for programs.** `events ls` reads the files, `-f`
  included, whether NATS is up or not (an emit never waits on the bus, so on this host they are
  never behind it); anfsd ships every line to NATS ("The bus").

## The bus (core/nats, core/anfsd)

The event log on NATS JetStream, for programs (anfsd's consumers, the ui in its container): every line of every month file is published, as it is, exactly once per event id. NATS is the
broker; anfsd (anfs-io/runtime, Go) ships, dispatches and supervises ("Dispatch"), and renders the
report file; it is not a broker. The plan is anfs-io/docs `units/agents/02-daemon/` (02a, 02b, 02c).

| | |
| --- | --- |
| Subjects | `anfs.<scope>.<noun>.<verb>`: the scope a space id or `host`, then the short type (`anfs.tkj76y3nfx.report.filed`, `anfs.host.source.updated`) |
| Stream | `ANFS`, subjects `anfs.>`, file storage, limits retention, discard old, `max_age` 90 days, `max_bytes` 1 GiB, duplicate window 24 h (anfsd.env). A bounded window: the files keep everything |
| NATS | `127.0.0.1:47222` (not 4222, which apps in containers publish), monitoring `47223` (nats.env). Users `anfsd` (publishes), `admin` (the person, through `anfs bus nats`), `reader` (subscribes `anfs.>`, its own consumers on `ANFS`; never publishes `anfs.>`; the ui's, consumer `ui`) |
| STATE | `~/.local/state/nats/` (0700): `server.conf` (0600, rendered: never edit), `users/<user>` (a password each, 64 hex, made once), `port`, `jetstream/`, `nats-server.log` (macOS). `~/.local/state/anfsd/`: `cursors.json` (`{"<scope>/<YYYY-MM>.jsonl": <byte offset>}`), `anfsd.pid`, `anfsd.log` (macOS), `runs/<run id>/` ("Dispatch"), `podman.json` (podman's state) |
| DATA | `~/.local/share/nats/<version>/{nats-server,nats}`, `~/.local/share/anfsd/<version>/anfsd`, linked from `~/.local/bin`; the downloads in `~/.cache/{nats,anfsd}/<version>/` |
| Services | `lib/anfs/service.sh`: launchd `io.anfs.nats`, `io.anfs.anfsd` (`KeepAlive`, `ThrottleInterval` 10); systemd user `anfs-nats.service`, `anfsd.service` (`Requires=`/`After=` NATS, `KillMode=process`; `Restart=on-failure`, `RestartSec=5`). Written by the packages' `post_install` (absolute paths, the install's PATH and HOME), removed by `post_remove`. On Debian, running without a login needs `loginctl enable-linger` (by hand; `anfs bus status` says so) |

- **Pinned binaries** (`lib/anfs/pins.sh`, `packages/<pkg>/pins.yml`: repo, version, the asset's
  name, the program's path in it, a sha256 per platform): `anfs_pin_fetch` downloads once, checks
  the sum (a mismatch fails the install naming both and deletes the file), unpacks into DATA.
  `packages/<pkg>/tests/pins [--print]` fetches the real assets and checks or prints their sums:
  by hand when bumping, never in bats. anfsd's sums come after its release (anfs-io/runtime's
  `release.yml`, a `v*` tag); until then `ANFSD_BIN` (anfsd.local.env: a build from source) is
  what core/anfsd runs, and `anfs bus status` says `from source`.
- **The shipper** (anfsd): fsnotify on `events/` and each scope plus a 30 s reconcile; complete
  lines only; a cursor per month file, written (temp, fsync, rename) only over the prefix NATS
  acknowledged; `Nats-Msg-Id` the event id, so a resend after a crash is dropped; at most 256
  awaiting acks, 100 events/s per scope (burst 1000). A line that is not an event is logged once
  and stepped past. NATS down: backoff 1, 2, 5, 10, 30 s, one log line per change, emitting
  unaffected.
- **Podman** (anfsd, 02c): one child, `podman events --format json --filter type=container
  --filter type=pod`, from now; the events above ("Events"). Podman away (not installed; on macOS
  the machine stopped): the child ends and is started again after 5, 10, 30, then every 60 s, one
  log line per change, never a loop; up 2 s (or a line read) is connected, up a minute resets the
  backoff. `ANFSD_PODMAN=off` (anfsd.local.env) never runs it. Tests use a fake podman printing
  recorded lines (anfs-io/runtime's `internal/testfake`), never the real one.
- **`anfs bus`** (core/anfsd's `anfs-bus`, the package seam):

| Command | Does |
| --- | --- |
| `anfs bus status` | `SERVICE STATUS DETAIL`: `nats` (healthz, the version, the ports), `jetstream` (the stream ANFS: messages, size, first and last; another stream on `anfs.>` is a fail), `anfsd` (the service, its pid, its version, `release` or `from source`), `shipper` (a `lag` row per scope with lines past the cursor), `dispatch` (the rules loaded, disabled, `off` (`dispatcher: none`, said only when there are some) and invalid, from `anfsd rules --json`; the runs working, queued and held, from their records; an invalid rule is a fail), `harness <name>` (one per harness a rule uses: found on PATH, its `--version`; agy's is never asked: it hangs), `podman` (from `~/.local/state/anfsd/podman.json`, while anfsd runs: `ok` connected, `away` with podman's error and the next try, `off` for `ANFSD_PODMAN=off`; neither `away` nor `off` fails the exit: on macOS a stopped podman machine is normal), `linger` (Linux). Exit 1 when one is not `ok`. `--json` |
| `anfs bus start\|stop\|restart [nats\|anfsd]` | load, unload (it starts again at the next login), or write again and load; both when none is named, NATS first up and last down. `restart nats` renders `server.conf` from nats.env first; `restart anfsd` writes `ANFSD_BIN` or the release into the unit |
| `anfs bus reload` | SIGHUP to anfsd: it reads the dispatch rules again (a `source.updated` does too) |
| `anfs bus logs [nats\|anfsd] [-f]` | the log files (macOS) or `journalctl --user` (Linux) |
| `anfs bus nats -- <args>` | the nats CLI with `NATS_URL` and the admin user in its environment, never on its command line: `anfs bus nats -- stream info ANFS`, `-- sub 'anfs.>'` |

- Under the toolkit API (`bus` is a group), `status` and `logs` without `-f` are reads.
- Tests: core's bats stub `curl`, `launchctl`, `systemctl` (`ANFS_SERVICE_OS`, `ANFS_PIN_PLATFORM`
  pick the platforms) and never start a service or reach the network; anfs-io/runtime's Go tests
  run an embedded nats-server, and its `go/test/e2e.bats` the pinned one in a temp HOME.

## Dispatch (anfsd, `anfs agents`)

A space's `space.yml` says which event starts which agent; anfsd (anfs-io/runtime) starts it, in a
job of its own, and watches it. The plans are anfs-io/docs `units/agents/02-daemon/02b-dispatch.md`
and `02d-safe.md` (a run's spool and stamp, the environment, what a harness loads, backpressure,
`dispatcher:`).

```yaml
dispatcher: anfsd                # optional: anfsd (default) | none (another tool dispatches this space)
access:                          # beyond the job, what this space's dispatched agents may reach
  - {path: ~/.local/share/anfs/sources, mode: read}   # ~ and $VAR expanded; relative: from the space
agents:                          # the roles; a role's address is <space path>/<role>
  maintainer: {harness: claude, model: opus, concurrency: 1, queue: 10, budget_usd: 10}
dispatch:
  - name: fix-core-report        # [a-z0-9-], unique in the space
    enabled: false               # optional (default true): valid, shown, never run
    on: {type: report.filed, subject: "r-*", data: {to: file, package: "core/*"}, space: anfs-dev}
    as: maintainer
    harness: claude              # optional: the role's
    job: {name: "fix-{{subject}}", repos: [core]}   # anfs work new; or none (the default)
    prompt_file: prompts/report-filed.md            # or prompt: (exactly one)
    args: [--effort, high]       # optional: more of the harness's options
    timeout: 2h                  # default 1h, at most 12h
    rate: 20/h                   # starts per rule (N/s, N/m, N/h, N/d)
    stale: 24h                   # an older event is not acted on
    retries: 0                   # 0 to 2, after a failed exit only (30 s, then 2 min apart)
    overflow: delay              # delay (default) | reject: what a full queue or a spent rate does
    hold: 20                     # most runs of this rule held at once (default 20, 0 to 200)
```

- **One parser, anfsd's**: `anfsd rules [--json] [space.yml...]`, read by `anfs agents rules`. The
  rules come from every installed space with an id (`wsm ls --json`), at anfsd's start, on `anfs
  bus reload` (SIGHUP) and on a `source.updated`. A rule that fails is `invalid` (the reason in
  `--json`) and not loaded; the space's others load. Refused: an unknown key, an unknown template
  name, `on.type` matching `run.*` (a run would start runs), a harness not on anfsd's PATH, `job:`
  without `anfs work` (anfs-dev/dev), `access:` at `/` or `$HOME` itself, and in `args:` anything
  that skips permissions or overrides what anfsd hands the harness (`--dangerously-skip-permissions`,
  `--auto`, `--permission-mode`, `--settings`, `--add-dir`, `--sandbox`, `--tools`, `--mcp-config`,
  `--plugin-dir`, `--bare`, ...). Statuses: `ok`, `invalid`, `disabled`, `unenforced` (pi: no
  permission system), `partial` (opencode, antigravity: no read/write split), `off` (valid, but the
  space says `dispatcher: none`).
- **Templates** in `job.name` and the prompt: `{{id}}`, `{{type}}`, `{{subject}}`, `{{time}}`,
  `{{space}}`, `{{actor}}`, `{{data.<key>}}`, `{{run}}`, `{{job}}` (the last two not in
  `job.name`); in `job.name` a value is lowered and anything outside `[a-z0-9-]` becomes `-`.
- **A run**: the durable consumer `anfsd-dispatch` (filters: each rule's `anfs.<space id>.<the
  type's literal tokens>`, and `anfs.host.source.updated`) gets the event; one run per rule and
  event id (a redelivery finds the record, a rejection included, and is acked). The guards, in
  order: `stale` and `loop` (the event's `actorrun`, else its actor, is a run of this rule), each
  a final `run.rejected`; then `rate` and `queue` (no free slot and `queue:` runs waiting), which
  **hold** the run under `overflow: delay` (below) and reject it under `overflow: reject`. Then the
  record `~/.local/state/anfsd/runs/<run id>/run.json` (UUIDv7), the
  event's line `event.json` and the prompt are written, `run.submitted`, and the message acked.
  It starts when its role has a free slot and the host has one (`ANFSD_MAX_RUNS`, anfsd.env,
  default 2): `anfs work new <job> <repos>` (a job this run made on an earlier try is reused; any
  other existing job is `run.failed reason=job`), then the harness in its own session (setsid),
  cwd the job (`job: none`: the space's directory, read-only, a TMPDIR in the run's directory),
  stdin `/dev/null`, output `out.log`, with the environment below: `run.working` (job, branch). The prompt is the rule's, then anfsd's footer (who it
  is, the rule, the event, the job, what it may not do, "end with a summary").
- **Ends**: `run.completed` (exit 0; `commits` per repo ahead of main, `summary`: the final
  answer's last 1500 bytes), `run.failed` (`reason`: `exit`, `timeout`, `job`, `spawn`,
  `orphaned`; `exit`), `run.canceled` (`by`). The job stays for the person to review, merge and
  remove. A run is a task: never restarted (`retries:` aside). Timeout: SIGTERM to the group,
  SIGKILL 30 s later. anfsd stopped or restarted leaves runs running (their own sessions;
  `KillMode=process`): at start it adopts every `working` run whose pid is alive with the start
  time it recorded (checked every 10 s while there are any), and ends the rest from the exit status
  their wrapper left, else `orphaned`.
- **The environment is an allow-list** (02d): from anfsd's own only `PATH`, `HOME`, `USER`,
  `LOGNAME`, `SHELL`, `LANG`, `LANGUAGE`, `LC_*`, `TZ`, `TERM`, `__CF_USER_TEXT_ENCODING`, the
  `XDG_*` paths, `ANFS_*` (not `ANFS_WORK`, `ANFS_WORK_SAID` or the per-run names; `ANFSD_*` are
  the daemon's) and, for claude only, its credential (`ANTHROPIC_API_KEY`,
  `CLAUDE_CODE_OAUTH_TOKEN`). anfsd sets `TMPDIR`, `anfs work env <job>`'s variables,
  `ANFS_ACTOR=<harness>:<the run id's last 8>`, `ANFS_AS=<space path>/<role>`, `ANFS_RUN`,
  `ANFS_EVENT` (event.json), `ANFS_EVENTS_SPOOL` (the run's spool, "Events"),
  `GIT_TERMINAL_PROMPT=0` and an empty `credential.helper` through `GIT_CONFIG_COUNT`/`KEY`/`VALUE`
  (after any the job sets: every helper of the system and global config is reset, macOS's
  `osxkeychain` included), claude's `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, and the harness's own.
  So `SSH_AUTH_SOCK`, `GH_TOKEN`, `GITHUB_TOKEN`, `GIT_ASKPASS`, `AWS_*` and the rest never reach a
  run. anfsd's own `anfs work new|path|env` get the same list.
- **The harnesses** (anfs-io/runtime `internal/harness`; access per plan 02's decision 5):

| Harness | Command | Access |
| --- | --- | --- |
| claude | `claude -p --output-format stream-json --verbose --permission-mode dontAsk --settings <run>/claude.json --setting-sources= --strict-mcp-config [--bare] --add-dir <path>... [--model M] [--max-budget-usd N] --name <rule>:<run> -- <prompt>` | `claude.json`: `permissions.allow` (`Read` of every path, `Edit`/`Write` of the write ones, `Bash`), `permissions.deny` (`Bash(<cmd>)` and `Bash(<cmd>:*)` for each denial), `sandbox` (`enabled`, `failIfUnavailable`, `allowUnsandboxedCommands: false`, `filesystem.allowWrite` the write paths and the run's spool, `filesystem.denyRead` the credential files, `credentials.envVars` its own key denied), `claudeMdExcludes` |
| opencode | `opencode run --format json --dir <cwd> [--model M] <prompt>` | `OPENCODE_CONFIG_CONTENT`: `permission.external_directory` (each path and the spool allow, `*` deny), `permission.bash` (the denials deny); `OPENCODE_DISABLE_PROJECT_CONFIG`, `OPENCODE_DISABLE_CLAUDE_CODE`, `OPENCODE_DISABLE_EXTERNAL_SKILLS`, `OPENCODE_PURE` |
| pi | `pi -p --mode json --no-extensions --no-mcp --no-skills --no-prompt-templates --no-approve [--model M] [--tools read,grep,find,ls,bash] -- <prompt>` | none (the read tools only when the rule writes nothing) |
| antigravity | `agy -p <prompt> --sandbox --add-dir <path>... --print-timeout <s>` | its sandbox (the spool one of its directories); no read/write split |

- **What is enforced, and what is only documented.** An environment variable is a convenience the
  agent could undo; the real stops are claude's:

| Path to a credential | claude (sandboxed Bash) | opencode, pi, antigravity |
| --- | --- | --- |
| `SSH_AUTH_SOCK`, tokens in the environment | **enforced**: not in the environment; its own key also unset in Bash (`sandbox.credentials.envVars`) | removed from the environment |
| key and token files: `~/.ssh`, `~/.config/gh`, `~/.git-credentials`, `~/.netrc`, `~/.claude/.credentials.json`, `~/.local/state/nats` (the bus's passwords) | **enforced**: `sandbox.filesystem.denyRead` | readable: **documented** |
| macOS keychain (`osxkeychain`, `gh`, `security`) | the helper reset (a hint), and **no network** out of the sandbox (under `dontAsk` every host outside the empty `allowedDomains` is refused), so a token taken from it cannot be used | reachable: **documented** |
| `git push`, `gh` over the network | **enforced** by the sandbox's network (and denied by rule) | denied by rule (opencode), or not at all (pi, antigravity): **documented** |

  This is why anfs-dev's rules use claude. A side effect: claude's sandboxed Bash has no network,
  so a fix that needs a module download fails (a per-space `network:` list is later work).
- **What a dispatched harness loads**: claude only `--settings` (and managed policy):
  `--setting-sources=` loads no user, project or local settings file (no hooks, `env`, plugins or
  permissions from them), `--strict-mcp-config` connects no MCP server, `claudeMdExcludes` leaves out
  `~/.claude/CLAUDE.md` and `~/.claude/rules/`; the repos' `CLAUDE.md` and `AGENTS.md` still load,
  and so do user skills (`~/.claude/skills`) and subagents (`~/.claude/agents`): definitions the
  agent may use, not code that runs by itself. Hooks a role needs would come from the run's
  `--settings` only. `ANFSD_CLAUDE_BARE=on` (anfsd.env) adds `--bare` (no skills, agents or auto
  memory either), which reads no OAuth login or keychain: only for a host whose claude
  authenticates with `ANTHROPIC_API_KEY` or an `apiKeyHelper`. pi loads no extensions, MCP, skills
  or prompt templates; opencode no project config, nothing of `~/.claude`, no external skills or
  plugins, but its global `~/.config/opencode` (its MCP servers) has no switch: documented;
  antigravity: none known, not isolated.
- **Backpressure delays, with bounds** (02d): under `overflow: delay` a full queue or a spent
  `rate:` **holds** the run: it is `submitted` with `held: rate|queue` and `held_since`, and
  `run.submitted` says `held` and `detail`; nothing is emitted when it leaves hold (the next is
  `run.working`, or a final state). At most `hold:` runs per rule are held; one more is
  `run.rejected` with detail `hold: 20 full`. A rule that holds runs holds every new one too (first
  in, first out). They enter the queue, oldest first, when the role's queue has room and the
  rule's window frees a start (one timer per rule while it holds runs, no polling); `rate:` counts
  runs as they enter the queue (`queued`). Held runs are records: a restart holds them again, in
  order. **Stale is checked again when a run would start**: one that waited past `stale` ends
  `run.rejected reason=stale`. An event a rule rejected for `queue` or `rate` is **unhandled**
  (every other record handles it): `anfs agents ls --unhandled` lists them and `anfs agents
  redispatch` takes them.
- **`dispatcher: none`**: the space's rules are parsed and shown (`off`), never loaded nor in the
  consumer's filters; at each reload its queued and held runs end `run.canceled by=dispatcher:none`
  (working runs go on: `anfs agents stop`); `redispatch` refuses it. The shipper and the report
  sink are unaffected: the space's events are still shipped and its BACKLOG rendered.

- **What a dispatched agent may not do before 04's approvals** (denied to each harness that can
  deny, and said in every footer): `git push`; `ppm install|remove`; `anfs install|remove|implode|src
  update`; `wsm install|remove`; `anfs report close`; `gh`; `sudo`; `launchctl`; `systemctl`; `anfs
  bus`; `anfs agents`; writing outside the job, its TMPDIR and `access:`'s write paths. Merge,
  install, push and close are the person's.

**`anfs agents`** (core/anfsd's `anfs-agents`, the package seam), from the run records, so anfsd
need not be up; a run is its id or the id's last 8 characters:

| Command | Does |
| --- | --- |
| `anfs agents ls [SPEC] [--all]` | `RUN STATUS RULE ROLE SPACE HARNESS JOB AGE`: the runs not ended and the last day's (`--all`: all); a held run's STATUS is `held:rate` or `held:queue` |
| `anfs agents ls --unhandled [SPEC]` | `EVENT SUBJECT RULE REASON AGE`: per rule, the events it rejected for `queue` or `rate` and never ran |
| `anfs agents show <run>` | the record, the trigger event, the command line (the prompt cut), the job, held since, redispatched by, its events (ingested, refused, the bytes of its spool not ingested); `--json` the record and the event |
| `anfs agents redispatch <event> [rule] [--again] [-y]` | the event's line found in the log by its id (the UUIDv7's month, `grep -F` in each scope), `anfsd match` on it, then (asked without `-y`) a request `~/.local/state/anfsd/redispatch/<uuid>.json` (`event`, `rule`, `by`, `again`) and SIGHUP to anfsd's pid; anfsd reads the directory at start and on SIGHUP and submits, per matching rule (or the one named), a run that skips stale, rate and loop (it may wait for the queue: `redispatch_by` in the record, `redispatch` in `run.submitted`). Refused by anfsd, in its log: a disabled rule, `dispatcher: none`, a run of it not ended, an event it handled unless `--again`. With anfsd down the request waits for its start |
| `anfs agents logs <run> [-f]` | `out.log` through `anfsd render <harness>` (claude's stream as text); `--json` as written |
| `anfs agents stop <run>\|--all [-y]` | the `cancel` marker (who), then SIGTERM to the run's group (the recorded process only: its start time is checked), SIGKILL 30 s later; anfsd says `run.canceled`. A run not started yet is canceled before it starts. Asks first |
| `anfs agents rules [SPEC]` | `RULE STATUS SPACE ON AS HARNESS`, through `anfsd rules --json` |
| `anfs agents match [--event FILE\|-] [--type T --subject S --data K=V... --space SPACE] [space.yml...]` | the dry check: what each rule would do with that event (no match and why; submit: the job, cwd, environment, the harness's command line; reject and why; `disabled`: what it would do), through `anfsd match`. Starts and writes nothing |

- Under the toolkit API (`agents` is a group), `ls`, `show`, `rules`, `match` and `logs` without
  `-f` are reads; `stop` and `redispatch` writes.
- Tests: anfs-io/runtime's Go tests run fake harnesses and a fake `anfs` (`internal/testfake`)
  against an embedded nats-server; core's bats (`packages/anfsd/tests/agents.bats`, `bus.bats`)
  read fixture run directories and a stub `anfsd`, with a PATH of stubs and the system's only: no
  test ever finds or starts a harness.

## Key Files

- `~/.config/anfs/system.list` — default sources, linked from `core/anfs` (don't edit: `anfs src
  ssh` switches a system source's clone `origin` and leaves the list, whose URL is only used for
  the first clone; `anfs src list` shows the origin)
- `~/.config/anfs/user.list` — your sources (made and edited by `anfs src add/remove/ssh`, or a link into your repo); higher priority than system.list
- `~/.local/share/anfs/sources/<alias>/` — one clone per source; a local-path source is a link here
- `~/.cache/anfs/updated/<alias>` — each source's last successful clone/pull. `ppm install`,
  `pcm up`/`install` and `anfs install` auto-update only the sources older than
  `ANFS_UPDATE_CACHE_DURATION` (default 24h); a source skipped for uncommitted changes stays stale
  on its own and is rechecked next time. Install prints one `Not updated (uncommitted changes):
  <repos>` line for them; `ANFS_QUIET_SKIPPED_REPOS=true` in `anfs.local.env` moves it to `--debug`
- `~/.config/anfs/anfs.env` — anfs's settings (`ANFS_*`, Homebrew's), linked from core/anfs (see
  Configuration); `~/.config/<tool>/<tool>.env` each tool's, linked from its package
- `~/.config/<tool>/<tool>.local.env` — this machine's values (yours, never shipped)
- `~/.local/state/ppm/installed/<repo>/<pkg>.yml` — per-package install tracker (version, timestamp, linked `files` — a directory link is one —, `links` out of the tree, `installed_deps`, `resources`)
- `~/.local/state/ppm/installed/callbacks.yml` — packages registered for post-run callbacks (`ppm_register_callback`)
- `~/.local/state/ppm/installed/protected.yml` — files `ppm file protect` detached from ppm; seeded into the installer's skip list so they are never re-linked
- `~/.local/state/wsm/backup/` — what `wsm install -f` moved aside; wsm's only state (what is installed is read off the links)
- `~/.local/bin/<tool>` — each stowed from its package (`core/anfs`, `core/ppm`, `core/pcm`, ...)
- `~/.config/sh/*.sh`, `~/.config/zsh/*.zsh`, `~/.config/bash/*.bash` — package-contributed shell snippets (see Shell Integration). `ppm.*` and `mise.*` come from `core/ppm`, `anfs.sh` from `core/anfs`
- `~/.local/lib/anfs/` — what every tool sources (paths, sources, resolve, link, manifest, files,
  platform): one link into `core/anfs` (`links: [.local/lib/anfs/]`), so a pulled library is there
  at once. `~/.local/lib/{pcm,pmm}` are directory links too; `~/.local/lib/ppm` stays per file
  (other packages write there)
- `~/.local/lib/ppm/*.sh` — ppm's own libraries (stowed from `core/ppm`) plus package-contributed library extensions. Extensions add helpers for hooks (e.g. `stack/ruby`'s `install_gem`) or, for now, commands: a function named `cmd_foo`, registered with `cli_cmd`, becomes `ppm foo` (anfs-dev/dev's `ppm user`; new commands are `~/.local/bin/anfs-<name>`, run as `anfs <name>`)
- `~/.cache/ppm/brew_last_update`
- `~/.local/state/pcm/containers/<name>/state.env` — what pcm recorded for a container (the tunnel token)
- `~/.local/state/pmm/ssh_config` — pmm's running machines for ssh, included by `~/.ssh/config.d/05-pmm.conf`
- Each tool keeps its own files in its own XDG dirs, each kind where "Where files go" says:
  `$XDG_{CONFIG,DATA,STATE,CACHE}_HOME/<tool>`

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
- **Every `cd` goes through `_anfs_cd`.** A tool's `cd` is a wrapper in its own `sh/<tool>.sh`
  (portable, never a `.zsh`) that calls `_anfs_cd [-s WORD] TOOL DEFAULT ARG...` from
  `sh/anfs.sh`: it runs `TOOL [WORD] path ARG...`, cds on exit 0 or 3 (stale, path still
  printed), returns any other status without moving, and with no ARG cds to DEFAULT (or, when it
  is empty, asks `path` with no arguments). The binary's `cmd_cd` only says the function is
  missing. Wrappers look `_anfs_cd` up at call time, so sourcing order does not matter.
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
  `post_remove` restores it); otherwise the install stops on it and `-f` would move it aside. Note
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

- `ppm install git` installs every `git` package in source order (e.g. `user/git`, then `stack/git`). The layers share one skip list (`PPM_SKIP_FILE`, exact paths), so files linked by a higher-priority layer are skipped by lower ones. This lets personal repos override individual files.
- `ppm install stack/git` installs only that layer. Files a higher layer linked are the plan's `other` (a live link into another package), so the install stops on them; this is intended.
- `core` is last in `system.list`, so every other source may layer over its packages and depend
  on what it ships (`depends: [node]` resolves to `core/node`).

## Linking (lib/anfs/link.sh)

ppm, wsm and `install.sh` put files in place with one library, `lib/anfs/link.sh` (GNU Stow did
it before). It knows nothing about packages or spaces: it links a list of files from one
directory into another, skipping a set, and says who a link points into.

- **A link is per file and relative**, exactly what `stow --no-folding` wrote
  (`~/.local/bin/ppm -> ../../.local/share/anfs/sources/core/packages/ppm/home/.local/bin/ppm`), so
  an install stow made is taken over with no link rewritten, and `stow -D` still undoes one.
  Directories on the way are real; a directory on the way that is a link is followed only when it
  resolves inside the target **and not into the sources** (a directory link: a path through it
  would write into a source's checkout, so it is a `conflict`, `inside a directory link: <owner>`,
  never cleared; `anfs_unlink` never removes through one either).
- **A path in a list may be a directory** (a directory link): planned, applied, checked and
  unlinked as one link. A real directory there is a `conflict` (`a directory`, or `a directory,
  with links into another package: <owner>` when it holds any, which ppm's `-f` does not clear).
- **Relative everywhere, absolute only across `/`**: `anfs_link_text <link-dir> <target>` (both
  canonical) is the relative path, or the target itself when the two share only `/` (a source on
  another volume). The plan's and the check's texts follow it. Every link ppm, wsm and ovm make
  goes through `link.sh` (`anfs_link_one` refuses when anything is at its path, a link or a
  directory included).
- **Links out of a tree**: `anfs_link_src_state <link> <src>` (`ok` whether relative or absolute,
  `missing`, `missing src`, `wrong`, `in the way`) and `anfs_unlink_src` (only while it still
  resolves to `src`), shared by ppm's and wsm's `{src}` entries.
- **`lib/anfs/manifest.sh`** reads `links:`, `files:` and `platforms:` of any number of
  `package.yml`/`space.yml` in one yq (`anfs_manifest_read`) and plans one for a platform
  (`anfs_manifest_plan` → `ANFS_MF_LINKS`, `_SRCS`, `_COPIES`, `_OFF`, `_DIRS`, `_ERR`);
  `anfs_manifest_match` is how platforms match. **`lib/anfs/files.sh`** is real files in a target:
  copy-if-missing (`anfs_files_plan`/`_apply`: `missing`, `present`, `differs`, `in the way`,
  `skip`; a copy is moved into place only if nothing appeared meanwhile), and the home of linker
  plan 03's file operations.
- **A plan, then the links.** `anfs_link_plan` classifies every file, one `<class>\t<path>[\t<detail>]`
  line each: `link`, `keep` (a relative link to this file), `replace` (a link into `<from>`
  that is absolute or points at another of its files, or a dangling link into the sources),
  `skip` (the skip set, and `.DS_Store`: the only name the library skips itself), `other` (a live
  link into another directory of the sources: another layer's; detail is its owner) and
  `conflict` (a file, a directory, a link elsewhere). `anfs_link_apply` changes nothing unless
  the plan has no `other` or `conflict`; it returns 1 and the caller decides: ppm moves them
  aside under `-f` (`stow_package`), and so does wsm (`_backup`); without `-f` both refuse. Every
  file in the way is reported, not the first.
- **`anfs_link_check <from> <to> <files-file>...`** is the read-only side: `<state>\t<file>` per
  file, `ok` (the text apply writes, or any link that resolves to the file), `missing`, `wrong` (a
  link to anything else), `in the way` (a file, a directory, or an obstacle on the way). It takes
  several triplets at once (wsm checks every source in one call) and leaves the states in
  `_ANFS_ST` too. A constant number of forks however many files: tests in the shell, the expected
  text built as apply builds it, every link's text read with one `readlink`, and only a link whose
  text differs resolved. wsm's whole state is this.
- **No fork per file anywhere in the library**: a path is resolved by `cd -P` in the shell and
  back (`_anfs_link_physical`), and `anfs_link_apply` makes a directory's links with one `mkdir`,
  one `rm` and one `ln -s` (a link made into a directory is named for its text's last part).
- **Names are data**: spaces, `+`, `(`, `[`, a leading `-`. A name with a newline or a tab is
  refused (exit 2), once. Paths are compared canonical (macOS's `/var` is `/private/var`).
- **`anfs_link_owner <path>`** is the one answer to "is this ours": `<source>/<path in it>` for a
  link into `$ANFS_SOURCES_HOME` (live or dangling; a local-path source by its alias), else 1.
  ppm's implode sweep uses it.
- **`ppm install -n`** prints each layer's plan (and what `-f` would do with what is in the way)
  and changes nothing: no pull, no brew, no hooks, no links, no tracker. It exits 1 when the
  install would stop. Hooks do not run, so a `pre_install` that moves a file aside (stack/bash's
  `.bashrc`) shows as a conflict.
- ppm and wsm source `~/.local/lib/anfs/{platform,link,manifest,files}.sh` and nothing else: the
  directory is one link, so there is no fallback to the clone.
- Tests: `packages/anfs/tests/link.bats` (the library, under `/bin/bash` too; the stow comparison
  skips without stow), `manifest.bats`, `files.bats`, `packages/ppm/tests/backup.bats`,
  `plan.bats` and `manifest.bats`, `packages/wsm/tests/links.bats`.

## Your Customization Repo

The alias `user` (`PPM_USER_REPO_ALIAS` in `core.sh`) is always your own repo:

- `anfs onboard` (its `repo` step, `lib/anfs/onboard.sh`) creates it locally: `git init` at `~/.local/share/anfs/sources/user`, an `anfs` package holding `user.list` (listing the repo itself, as a local path), registered at the top of `user.list`, then `ppm install -f user/anfs` swaps the plain `user.list` for a link into the repo. `--repo <url>` does what `install.sh --repo` does; `--repo new` is `local` plus stack/git's `publish` step creating it on GitHub and rewriting the `user` line to that URL. This replaced `ppm customize`.
- `anfs onboard [--check] [step...]` is the whole walk from a fresh install, and it is extensible: anfs owns only the runner and two steps, `packages` (what the sources offer and is not installed) and `repo`. Every other step belongs to an installed package:
  - **Declared** in `package.yml` under `onboard:` (a key ppm owns): `offer` (one line, read while the package is *not* installed, so no code of a package you did not choose ever runs), `steps` (`name`, `summary`, `after`, `before`; names nobody has are ignored, so they never require another package) and `options` (the spec strings `cli_cmd --opt` takes; read from every source's packages when the line is about onboard, so `--install op --vault Dev` works in one go).
  - **Implemented** in the package's `install.sh` as `onboard_<step>_detect` (true when done, no side effects: it is all `--check` runs) and `onboard_<step>` (detect, then apply). The contract and the helper functions (`onboard_get/set`, `onboard_opt`, `onboard_detail/state`, `onboard_propose/confirm/ask/choose`, `onboard_user_repo`, `onboard_commit`) are in `lib/ppm/onboard.sh`.
  - **Run** by `ppm __onboard <repo/pkg> <function>`, one process per call, so steps share what they learn through a facts file that lasts for the run. Exit 0 is done, 1 is not done, anything else ends the walk (64: a question no option answered).
  - Nothing is recorded: a rerun does only what is missing. `-y` takes proposals but never installs an offer, authorizes a key, picks a vault or publishes a repo; those need their option.
  - `stack/git` (identity, github, publish), `stack/ssh` (key, access) and `stack/op` (pm, pm-key, pm-github) are the first to use it. Tests: `packages/anfs/tests/onboard.bats` (the runner, with a fixture source) and stack's `packages/git/tests/onboard.bats` (those steps, with `gh`, `op` and `ssh-add` stubbed).
- Its `anfs` package is a layer of `core/anfs`, so files it ships win over the toolkit's defaults: its `user.list`, and an `anfs.env` of its own if it wants one (it replaces core's whole; a machine's values belong in `anfs.local.env`, a tool's in `~/.config/<tool>/<tool>.local.env`).
- `install.sh --repo <url>` registers that URL as `user` and installs `user/anfs` with `-f`.
- `ppm file claim` defaults to it.
- Local-path sources are never pulled: after pushing it, set the `user` line in `user.list` to the git URL.

## Homebrew Ownership

Homebrew supports one owner per installation (`/opt/homebrew` on Apple silicon macOS, `/home/linuxbrew/.linuxbrew` on Linux; Intel Macs are not supported). The user who installed it owns it and is the only one who installs, updates or upgrades formulas. Other users on the machine run the tools but never write to the prefix. ppm puts brew on PATH itself (`brew_env`), skips `brew update` for non-owners, and uses `brew_require_owner` to tell a non-owner which command the owner has to run.

## Claiming and Protecting Files

Three levels of ownership for an individual file: ppm owns it (default), *you* own it in
*your repo* (`claim`), or *you* own it locally with ppm detached (`protect`).

- `ppm file claim <file...> [--repo REPO] [--package NAME]` copies files into `REPO/NAME/home/` and links them from there (`anfs_link_one`, that file only). The default repo is `$PPM_DEFAULT_REPO` (default `user`, settable in `ppm.local.env`). The default package has the same name as the owning package. A new package with a different name gets `depends: [<owner>]`.
- `ppm file add <repo/package> <file...>` is `claim` for files no package owns yet (`ppm file claim <file...> --package repo/package`; `--package` accepts that form everywhere). The target is mandatory and the package is created if missing. Directories are refused: pass `dir/*` and let the shell expand it, so exactly the named files move. Directories are always real with a link per file, so files a tool creates there later stay local until added too.
- **Never put a space in a package**: a space is a directory with a `space.yml` under a source's `spaces/`, and wsm links it into `WSM_SPACES_HOME` (and implode unlinks it). A space stowed by ppm would be files no tool can remove. Files in a wsm tree go into the source with `wsm add`, not `ppm file add`.
- Protected files are refused by `claim`/`add` (unprotect first): claim would link them again.
- A path inside a directory link (`~/.local/lib/anfs/x.sh`) is refused by `claim`, `add` and
  `protect`: it is a file of the source itself ("inside core/anfs's directory link
  ~/.local/lib/anfs").
- `ppm file reset <file...>` deletes the claimed copy, restores the owner's link, and removes the claimant package if it becomes empty.
- `ppm file protect <file...>` turns a package-managed symlink into a plain local copy (preserving its content) and records it in `protected.yml`. ppm then never re-links or force-removes it — including under `-f` — so you can customize it without a repo. The file is also dropped from its package's tracker.
- `ppm file unprotect <file...>` removes it from `protected.yml`; the next `ppm install -f <package>` re-links it.
- Claims are recorded in `~/.local/state/ppm/installed/claims.yml` (file → claimant, owner); protections in `~/.local/state/ppm/installed/protected.yml` (a plain list of `$HOME`-relative paths). The per-package trackers are updated to match.
- None of these touch git. Commit the changes in the repo yourself.
- `ppm install -f` never deletes a file of yours. `stow_package` (`installer.sh`) deletes only a link into the sources (the plan's `other`); anything else in the way (`conflict`) is moved to `~/.local/state/ppm/backup/files/<path>` and recorded in `backup/manifest` (`repo/pkg<TAB>path`). `ppm remove` of that package puts it back (`_backup_restore`, skipped by a reinstall), and `ppm implode` restores whatever is left before it deletes the state dir, beside the path as `<path>.pre-ppm` when the path is taken. The first backup of a path is the pre-ppm original and is never replaced. `packages/ppm/tests/backup.bats`.

## Moving a resource between sources (lib/anfs/move.sh)

```
ppm move stack/rails user          # a package
wsm move lgat/tech/web rws         # a space, and the spaces under it
<tool> move <source/name> <to-source> [-n] [-f]
```

A resource's directory (`<dir>/<name>`: `packages/rails`, `spaces/tech/web`) moves to another
source **with its history**, as commits, and one commit in the origin removes it. **A move
commits, by design** (history is commits): it is the one place the toolkit commits on the
person's behalf. It never pushes, and leaves both repositories clean, or as they were when it
fails. `-n` prints the checks, the commits that would be replayed (and whether the replay works),
and the tool's own steps; it changes nothing.

**The tool orchestrates; the library supplies building blocks**, with no hooks or callbacks. A
tool that has a move declares it with `anfs_move_cli <noun> <arg-kind>` (the same help, `-f` and
`-n` everywhere) and writes its own `cmd_move`, which reads top to bottom with its own functions
around the two others. A tool without a `cmd_move` has no move (pcm, pmm and psm: linker plan 06).

- **`anfs_move_check [-f] <dir> <id> <to> [deps-fn]`** prints one line per check,
  `<state><TAB><check><TAB><detail>` (`ok`, `refused`, `forced`, `note`); 0 go on, 1 refused (`-f`
  would go on), 2 refused whatever the flags.
  - Always refused: a bare name (it is a layer in every source; `<id>` is `<source>/<name>`), a
    resource the origin does not have (or without its marker), the same source, a destination that
    is not a configured source or has no clone, a source that is not a git repository (a local
    directory has no history to carry), **the path in the destination** (there, tracked, or a file
    on the way: `-f` never overwrites a source), either repository in the middle of an am, rebase,
    merge, cherry-pick or revert, on no branch or with no commit, and **uncommitted or untracked
    changes inside the resource's own path** (what moves is what is committed).
  - Refused unless `-f`: other uncommitted changes in either repository (the commits still hold
    only the path); **dependents** that resolve it now and would not after (the rule is
    `resolve.sh`'s: a dependency resolves from the depending source's position down, so moving
    *up* hides it from the dependents below its new place, and one named `<from>/<name>` never
    resolves again); **its own dependencies** that would not resolve from the destination's
    position down (moving *down* can lose them); a `stacks/*/stack.yml` in any source naming
    `<from>/<name>`. Each with the file that says so. Nothing is rewritten.
  - Notes: the layers before and after (a kind that layers), which source a bare name finds
    after (`ANFS_RESOLVE_FIRST`), the branches the commits land on, and that nothing is pushed.
  - Positions are in the whole source order: the destination may not hold `<dir>/` yet.
    `deps-fn` is what the tool gives `anfs_resolve` (`meta_depends`, `_space_deps`); without it
    the dependency checks are skipped and said. A nesting kind (`ANFS_NAME_NEST`,
    `ANFS_RESOLVE_MARKER`) moves a resource with every one under it.
- **`anfs_move_tree [-n] <dir> <id> <to>`**: `ANFS_MOVE_METHOD` (`replay` or `copy`),
  `ANFS_MOVE_COMMITS`, `ANFS_MOVE_WHY`; one line at the end (`moved packages/rails: stack -> user,
  10 commits replayed`); 0, or 1 with both repositories as they were.
  1. `git format-patch -k --root HEAD -- <path>`: every commit that touched the path, cut down to
     it (merges are skipped).
  2. **A trial in a scratch repository**, then a **verification**: the path's tree equals the
     origin's, and every replayed commit's author, author date and whole message equal the
     origin's (`git log --no-merges -- <path>`). Only a replay known to work touches the
     destination. The am flags, each for a reason found on real history (2026-10-22: 92 of 93
     resources replayed exactly): `-k` (a `[wip]` subject keeps its brackets), `--keep-cr` (CRLF
     files), `--whitespace=nowarn` (no warnings, and no one's `apply.whitespace=fix`), `--no-3way`,
     `--committer-date-is-author-date` (the committer is whoever moves it; the dates are the
     author dates), `--no-verify` (no applypatch hooks: the history was judged where it was made),
     `--no-message-id`.
  3. Into the destination: the same am, verified again; on any failure `git am --abort`, `git
     reset --keep` to the recorded HEAD, then the copy. A staged change there (`-f`) skips the
     replay (`git am` needs a clean index). **The copy**: exactly what is committed (an index of
     its own, `read-tree` and `checkout-index`: modes and links kept, no export attribute), one
     commit `<path>: moved from <from>` naming the origin's URL and SHA, where its history is, and
     why it was not replayed. What fails a replay: merged parallel branches that linearise into a
     conflict (user/claude's history), a message holding a `diff --git` line (am refuses it) or a
     `---` line (am cuts it silently: the verification catches it).
  4. Out of the origin: `git rm -r` and one commit `<path>: moved to <to> (<method>, <sha>)`
     limited to the path. The copy and this commit run the repository's hooks (the version bump),
     and the path is added again after them. If this commit fails, both are put back. What the
     origin ignores in the directory (`.DS_Store`) goes to the destination, so nothing left at the
     old path resolves as a resource.
- **ppm** (`lib/ppm/move.sh`): `core/anfs` and `core/ppm` refused without `-f`; every link the
  tracker lists must still be the package's (`anfs_link_plan` says `keep`), else nothing changes
  (`ppm install -f`, or `ppm file protect`, first); the tracker's files unlinked (no remove hooks;
  `links: {src}` links point outside and stay; copies are the user's); the tree; the tracker moved
  unchanged to `installed/<to>/`; the same files linked from the destination (a higher layer's and
  protected files left alone); then claims (claimant, owner), the callback registration and the
  backup manifest's owner renamed. No install hook, no mise, no resources: only the place changed.
- **wsm** (`cmd_move`): a space and every space under it (a source's root space is refused: move
  the spaces under it). Besides the check, refused: the place under the root taken, a moved space
  with `wrong`, in-the-way or leftover links (`wsm install -f` first), and unless `-f` a relative
  `links:` src or `skills:` repo that leaves the moved directory. Then the tree; when installed, the
  directory under the root moves in one rename (the clones, the copies and the user's files with
  it), the links are made again from the new source (a link dangling into the sources is the plan's
  `replace`), local-path skills are installed again from it, `git worktree repair` runs in each
  clone with linked worktrees (`anfs work`'s), and the events are `remove` with the old ids and
  `install` with the new (an ovm vault link naming the old id is then `unknown`: said). Ids are
  never rewritten.
- `anfs mv <source/name> --to <source>` (linker plan 03) will only run the owning tool's `move`.

## Dependencies

- `yq` (mikefarah/yq) — for YAML parsing of package.yml and tracker files
- `git` — repo cloning and updates

Links are made by the toolkit itself (`lib/anfs/link.sh`); GNU Stow is not needed. A machine that
has it keeps it: nothing uninstalls the formula, and `stow -D` still undoes a package (the links
are the ones it wrote).

## Running a job's code: ANFS_WORK

`ANFS_WORK=<job> <tool> ...` runs a job's copy of the tool (`~/work/<job>/`, anfs-dev's `anfs
work`), with the job's libraries, on **live data**: this machine's sources, settings, state and
machines. It is how a person tries a branch before it merges (`ANFS_WORK=config-03 pcm list`);
anything the command changes, it changes for real. Tests never use it: they run a checkout's
code by path under a temp `HOME`, and `anfs work run`/`env` and every test helper unset it.

- **The preamble**: every entry script's first line after `set -euo pipefail` (a comment above it
  says what it is), before `bash.sh`, so it runs under macOS's 3.2:

  ```bash
  [ -z "${ANFS_WORK:-}" ] || [ ! -f "$HOME/.local/lib/anfs/work.sh" ] || . "$HOME/.local/lib/anfs/work.sh"
  ```

- **`lib/anfs/work.sh`** (bootstrap set): only the copy run as `~/.local/bin/<tool>` hands over
  (`$HOME` as given or canonical), so a job's copy, a test's or a checkout run by path never does:
  no loop, no marker. The job is `${ANFS_WORK_HOME:-~/work}/$ANFS_WORK` with a `.job.yml`; none, or
  a name with a `/` or a leading dot: `anfs: no job <job> in ~/work (anfs work list)`, exit 64. The
  copy: the installed link's text reads `.../sources/<alias>/<rest>`, the copy is
  `<job>/<alias>/<rest>` when the job has that worktree and the file; then `exec`, arguments
  intact. No copy: the installed tool goes on. `anfs: running job <job>` once per run on stderr
  (`ANFS_WORK_SAID` is exported so the tools it runs stay quiet), copy or not.
- **Libraries** (`paths.sh`): the installed `paths.sh`, under `ANFS_WORK`, sources the job's copy of
  itself and returns, so `ANFS_LIB_DIR` (the directory of the `paths.sh` that ran) is the job's
  `lib/anfs` when the job has core. A tool sources `bash.sh` and `paths.sh` by their literal
  installed path and everything else from `$ANFS_LIB_DIR`. Its own library directory is
  `anfs_lib_dir <name>` (pcm, pmm, stack's tsm): the job's copy of the directory link
  `$ANFS_LIB_ROOT/<name>`, else the installed one. `lib/ppm`, filled file by file by three packages,
  is `anfs_lib_files ppm`: each installed file or its job copy, then the files only the job has.
- A tool the job does not have runs as installed, with the job's `lib/anfs` when the job has core.
- **Environment only**: `ANFS_WORK`, `ANFS_WORK_HOME` and `ANFS_WORK_TMP` in a settings file are
  ignored with a warning (`anfs_conf_env_only`).
- A new entry script starts with the preamble (`packages/anfs/tests/work.bats` holds core's, and
  stack's, anfs-dev's and user's `pjm` when they sit beside core).

## Development

Plans are in [anfs-io/docs](https://github.com/anfs-io/docs) (`units/`, cloned in the `anfs`
wsm space). Follow the Chorus methodology:
1. Read the unit `.md` for objectives
2. Read the plan's `plan.md` for implementation spec
3. Implement and test
4. Write `log.md` on completion

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
               # every entry point; bash 3.2, like link.sh
  work.sh      # ANFS_WORK=<job> (bash 3.2, bootstrap set): the entry scripts' preamble sources it;
               # anfs_work_handover, anfs_work_job, anfs_work_map/anfs_work_where. See "Running a
               # job's code: ANFS_WORK"
  link.sh      # the linker (bash 3.2, in the bootstrap set): anfs_link_plan / anfs_link_apply
               # (<from> <to> <files-file> [skip-file]), anfs_link_check, anfs_unlink, anfs_unlink_tree,
               # anfs_link_one, anfs_link_owner, anfs_relpath, anfs_link_text, anfs_link_src_state,
               # anfs_unlink_src. See "Linking" below
  manifest.sh  # links:, files:, platforms: of a package.yml or space.yml (bash 3.2, bootstrap set; yq):
               # anfs_manifest_read, anfs_manifest_plan, anfs_manifest_match
  files.sh     # real files in a target (bash 3.2, bootstrap set): anfs_files_plan / anfs_files_apply,
               # copy-if-missing; the file operations of linker plan 03 go here
  platform.sh  # platform() (macos/debian/fedora) and os() (macos/linux), bash 3.2, bootstrap set
  log.sh       # anfs_info/warn/die/fail/debug, the log file (anfs log), ANFS_DEBUG, ANFS_TRACE
  callbacks.sh # anfs_callback_register/unregister, anfs_callbacks_run (emit), anfs_callbacks_ls
  catalog.sh   # the definitions of one kind across the sources (pcm's services, pmm's images):
               # catalog_load, catalog_canon, catalog_all_ids
  events.sh    # the event log: space ids (anfs_space_id_new/_read/_write), anfs_emit (one CloudEvent
               # per line in STATE, built by _anfs_ev_envelope only), anfs_events_space_at/_named, and
               # events ls (anfs_events_cli, anfs_events_ls; read through _anfs_ev_parse only). anfs
               # and wsm source it. See "Events"
  service.sh   # a user's long-running service: a launchd agent or a systemd user unit, written (absolute
               # paths, PATH, HOME), loaded, stopped, removed, asked (anfs_service_*; ANFS_SERVICE_OS for
               # tests). The bus's two; listener.sh (socket-activated) stays as it is
  pins.sh      # pinned release binaries: anfs_pin_read/_fetch (pins.yml; sha256 checked; CACHE, then
               # DATA), anfs_pin_link/_unlink (~/.local/bin). core/nats and core/anfsd
  bus.sh       # the bus's definitions, shared by core/nats's and core/anfsd's hooks and anfs bus: the
               # service specs, NATS's users and server.conf (anfs_bus_nats_*), anfsd's binary
               # (anfs_bus_anfsd_bin: ANFSD_BIN or the release). See "The bus"
  report.sh    # anfs report (anfs_report_cli: new, diag, check, status, show, close, wait, and the
               # __sink plumbing): the issue with its diagnostics, filed where ANFS_REPORT_TO says (a
               # file report's record in STATE, the file a view of the records), and followed to its
               # fix. See "Reporting a bug: anfs report"
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
  paths.sh     # ANFS_* paths, anfs_tool_paths <tool> (<TOOL>_{CONFIG,DATA,STATE,CACHE}_HOME, then
               # the tool's settings), the settings: anfs_load_conf [tool] (<tool>.local.env, then
               # <tool>.env; the environment wins; anfs's when sourced), anfs_conf_read <file>,
               # anfs_conf_files <tool>, anfs_conf_expand <value> (a leading ~), anfs_conf_env_only <name>,
               # ANFS_CONF_LOADED (the names it exported).
               # ANFS_LIB_ROOT (~/.local/lib, the one place it is written), ANFS_LIB_DIR (the lib/anfs
               # the rest is sourced from), anfs_lib_dir <name>, anfs_lib_files <name> (lib/ppm); under
               # ANFS_WORK it hands over to the job's paths.sh first
  config.sh    # the `config` group (Configuration): anfs_config_declare (cmd_config_list/get/set/
               # unset, complete_setting, complete_assignment), anfs_config_rows <tool>. A tool that
               # ships <tool>.env calls it among its declarations; stack's tools when core has it
  skill.sh     # agent skills through the skills CLI (npx skills@$ANFS_SKILLS_CLI_VERSION) with a
               # scope, -g or a directory: anfs_skill_cli, _require, _agents (ppm's meta.agent),
               # _package_agents, _display/_id, _dir_skills, _load, _has, _status, _sync_rows,
               # _remove (never unscoped: -a for the agents a skill is on, then the shared
               # .agents/skills copy and lock entry; an unscoped remove sweeps ~/agent/skills/<name>,
               # a project's skills/<name>), _remove_for, _unlink. psm runs it with -g, wsm with a
               # space's directory
  move.sh      # a resource to another source with its history: anfs_move_check, anfs_move_tree,
               # anfs_move_cli (see "Moving a resource between sources"); the one place that commits
  repo.sh      # one clone at one path: anfs_repo_name (the directory git clone would make),
               # anfs_repo_clone <url> <dir> [ref], anfs_repo_status, anfs_repo_ahead,
               # anfs_repo_dirty, anfs_repo_update (pull; 2 when dirty), anfs_repo_ssh_url,
               # anfs_repo_ssh, anfs_repo_push <dir> [-n] (plain git push of the current branch;
               # its outcome as the exit status). No policy, no messages: anfs src and wsm repo
               # keep theirs, except anfs_repo_push_cli, the push command both share (names or
               # --all, -n, the list, the exit status; the caller fills ANFS_PUSH_IDS/_DIRS)
  sources.sh   # gitsrc_*: source lists, the TTL and marks, linking local paths, provides, the
               # `src` command, over repo.sh (which it sources from where it really lives, its
               # link resolved: every tool that sources sources.sh has it, and a pull that brings
               # repo.sh works before core/anfs is installed again); anfs_gitsrc_env points it at
               # anfs's lists
  cli.sh       # the command line: cli_cmd / cli_group declarations, and from them help, the
               # check of the line (CLI_OPT), `__complete`, cli_call, anfs_confirm
  resolve.sh   # anfs_sources <dir>, anfs_find, anfs_list, anfs_resolve <dir> <deps_fn> (layered
               # topo sort with the same-or-lower-priority dependency rule; ANFS_RESOLVE_FIRST for
               # kinds that don't layer; ANFS_NAME_NEST for names that nest to any depth, the
               # first segment the source when it is one, and ANFS_RESOLVE_MARKER for the file a
               # resource directory must hold: wsm's spaces, lgat/tech/web and the root lgat)
packages/ppm/home/.local/lib/ppm/
  core.sh        # API for package hooks: arch(), add_to_file(), remove_from_file(),
                 # debug(), user_message(), ppm_fail() (os() and platform() are lib/anfs/platform.sh's)
  platform.sh    # system_pkg_*() (apt/dnf), _system_sudo(), brew_prefix(), brew_env(), brew_owner(),
                 # brew_is_owner(), brew_require_owner(), update_brew_if_needed()
  sources.sh     # collect_repos() (the sources holding packages/), update_ppm_if_needed()
  packages.sh    # list, show, path, deps; collect_packages(), find_package_dirs() and resolve_deps()
                 # (over resolve.sh), package.yml reads, install trackers
  installer.sh   # install (and install -n), remove; install_single_package(), remover(),
                 # stow_package() (the manifest, one plan over links, copies and links out of the tree,
                 # -f, then all of them), plan_package() (-n), unstow_package(),
                 # PPM_SKIP_FILE, _backup_file(), _install_declared_resources()/
                 # _remove_declared_resources(), _reload_stowed_libs()
  file.sh        # file claim|reset|protect|unprotect (file_command), claims.yml, protected.yml
  move.sh        # move: cmd_move over lib/anfs/move.sh (unlink, tree, tracker, relink, renames)
  implode.sh     # implode: every installed package removed, dependents first, then ppm's dirs
  completion.sh  # completion
```

Rules for `lib/anfs`: it only defines functions (and paths.sh its variables), depends on no tool, takes its configuration from its own variables (`GITSRC_*`),
and runs under `set -euo pipefail`. Every tool sources `bash.sh` and `paths.sh` from
`~/.local/lib/anfs`, by that literal path, and the rest from `$ANFS_LIB_DIR` (the job's under
`ANFS_WORK`); nothing else names `~/.local/lib`.

**The bash floor is 5.2.** The tools and `lib/anfs` are written for it: associative arrays,
`mapfile`, namerefs. macOS ships 3.2 and always will, so `lib/anfs/bash.sh` is what makes the
floor true there, and every entry point sources it first, at top level, before anything else
(only the `ANFS_WORK` preamble comes before it):

```bash
source "$HOME/.local/lib/anfs/bash.sh"
```

- Under 5.2 or newer it does nothing. Under an older bash it re-execs the script with a newer one
  found **by path** (`$HOMEBREW_PREFIX/bin/bash`, `/opt/homebrew/bin/bash`, `/usr/local/bin/bash`,
  linuxbrew's), or exits 69 saying how to get one. Never `command -v bash`: the reason the guard
  exists is that PATH puts `/bin` first in nested login shells and non-interactive ones (see Shell
  Integration), so `env bash` finds 3.2 on a machine that has 5.
- An entry point is anything that starts its own bash process: the five tools, pcm's edge
  providers (`lib/pcm/edges/*`), pmm's provisioners (`lib/pmm/provisioners/*`), the `pre-commit`
  hook. A library a tool sources needs no guard,
  and neither does a package's `install.sh`: ppm sources it, so it runs under ppm's bash.
- `anfs` and `ppm` source it only if it exists, a leftover of when `lib/anfs` was linked file by
  file. It is one directory link now (core/anfs's `links:`), so a pulled library is there at once.
- **The bootstrap set stays on 3.2**: `install.sh`, the four ppm libraries it sources
  (`PPM_BOOTSTRAP_LIBS`: `core.sh`, `platform.sh`, `file.sh`, `installer.sh`), lib/anfs's
  `platform.sh`, `link.sh`, `manifest.sh` and `files.sh` (`ANFS_BOOTSTRAP_LIBS`), `bash.sh`
  itself and `work.sh` (the preamble's, which runs before `bash.sh`).
  They run on a vanilla Mac before Homebrew's bash exists, so no bash 4+ syntax in them. Each says
  so in its header, and `packages/anfs/tests/bash.bats` parses them under `/bin/bash`. They may
  call functions from bash 5 libraries, as long as that only happens once the real `ppm` runs.
- Code that predates the floor (wsm, ppm's `packages.sh`, pmm's `image.sh`) still uses parallel
  arrays. Convert it when it is next changed, not for its own sake.
- **Do not run `ppm install -r core/anfs`**. `-r` removes the package first, which unlinks
  `lib/anfs`, and ppm cannot run without it to put it back. A new `lib/anfs` file needs no install
  at all: the directory is one link.

**Every tool's command line is `cli.sh`'s**: see "The Command Line" above. An extension declares
its commands where it defines them: `anfs-dev/dev`'s `container.sh` calls `cli_group container` and
`cli_cmd "container up" ...` next to `cmd_container_up`.

Library sourcing in `ppm`: every `*.sh` in `$PPM_LIB_DIR` (`~/.local/lib/ppm/`) is
sourced (`anfs_lib_files ppm`: under `ANFS_WORK`, the job's copies). That directory holds both ppm's own core libraries (stowed from `core/ppm`)
and package-contributed extensions (e.g. anfs-dev/dev's `container.sh` and `vm.sh`). During a fresh
install `install.sh` sources the core libs directly from the clone and stows `core/anfs` and `core/ppm`
so they are present before `ppm` first runs.

### Testing

Unit tests are bats, no network (local bare repos over file://). The whole set, several files at
once, is `packages/anfs/tests/all` (about 30 s); while working, run only the file you touch.

**pmm's and pcm's suites are off until further notice** (2026-10-19): too slow to run on every
change. Their helpers skip every test and `tests/all` leaves them out; the person runs them by
hand with `ANFS_TESTS_PMM_PCM=1` (ROADMAP.md, "Last"). Agents do not turn them back on.

```
bats packages/anfs/tests     # lib/anfs: paths.sh's settings (conf.bats; settings.bats: each tool's <tool>.env
                             # documents what it reads), sources.sh, repo.sh, skill.sh, resolve.sh, link.sh, manifest.sh, files.sh,
                             # bash.sh (the floor, the bootstrap set),
                             # log.sh, callbacks.sh, table.sh, cli.sh (registry.bats), anfs callbacks/log,
                             # move.sh (move.bats: fixture repositories, bare remotes over file://),
                             # report.sh (report.bats: gh, podman and npx stubbed; no network),
                             # events.sh (events.bats: emit, ls, follow; ANFS_EVENTS=on per command)
                             # Run bats with </dev/null: pmm's ssh stub reads stdin, and a test
                             # run that inherits an open one waits on it forever
bats packages/ppm/tests      # ppm: callbacks, meta, linking and -f's backups, install -n, links:/files:/platforms:,
                             # brew update's interval (brew.bats), ppm move (move.bats)
                             # (manifest.bats: platform, brew and mise stubbed)
bats packages/pcm/tests      # pcm: sources, validate, remove
bats packages/psm/tests      # psm: skills from sources, install, implode, ANFS_SKILLS_CLI_VERSION (skills CLI stubbed)
bats packages/nats/tests     # core/nats's hooks: pins (curl serves fixtures), STATE, server.conf, the service (stubs)
bats packages/anfsd/tests    # core/anfsd's hooks (the release or ANFSD_BIN), anfs bus (curl, launchctl,
                             # systemctl stubbed: status rows, start/stop/restart, logs, nats --) and
                             # anfs agents (agents.bats: fixture runs, a stub anfsd, a process group the
                             # test starts for stop; PATH holds no harness)
bats packages/wsm/tests      # wsm: install (spaces at any depth, ownership, specs, dependencies, the root, -f,
                             # repositories), the state (ls), path/remove/new/add/repo/implode, events,
                             # links: (links.bats), skills: and wsm skill, the ppm callback (skills.bats,
                             # npx stubbed: it logs its cwd), wsm move (move.bats), space ids and
                             # wsm events ls (ids.bats; space_def writes an id unless NOID=1)
bats packages/pmm/tests      # pmm: images (sources, templates, validate, qemu argv, build, provisioners, list,
                             # what is on a build), machines (sources, profiles, validate, run/up/exec/snapshots/reset/
                             # remove, the macOS limit, media), networks and interfaces. qemu, ssh, tart
                             # and virsh are stubbed, and PMM_SOCK_DIR is the suite's own
```

The end-to-end round trips (Linux in a podman box, macOS in a tart VM), their harness, the `acme`
fixture and the test boxes are in the anfs-dev source (`packages/dev/tests/`, `containers/`, `machines/`; its AGENTS.md).

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
- tart allows two macOS guests in all: anfs-dev's `roundtrip-macos` takes `$ANFS_STATE_HOME/work/tart.lock`
  (exit 75 while another run holds it, naming the pid and the job).
- **No test may name `/tmp/pmm-<uid>` (or Linux's `$XDG_RUNTIME_DIR/pmm`), point a `*_HOME` at a real home, write under the real `~`,
  or kill by pattern** (`pkill`, `killall`). `packages/anfs/tests/isolation.bats` greps every
  suite's bats files, helpers, stubs and e2e scripts for those; the round trips and the harness,
  whose `~` is a box's, are not covered. What no grep sees, a suite that never sets
  `PMM_SOCK_DIR`, pmm refuses itself: under bats (`BATS_TEST_TMPDIR` set) the live directory, set
  or defaulted, is exit 69 before any command (`sock_dir_path`, `lib/pmm/core.sh`).

pmm runs under `set -euo pipefail`, so every best-effort `tart` call needs an explicit guard
(`tart delete` on a missing VM exits 2 and would otherwise kill the command mid-run). The same
option is why **a list is never piped into `grep -q`**: grep leaves at its first match, the writer
is cut short, and pipefail turns a match into a failure, now and then (`tart_exists` reads the
names into a variable first).
