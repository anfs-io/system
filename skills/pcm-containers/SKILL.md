---
name: pcm-containers
description: Create or edit pcm (Personal Container Manager) container definitions — the compose.yml, .env.schema, optional provision hook and README in an anfs source (a repo's containers/<name>/, or ~/.config/pcm/containers/<name>/). Use when the user wants to add a new container/service to pcm, wire one service to another (x-pcm.depends_on, e.g. "give it a postgres database"), write or fix an .env.schema, or make `pcm validate` pass.
---

# pcm container definitions

pcm runs podman compose projects on a dev machine. Each **container definition** is one
directory; pcm's CLI calls it a *service* (`pcm up <service>`). One definition can hold
several compose services (twenty runs `server` and `worker`).

## Where definitions live

pcm reads definitions from **sources**, in priority order; a plain name resolves to the first
source that has it, and `source/name` picks one explicitly (`pcm list` shows shadowed ones):

1. `local` — `$PCM_CONTAINERS_HOME/<name>/` = `~/.config/pcm/containers/<name>/`, not in git
2. every anfs source holding a `containers/` directory, in anfs's order: `user.list` entries
   (`anfs src add <git-url> [alias]`), then `system.list` (shipped; `core` = the `core-pcm`
   repo, `pdt` has `dnsmasq` and `netboot`). `anfs src list` shows what each source provides.

A source is cloned once to `~/.local/share/anfs/sources/<alias>/` and may hold `packages/`,
`skills/` and `spaces/` next to its `containers/<name>/`. pcm runs definitions straight from the
clone: `pcm cd <name>` lands in the repo, edits are committed there, and `anfs src list` shows
each clone clean or dirty. `pcm install <source>/` starts every definition a source holds.

- New definition for a repo: create `containers/<name>/` in its clone (`pcm path <other>` then
  `..` finds it) and commit there. Scratch or machine-only: create it in the local source.
- Data: `$PCM_VOLUMES_HOME/<name>/` = `~/.local/share/pcm/volumes/<name>/`, keyed by name only:
  one service of a name runs at a time, whichever source it came from
- Runtime: pcm runs each definition as compose project `<name>` and labels its containers
  `io.pcm.id` (`source/name`), `io.pcm.name` and `io.pcm.source`. Don't set a top-level `name:`
  (it is ignored, and `validate` warns when it differs); don't set `container_name:`.
- Local overrides: `~/.config/pcm/env/<name>.env`
- Shared settings: `PCM_SHARED_NETWORK` and `PCM_ATTACHED_SERVICES` in `~/.config/anfs/anfs.conf`

Before writing a new one, read an existing definition as a model:
`postgres` and `valkey` (shared dependencies with provision hooks), `twenty` (depends on
both, several compose services), `dockge` (extra allowed mount).

## Files

| File | Required | Purpose |
|------|----------|---------|
| `compose.yml` | yes | The compose project, plus the `x-pcm` block |
| `.env.schema` | if `compose.yml` uses any `${VAR}` | Declares every variable, with type and default |
| `provision` | no, executable | Hook other definitions call when they depend on this one |
| `deprovision` | with `provision`, if it creates anything | Undoes `provision` when a dependent is removed |
| `README.md` | recommended | What it is, how to start it, anything non-obvious |

Never ship a `.env`: the user overrides defaults in `~/.config/pcm/env/<name>.env`, which
pcm exports before varlock runs (a `.env` in a clone would dirty it).

## compose.yml

```yaml
# <Name> — one line on what it is (link).
#
# pcm service: `pcm up <name>`. Every variable, with its default, lives in .env.schema.

x-pcm:                             # optional
  depends_on:                      # other pcm definitions this one needs (name or source/name)
    postgres:                      # map form: settings passed to postgres's provision hook
      database: <name>
  # depends_on: [postgres]         # list form: no settings
  allow_mounts:                    # extra host paths this definition may mount
    - ${PCM_PODMAN_SOCKET}

services:
  app:
    image: ${APP_IMAGE}:${APP_TAG}   # fully qualified image (docker.io/...), set in the schema
    restart: unless-stopped
    ports:
      - "${APP_PORT}:8080"           # every host port comes from the schema
    environment:
      DATABASE_URL: ${PCM_POSTGRES_URL}
    volumes:
      - ${PCM_VOLUMES_HOME}/<name>/data:/data
      - ./config.toml:/etc/app/config.toml:ro
    healthcheck:                     # add one if anything depends on this definition
      test: ["CMD-SHELL", "..."]
      interval: 10s
      timeout: 5s
      retries: 5
```

### Volume rules (`pcm validate` errors)

- Bind mounts must be under `${PCM_VOLUMES_HOME}/<name>/`. pcm creates missing directories there on `up`.
- Read-only mounts (`:ro`) may come from the definition directory (`./file`).
- No named volumes, no anonymous volumes (a bare `/path`), no top-level `volumes:`, no `..`.
- Any other host path must be listed in `x-pcm.allow_mounts`. On Linux it must also exist.
- `tmpfs` mounts are fine.

Also:

- **Image VOLUMEs:** if the image declares a `VOLUME`, mount something at that path, or podman
  creates a new anonymous volume on every run (a warning). Postgres mounts
  `${PCM_VOLUMES_HOME}/postgres` at `/var/lib/postgresql/data` and sets `PGDATA` to a
  subdirectory.
- **Non-root images:** add `:U` so rootless podman chowns the host directory
  (`.../uploads:/code/uploads:U`).

### Privileges (`pcm validate` errors)

A container gets podman's default isolation. Anything beyond it must be declared, with the reason,
under `x-pcm.privileges`, or `validate` (and so `up`) refuses it:

```yaml
x-pcm:
  privileges:
    privileged: "rootless podman runs inside the box"
    devices: "/dev/fuse, which podman's overlay storage needs"

services:
  box:
    privileged: true
    devices: ["/dev/fuse"]
```

- **Keys:** `privileged`, `devices`, `cap_add`, `security_opt`, `userns_mode`, and `pid`,
  `network_mode`, `ipc` when they are `host`.
- **Each needs a non-empty reason.** An unknown key is an error, and a declared key that no
  service uses is a warning.
- **Visible:** `pcm up` prints each privilege and its reason as it starts the service, and
  `pcm show` lists them.
- **Use them sparingly.** If a service only needs a host path, `allow_mounts` is enough.

### Mount sets (generated mounts)

When the mounts depend on the machine rather than the definition, declare a mount set and pcm
generates them in its override at every `up`:

```yaml
x-pcm:
  mounts:
    - set: anfs-sources     # every anfs source, at <target>/<alias>
      target: /src
      service: box          # optional: one compose service (default: all of them)
      readonly: false       # optional: read-only unless it says false
```

The only set today is `anfs-sources`, the source repos resolved to their real paths. Generated
mounts are not in `volumes:`, so the volume rules above don't apply to them.

### Snapshots, exec and shell

These work on any running service:
- `pcm exec <svc> [-u user] [-s compose-svc] -- cmd` runs a command in its container.
- `pcm shell <svc> [-u user]` opens that user's login shell.
- `pcm snapshot <svc> <name>` saves the service: each container committed to an image, plus a
  copy of its data dir.
- `pcm reset -y <svc> <name>` goes back to a snapshot and keeps running from it.
- `pcm reset -y <svc>` recreates the service from its definition, with fresh data.

Snapshots are made for a dev database before a migration, or a test box with its slow setup
done. `pcm remove` and `pcm implode` delete a service's snapshots with it.

### Dependencies and networking

- **Startup:** for each `x-pcm.depends_on` entry, `pcm up` does four things in order:
  1. starts the dependency if it isn't running
  2. waits until its healthchecks pass (`PCM_HEALTH_TIMEOUT`, default 120s)
  3. runs its `provision` hook with the map settings as `key=value` args
  4. exports each `KEY=VALUE` the hook prints as `PCM_<DEP>_<KEY>` (dep upper-cased, `-`→`_`)
- **Existing values:** a value already in the environment wins over one the hook prints.
- **Shared network:** definitions with dependencies, or listed in
  `PCM_ATTACHED_SERVICES`, join the shared network (`PCM_SHARED_NETWORK`, default `dev-net`). They also keep their project's
  default network. Reach a dependency by the container name it provisions (e.g. `HOST`).
- **Stopping:** `pcm down` refuses while running definitions depend on the target, unless `--force`
  is passed.
- **Rules:** dependencies must name existing definitions, with no cycles.

## .env.schema

This is a [varlock](https://varlock.dev) schema. pcm runs compose and provision hooks through
`varlock run` from the definition directory. Values resolve as environment > `.env` > schema
defaults, and invalid values stop the command.

```sh
# <Name> config schema — canonical source of truth for every tunable.
#
# Validate: varlock load --path .
#
# @defaultSensitive=false @defaultRequired=infer
# ---

## Image — fully qualified for Podman (no docker.io assumption).
# @type=string
APP_IMAGE=docker.io/example/app
# @type=string
APP_TAG=1

## Core config
# What it does. The dev default is INSECURE — set a real one for anything shared.
# Generate: openssl rand -hex 32
# @required @sensitive @type=string
APP_SECRET_KEY=dev-insecure-change-me
# Host port.
# @type=port
APP_PORT=8080

## Injected by pcm — do not set
# Connection URL for the shared pcm postgres (x-pcm.depends_on in compose.yml).
# Optional because pcm only provisions it on `up`; `down`, `logs` etc. run without it.
# @optional @sensitive @type=url
PCM_POSTGRES_URL=
# Root of pcm service volumes.
# @required @type=string
PCM_VOLUMES_HOME=
```

- **Layout:** each variable gets a comment line, then a `# @...` decorator line, then `NAME=default`.
  Group variables under `## Section` headings.
- **Types used so far:** `string`, `port`, `url`, `ip`, `enum(True, False)`. Add `@required`,
  `@optional` and `@sensitive` as needed. Don't use `@type=email` for a default with no TLD, because
  varlock rejects it.
- **Declare everything:** every `${VAR}` in `compose.yml` must be declared, including pcm's own.
- **Defaults:** they should boot the service untouched on a dev machine. Mark insecure ones.
- **Variables pcm injects:** list them last, empty, under "Injected by pcm — do not set":
  - `PCM_VOLUMES_HOME`: always, `@required`.
  - `PCM_PODMAN_SOCKET`: the podman API socket, set only when `compose.yml` references it.
    `@required`, and list it in `allow_mounts`.
  - `PCM_<DEP>_<KEY>`: from dependency provisioning, `@optional`.

## provision hook

This is only needed when other definitions depend on this one and need something set up or
passed back, like a database and its connection URL. Model it on `postgres/provision`.

- **How it's run:** `#!/usr/bin/env bash`, `set -euo pipefail`, executable (`chmod +x`). pcm runs it
  from this definition's directory under varlock, so this definition's schema variables are set.
- **Inputs:** `key=value` args from the dependent's `depends_on` map. Reject unknown keys and
  validate values. Extra env:
  - `PCM_SERVICE`: this definition
  - `PCM_PROJECT`: its compose project, used to find containers with
    `podman ps --filter label=com.docker.compose.project=$PCM_PROJECT`
  - `PCM_DEPENDENT`: the definition asking
- **Behavior:** it must be idempotent, because it runs on every `pcm up` of a dependent.
- **Output:** `KEY=VALUE` lines on stdout (upper-case keys) and nothing else. Send logs and
  progress to stderr. Document the keys in the header comment.

## deprovision hook

The mirror of `provision`: `pcm remove <dependent>` runs it after the dependent is down, while
this definition is running, with the same `key=value` args and env. It undoes what `provision`
created for that dependent (postgres drops the dependent's database). Model it on
`postgres/deprovision`.

- Never destroy anything shared: when the settings point at a default/shared resource (postgres's
  admin database), log to stderr and exit 0.
- Idempotent (`--if-exists`), output to stderr only. A non-zero exit is reported and the rest of
  the remove still happens.
- If this definition isn't running, pcm skips the hook and says what was left in place.

## Secrets

If `fnox` is installed and a `fnox.toml` is in the definition directory or
`$PCM_CONFIG_HOME` (or `$PCM_CONTAINERS_HOME`), pcm wraps each call in `fnox exec` so secrets are in the environment
before varlock resolves.

## Workflow

1. Create `<name>/` with `compose.yml` and `.env.schema`, plus `provision`/`deprovision` and
   `README.md` if needed.
2. `cd <name> && varlock load --path .` to check the schema on its own.
3. `pcm validate <name>`. Fix every error. Treat warnings (image VOLUMEs, host-port clashes with
   other definitions) as bugs unless there's a reason.
4. `pcm list` shows it (and whether it shadows or is shadowed), then `pcm up <name>`. Commit it in its source repo.
5. Check it: `pcm ps`, `podman compose --pcm logs -f <name>`, then `pcm down <name>`.

Only report the definition as working after `pcm validate` passes and `pcm up` starts it
healthy. If you couldn't run them, say so.
