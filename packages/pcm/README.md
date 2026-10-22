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

## Validate

```sh
pcm validate            # every service pcm resolves
pcm validate stack/n8n  # one definition, from one source
```
