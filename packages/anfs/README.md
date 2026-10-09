# anfs — the toolkit's own package

The `anfs` command and everything the tools share:

| Stowed to | What |
| --- | --- |
| `~/.local/bin/anfs` | `anfs src`, `anfs install <source>`, `anfs implode` |
| `~/.local/lib/anfs/` | the libraries every tool sources: `paths.sh` (where everything lives, and `anfs.conf`), `sources.sh` (the source lists and clones), `resolve.sh` (finding resources, ordering them by dependency) |
| `~/.config/anfs/system.list` | the default sources |
| `~/.config/anfs/anfs.conf` | the settings of every tool, each named for the tool that reads it |
| `~/.config/sh/anfs.sh` | the shell wrapper that reloads the shell after `anfs install` |

It depends on the rest of the toolkit — `ppm`, `pcm`, `psm`, `wsm` and the `podman`, `varlock`
and `node` they run on — so `ppm install core/anfs` installs everything, and keeps it updated.

**Customizing it.** Your own repo's `anfs` package (`user/anfs`, which `ppm customize` creates) is
a layer of this one: its `user.list` holds your sources, and an `anfs.conf` there replaces the
default settings for every tool. Machine-only settings go in `~/.config/anfs/anfs.local.conf`. The
environment wins over both files.

`tests/` holds the bats suites for `lib/anfs` and the end-to-end round trip (see CLAUDE.md,
Testing).
