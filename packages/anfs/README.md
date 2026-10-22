# anfs — the toolkit's own package

The `anfs` command and everything the tools share:

| Linked to | What |
| --- | --- |
| `~/.local/bin/anfs` | `anfs src` (and `anfs src install <source>`), the stacks (`anfs list|show|install|remove|path`), `anfs implode`, `anfs iso` (the ISO catalogue and store; `pmm iso` and `ventoy iso` are the same commands) |
| `~/.local/lib/anfs/` (one link: a library a pull brings is there at once) | the libraries every tool sources: `platform.sh` (`platform`, `os`), `link.sh`, `manifest.sh` and `files.sh` (how packages and spaces are placed: links, `links:`/`files:`/`platforms:`, copies), `paths.sh` (where everything lives, and every tool's settings: `anfs_load_conf`), `sources.sh` (the source lists), `repo.sh` (one clone at one path: clone, state, pull, ssh), `resolve.sh` (finding resources, ordering them by dependency), `stacks.sh` (stacks: the manifest, install and remove, the record), `iso.sh` (the ISO store, its catalogue and the `iso` commands) |
| `~/.config/anfs/system.list` | the default sources (`anfs src ssh` switches a clone's `origin`, never this list: its URL is only used for the first clone; `anfs src list` shows the origin) |
| `~/.config/anfs/anfs.env` | anfs's own settings (`ANFS_*`, shared by the tools) and Homebrew's, each documented with its default; each tool ships its own `~/.config/<tool>/<tool>.env` |
| `~/.config/sh/anfs.sh` | the shell wrapper that reloads the shell after `anfs install`, `remove` and `src install` |

It depends on `ppm` (what `anfs src install` and the stacks run) and nothing else. The rest of
the toolkit — `pcm`, `psm`, `wsm` and the `podman`, `varlock` and `node` they run on — is the stack
`core/system`: `anfs install system` installs it (install.sh does), `anfs implode` removes it.

**Customizing it.** Your own repo's `anfs` package (`user/anfs`, which `anfs onboard` creates) is
a layer of this one: its `user.list` holds your sources (and an `anfs.env` there would replace this
one whole). This machine's values go in `~/.config/anfs/anfs.local.env` (each tool's in
`~/.config/<tool>/<tool>.local.env`). The environment wins over both files.

`tests/` holds the bats suites for `lib/anfs` (see AGENTS.md, Testing); the end-to-end round
trips are in the anfs-dev source.
