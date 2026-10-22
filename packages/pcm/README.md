# pcm

pcm, the Personal Container Manager: podman compose services, with their configuration schema and
dependencies. Container definitions live in the `containers/` directory of any anfs source
([stack](https://github.com/anfs-io/stack/tree/main/containers) ships the defaults), and resolve
like packages: `pcm up postgres` runs `stack/postgres` unless a higher-priority source defines
`postgres`. `pcm help` lists the commands. pcm's own settings are `~/.config/pcm/pcm.env`
(shipped) and `pcm.local.env` beside it: `pcm config list` shows them, `pcm config set` writes.

## Layout

```
containers/<name>/
  compose.yml     # the service; x-pcm: keys for dependencies and allowed mounts
  .env.schema     # every variable compose.yml uses, with types and defaults (varlock)
  provision       # optional: dependency hook (see stack's postgres)
  README.md
```

Any git repo with this layout is a pcm source: `anfs src add <git-url> [alias]`.

## Local overrides

Don't put a `.env` in a source's clone: it is git-ignored, so nothing would show it is there. Use
`~/.config/pcm/containers/<name>/local.env` instead: pcm exports it before varlock resolves the
schema (the environment > `local.env` > the schema's defaults), for whichever source's `<name>`
runs. That directory holds a local definition only when it has a `compose.yml`; with only
`local.env` it is settings, and `pcm show <name>` names the file.

## One-off commands

`pcm run <service> [--] <cmd>...` runs a command in a new container of a service, as `docker
compose run` does: the service's image (pulled or built as `pcm up` gets it), its env with
`local.env`, its network (it reaches the services it depends on) and mounts, and pcm's labels plus
`io.pcm.oneoff=true`. It starts what the service requires (`x-pcm.depends_on`, compose
`depends_on`) when it is not running, has a tty at a terminal, and is removed on exit unless
`--keep`. `-s <compose-service>` picks one when the definition has several; with no command it runs
what the service runs.

```sh
pcm run app -- bin/rails db:migrate   # with the app's env, network and database
pcm run app -s worker -- sh            # a shell in a new container of compose service worker
```

There is no `pcm run <image>`. For a throwaway run of a stock image, plain `podman run --rm
<image>` is the right tool; it does not bypass pcm, which manages definitions.

## Logs

`pcm logs <service>` prints a service's logs, as `podman compose logs` does for its project: every
compose service's containers, or one with `-s <compose-service>`. It is a plain command, so it
works from bash, scripts and agents (the zsh-only `podman compose --pcm logs` now runs it). `pcm
run`'s one-offs are left out unless `-s` names one (its name is in `pcm ps`). It exits 1 when the
service has no containers.

```sh
pcm logs ui --tail 50          # the last 50 lines of each container
pcm logs app -s worker -f      # follow compose service worker
pcm logs app -- -t             # anything after -- goes on to compose logs
```

## Provisioning for a consumer outside pcm

A definition's `provision` hook normally runs for another definition that lists it under
`x-pcm.depends_on`. `pcm provision` runs it for anything else, such as a Rails app run on the
host, and `pcm deprovision` undoes it:

```sh
pcm provision postgres --as partitia/shop database=shop          # URL=... HOST=... PASSWORD=...
pcm provision postgres --as partitia/shop database=shop --json   # {"URL":"...",...}
pcm deprovision postgres --as partitia/shop database=shop
```

`provision` starts the service if it is not running (with what it depends on, as `pcm up` does)
and waits until it is healthy (`PCM_HEALTH_TIMEOUT`). Then it runs the hook the way `up` runs it for
a dependent: from the definition's directory under varlock, with `PCM_SERVICE`, `PCM_PROJECT` and
`PCM_DEPENDENT` (the `--as` name, `external` by default). The `key=value` args are passed as the
hook's arguments, just as a dependent's `depends_on` settings are. stdout is only the hook's
`KEY=VALUE` lines, and messages go to stderr. The values are secrets: pcm logs only their names. The
args are part of the command line, which the anfs log records, so they are settings, not secrets.

`deprovision` runs the `deprovision` hook with the same env and args. It never starts the service:
when the service is not running, it says what was left in place and exits 1. Both commands exit 1
when the definition has no such hook.

## Validate

```sh
pcm validate            # every service pcm resolves
pcm validate stack/n8n  # one definition, from one source
```
