# anfs — the toolkit's own package

The `anfs` command and everything the tools share:

| Stowed to | What |
| --- | --- |
| `~/.local/bin/anfs` | `anfs src` (and `anfs src install <source>`), the stacks (`anfs list|show|install|remove|path`), `anfs implode`, `anfs iso` (the ISO catalogue and store; `pmm iso` and `ventoy iso` are the same commands) |
| `~/.local/lib/anfs/` | the libraries every tool sources: `paths.sh` (where everything lives, and `anfs.conf`), `sources.sh` (the source lists and clones), `resolve.sh` (finding resources, ordering them by dependency), `stacks.sh` (stacks: the manifest, install and remove, the record), `iso.sh` (the ISO store, its catalogue and the `iso` commands) |
| `~/.config/anfs/system.list` | the default sources |
| `~/.config/anfs/anfs.conf` | the settings of every tool, each named for the tool that reads it |
| `~/.config/sh/anfs.sh` | the shell wrapper that reloads the shell after `anfs install`, `remove` and `src install` |

It depends on `ppm` (what `anfs src install` and the stacks run) and nothing else. The rest of
the toolkit — `pcm`, `psm`, `wsm` and the `podman`, `varlock` and `node` they run on — is the stack
`core/system`: `anfs install system` installs it (install.sh does), `anfs implode` removes it.

**Customizing it.** Your own repo's `anfs` package (`user/anfs`, which `anfs onboard` creates) is
a layer of this one: its `user.list` holds your sources, and an `anfs.conf` there replaces the
default settings for every tool. Machine-only settings go in `~/.config/anfs/anfs.local.conf`. The
environment wins over both files.

`tests/` holds the bats suites for `lib/anfs` (see AGENTS.md, Testing); the end-to-end round
trips are in the anfs-dev source.
