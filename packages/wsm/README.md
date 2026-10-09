# wsm — work space manager

Workspaces from anfs sources, put in place the way ppm puts packages in place.

A source's `spaces/` directory holds **workspaces**, and each workspace holds **spaces**. The
levels are fixed by depth: every directory at the workspace and space depths is one, whether or not
it has a `space.yml`. Hidden directories (`.vscode/`) are content, never a level.

```
lgat/spaces/
  space.yml             optional at every level: repositories to clone there
  mise.toml             the source level's own files (org-wide settings, ...)
  main/                 the workspace lgat/main
    opm.yml             the workspace's own files
    tech/               the space lgat/main/tech: everything below it
      space.yml
      README.md
    marketing/
  spikes/               the workspace lgat/spikes
    rails/
```

`wsm install lgat/main` stows each level into `<target>/lgat/`, `<target>/lgat/main/` and
`<target>/lgat/main/<space>/` with GNU Stow (`--no-folding`, so the directories stay real and
what you put in them stays yours). It then clones the repositories of every `space.yml` under the
spec. A narrower spec clones less: `wsm install lgat/main/tech` stows the source and workspace
levels too, but clones only the space's repositories (and those of the spaces it depends on).

The target is the `DIR` argument, else `WSM_SPACES_HOME` (default `~/spaces`). Set it in your
`anfs.conf` or `anfs.local.conf`; `wsm help` prints the value in use. A source lives in one target:
later installs of it go there, and another `DIR` is refused until you `wsm remove` it.

The tree you work in mirrors the source. `wsm new` and `wsm add` carry what you create there back
into the source, and `wsm status` shows what differs. The source then holds everything but the
clones.

wsm comes with anfs (`anfs/wsm`, part of the base install), and `anfs install <source>` runs
`wsm install <source>/` after the other tools.

## Commands

| Command | What it does |
| --- | --- |
| `wsm ls [SPEC] [-r\|--repositories]` | Every source, workspace and space the sources define, with where each is installed (`-` if not); or the repositories their `space.yml` files declare, and their state |
| `wsm install [SPEC [DIR]] [--dry-run]` | Stows levels into `DIR/<source>/<ws>/<space>` and clones their repositories, dependencies first. With no `SPEC`, the level at `.`, which must hold a `space.yml` |
| `wsm remove SPEC...` | Unstows installed spaces, and the workspace or source the spec names; cloned repos and your own files stay |
| `wsm new [[SOURCE/]WS/]SPACE` | Creates a space in a source; installs it when its workspace is installed |
| `wsm add FILE...` | Moves files (or every file under a directory) into the source, then stows them back |
| `wsm status [SOURCE...]` | Lists what an installed tree and its source disagree on |
| `wsm cd [-s] [QUERY]` | Jumps to an installed space, workspace or source; with no `QUERY`, to the deepest one you are in. `-s`, `--source`: to its directory in the source instead |
| `wsm path [-s] [QUERY]` | Prints that path (what `cd` is built on) |
| `wsm implode [-y]` | Unstows every installed level and deletes wsm's state; contents are kept |

`SPEC` for install is one of:
- `source/` (or a bare `source` that names no workspace): the source level and every workspace;
- `source/ws` or `source/ws/space`;
- `ws` or `ws/space` without a source: taken from the highest-priority source that has it.

A level installs even with nothing below it: `wsm install rws/` on a source whose `spaces/` holds
only a `space.yml` stows that and clones its repositories.

`remove` takes the same forms, matched against what is installed.

`QUERY` for cd and path is `space`, `ws/space` or `source/ws/space`. Failing those, `ws` or
`source/ws` names the workspace directory, and `source/` (or `source`) names the source's. An
ambiguous query lists the candidates and exits 2. With `-s`, a source-qualified query needs
nothing installed: `wsm cd -s lgat/spikes` is `<lgat>/spaces/spikes`.

`SPEC` for ls is `source/`, `source/ws` or `source/ws/space`, narrowing the list to that subtree.
`ls -r` reports each repository as `clean`, `dirty`, `missing`, `not a repo` or `not installed`.

