# anfs — the toolkit's own package

The `anfs` command and everything the tools share:

| Linked to | What |
| --- | --- |
| `~/.local/bin/anfs` | `anfs src` (and `anfs src install <source>`; `anfs src push [source...\|--all] [-n]` pushes the current branch of each source ahead of its upstream, plain `git push`, one row each), the stacks (`anfs list|show|install|remove|path`), `anfs implode`, `anfs iso` (the ISO catalogue and store; `pmm iso` and `ventoy iso` are the same commands) |
| `~/.local/lib/anfs/` (one link: a library a pull brings is there at once) | the libraries every tool sources: `platform.sh` (`platform`, `os`), `link.sh`, `manifest.sh` and `files.sh` (how packages and spaces are placed: links, `links:`/`files:`/`platforms:`, copies), `paths.sh` (where everything lives, and every tool's settings: `anfs_load_conf`), `sources.sh` (the source lists), `repo.sh` (one clone at one path: clone, state, pull, ssh, push; and the `push` command `anfs src` and `wsm repo` share), `resolve.sh` (finding resources, ordering them by dependency), `stacks.sh` (stacks: the manifest, install and remove, the record), `iso.sh` (the ISO store, its catalogue and the `iso` commands) |
| `~/.config/anfs/system.list` | the default sources (`anfs src ssh` switches a clone's `origin`, never this list: its URL is only used for the first clone; `anfs src list` shows the origin) |
| `~/.config/anfs/anfs.env` | anfs's own settings (`ANFS_*`, shared by the tools) and Homebrew's, each documented with its default; each tool ships its own `~/.config/<tool>/<tool>.env` |
| `~/.config/sh/anfs.sh` | the shell wrapper that reloads the shell after `anfs install`, `remove` and `src install` |

**Reporting a bug** in any anfs tool: `anfs report` (`lib/anfs/report.sh`). It builds the issue
(title, what was expected, what happened, steps, and `anfs report diag`'s block: versions, each
source's commit and state, installed packages, the log's recent failures) and files it where
`ANFS_REPORT_TO` says: `github` (the default; the repo of the source owning `--package`, after a
duplicate search and a yes) or a markdown file (appended as `## r-<date>-<n> <title>` with
`Status: open`). It prints the report's id. Then:

```bash
anfs report check                       # can this machine file one (ok/fail per item; exit 1 on a fail)
anfs report status <id>                 # open, fixed, or available (the fix is in this host's checkout)
anfs report wait <id> --timeout 3600    # until available (0) or the timeout (1)
anfs report close <id> --commit <sha>   # whoever merges the fix: recorded, and the issue closed
```

The core skill `anfs-bug-report` is how an agent uses it: it reproduces the bug minimally, runs
`anfs report` with the fields (never choosing where it goes, never calling `gh`), keeps the id,
runs `wait` in the background; invoked with no bug in hand (`/anfs-bug-report check`) it runs
`anfs report check`. Install it like the other core skills: `psm install core/anfs-bug-report`.

It depends on `ppm` (what `anfs src install` and the stacks run) and nothing else. The rest of
the toolkit — `pcm`, `psm`, `wsm` and the `podman`, `varlock` and `node` they run on — is the stack
`core/system`: `anfs install system` installs it (install.sh does), `anfs implode` removes it.

**Customizing it.** Your own repo's `anfs` package (`user/anfs`, which `anfs onboard` creates) is
a layer of this one: its `user.list` holds your sources (and an `anfs.env` there would replace this
one whole). This machine's values go in `~/.config/anfs/anfs.local.env` (each tool's in
`~/.config/<tool>/<tool>.local.env`). The environment wins over both files. `anfs config list`
shows anfs's settings and where each is from, `anfs config list --all` every installed tool's, and
`<tool> config set NAME=value` writes that tool's local file.

`tests/` holds the bats suites for `lib/anfs` (see AGENTS.md, Testing); the end-to-end round
trips are in the anfs-dev source.
