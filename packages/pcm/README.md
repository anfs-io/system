# pcm

pcm, the Personal Container Manager: podman compose services, with their configuration schema and
dependencies. Container definitions live in the `containers/` directory of any anfs source
([stack](https://github.com/anfs-io/stack/tree/main/containers) ships the defaults), and resolve
like packages: `pcm up postgres` runs `stack/postgres` unless a higher-priority source defines
`postgres`. `pcm help` lists the commands.

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
`~/.config/pcm/env/<name>.env` instead: pcm exports it before varlock resolves the schema.

## Validate

```sh
pcm validate            # every service pcm resolves
pcm validate stack/n8n  # one definition, from one source
```