`wsm cd` needs the shell function in `~/.config/sh/wsm.sh`: a subshell cannot change its parent's
directory, so the binary prints the path and the shell does the `cd`.

## Working in the tree

`wsm new` fills in the parts you leave out from where you are:

- **`SOURCE/WS/SPACE`** works anywhere.
- **`WS/SPACE`** works inside a source checkout (anywhere in the repo; `spaces/` is created if
  missing) or inside that source's installed tree.
- **`SPACE`** also needs the workspace: the first directory below `spaces/`, or below
  `<target>/<source>/`.

The space is created in the source. If its workspace is installed, it is installed there too.
Commit it in the source yourself; wsm never touches git history.

`wsm add` moves each file to the matching place in the source, links it back as stow would, and records it at
its level (source, workspace or space), so `remove` takes it with that level. A directory adds
every plain file below it. It refuses, or skips quietly under a directory:

- anything inside a git repo (a clone);
- a repository's path;
- what the source's `.gitignore` ignores, so keep `.env` and the like there;
- `.DS_Store`.

Some tools save by renaming over a file, which replaces wsm's link with a plain copy. `status`
reports these as `changed`, and `wsm add FILE` named explicitly puts the copy back in the source,
where `git diff` shows what changed.

`wsm status` reports, per installed source:

| Status | Meaning |
| --- | --- |
| `local` | a file in the tree the source doesn't have (`wsm add`) |
| `changed` | a copy where a link was (`wsm add FILE`) |
| `missing` or `broken` | a link gone, or pointing at nothing (`wsm install`) |
| `unlinked` | new in the source since the install, e.g. after a pull (`wsm install`) |

## space.yml

Optional, at any level. Each one's repositories are cloned into its own level's directory.

```yaml
depends: [org, infra/net]   # a space's only: installed first, a sibling by name or <ws>/<space>
repositories:               # paths relative to the level's directory
  - url: git@github.com:lgat/app
    path: repos/app         # optional; left out, the name git clone would use (app)
    ref: main               # optional; a branch, tag or commit, checked out after the clone
  - url: git@github.com:lgat/docs    # cloned into docs
```

`depends` resolves the way ppm's package dependencies do: to the same or a lower-priority source.
Spaces do not layer: a name means one space, the highest-priority one. Paths may not escape their
level, and two repositories of one `space.yml` may not share one: give one of them a `path`.

Install never pulls: what is checked out is yours. Re-running it is how a space picks up files
and repositories added since, and drops the links to files the source no longer has.

## How it is kept

- **Stowed, as ppm stows packages**, with `--no-folding`: one relative link per file, so a clone
  never lands in the source. Each level's stow ignores the directories below it (the levels of
  their own). stow runs with `HOME` set to `$WSM_STATE_HOME/stow`, whose `.stow-global-ignore`
  holds wsm's ignore list (`.DS_Store`). Without it, stow's built-in list would drop `README.*`,
  `LICENSE.*` and `.gitignore`. A file already in the way fails that level before stow runs.
- **One tracker per installed level** is wsm's only state: `<source>.yml`, `<source>/<ws>.yml`
  and `<source>/<ws>/<space>.yml` under `$WSM_STATE_HOME/installed/`, each holding the target, the
  directory and the linked files. A space's identity is its name; there is no marker in the
  space. A workspace's and a source's files go with their last installed space, unless the
  install spec named that level (its tracker says `named: true`); then only `wsm remove` of the
  level, or of its source, takes it.
- **No target inside a source**, nor inside another source's installed tree. Otherwise the source
  would be stowed into itself, and the clones would land in it.
- **remove and implode only take links**, and only those still pointing at the space's file, then
  the directories that leaves empty. Clones and your own files keep a space directory alive.

**Exit codes.** `0` success, `1` not found or failed, `2` ambiguous, `3` matched but its directory
is gone (the path is still printed), `64` usage, `69` yq, git or stow missing, `73` already exists.

## Tests

```sh
bats packages/wsm/tests/
```

The suite runs the script straight out of the package with `HOME` and the XDG dirs in a temporary
directory, and clones over `file://` from bare repos it makes; no network.
