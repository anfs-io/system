# wsm — work space manager

A registry of the workspaces under your home directory, so you can jump to one by name without
remembering where it lives and without walking the filesystem.

A workspace is any directory holding a `.wsm/id` marker. The marker is the source of truth; the
registry at `${XDG_STATE_HOME:-~/.local/state}/wsm/workspaces` only indexes it, and can be thrown
away and rebuilt with `wsm scan` at any time.

`docs/spec.md` is the specification, including the places this implementation deliberately
departs from it.

## Getting started

wsm comes with anfs (`anfs/wsm`, part of the base install).

```sh
wsm scan                 # seed the registry from markers already on this machine
```

Then, in a directory you want to track:

```sh
wsm init                 # added <name> ~/path/to/it
wsm cd <name>            # jump to it from anywhere
```

`wsm cd` needs the shell function in `~/.config/sh/wsm.sh` — a subshell cannot change its
parent's directory, so the binary prints the path and the shell does the `cd`. Both the zsh and
the bash rc source it. With no shell package installed, use `cd "$(wsm path <name>)"`.

## Commands

| Command | What it does |
| --- | --- |
| `wsm init [DIR] [--name NAME]` | Mark `DIR` (default `.`) as a workspace and register it |
| `wsm new PATH [--name NAME]` | Create `PATH`, then behave like `init` |
| `wsm ls [--stale\|--all] [--paths\|--ids]` | List registered workspaces |
| `wsm cd [QUERY]` | Jump to a workspace; with no `QUERY`, to the root of the current one |
| `wsm path [QUERY]` | Print a workspace path (what `cd` is built on) |
| `wsm forget [QUERY]` | Drop an entry, leaving its marker in place |
| `wsm prune [--dry-run]` | Drop every stale entry |
| `wsm scan [DIR...] [--dry-run]` | Search for markers and register what it finds |
| `wsm install SPACE... [--dry-run]` | Put spaces from anfs sources in place, dependencies first |
| `wsm implode [-y]` | Forget every workspace and delete wsm's state (contents are kept) |

`QUERY` resolves in this order: an exact id, then a unique id prefix of at least four characters,
then an exact name. Names do not have to be unique — an ambiguous query lists the candidates and
exits 2 rather than guessing.

Any command run inside an unregistered workspace registers it, so a freshly cloned repository
with a committed `.wsm/id` appears the first time you run any `wsm` command in it.

## Spaces from sources: `space.yml`

A space is defined in an anfs source, next to its `packages/` and `containers/`, at
`spaces/<name>/space.yml`. `wsm install` puts it in place:

```yaml
# lgat-anfs/spaces/tech/space.yml
path: spaces/lgat/tech     # where it lives, relative to $HOME (default: spaces/<name>)
id: 0b4a1c2e-...           # optional: the same identity on every machine
depends: [org]             # other spaces, installed first
resources:                 # what belongs inside it, relative to the space
  - type: repo
    url: git@github.com:lgat/app
    path: repos/app
    ref: main              # optional; a branch, tag or commit, checked out after the clone
```

```sh
wsm install lgat/tech      # org first, then tech
wsm install lgat/          # every space lgat defines
wsm install tech           # a bare name: the highest-priority source that has it
```

For each space, dependencies first: create `$HOME/<path>`, write the marker (with `id` when given),
register it under the space's name, record the definition in `.wsm/source`, and clone the
resources that are missing. It never pulls, because what is checked out is yours; re-running it is
how a space picks up resources added since.

`depends` names other spaces and resolves the way ppm's package dependencies do: a bare name to the
same or a lower-priority source. A space declares only what a space is concerned with — where it
lives, which spaces it builds on, which repos it holds. The software working in it needs is a
package in the same source (`packages/lgat`), and its services are containers
(`containers/postgres`); `anfs install lgat` installs all three, in that order.

`type` defaults to `repo`, the only type implemented. It is carried from the start so `link`,
`mkdir` and whatever else can arrive later without invalidating files already written; an unknown
type is a warning and a skip, not an error. Paths may not escape the space.

**`install` is the one command that needs `yq`** (and anfs's shared libraries, to find sources).
Everything else is plain bash.

**Spaces are never deleted.** `wsm implode` forgets every workspace and removes the markers wsm
wrote, but everything inside a space stays. A space repo that commits its own `.wsm/id` keeps it.

## Things worth knowing

**Renaming.** There is no `rename` command because `init` already is one:

```sh
cd ~/code/thing && wsm init --name something-else
```

**Moving.** Just move the directory and run `wsm init` in its new home, or `wsm scan`. The id in
the marker is what identifies a workspace, so the entry is updated rather than duplicated and the
date it was first registered is kept.

**Forget is not delete.** `wsm forget` drops the registry entry but leaves `.wsm/` alone, so the
workspace re-registers itself the next time you run a `wsm` command inside it. That is deliberate.
To be rid of it for good, remove the marker: `rm -r .wsm`.

**Staleness costs a read.** An entry is stale when its path is gone or its marker no longer holds
the recorded id. Checking the second half means reading `<path>/.wsm/id`, so plain `wsm ls` does
one open+read per entry — fine for hundreds of workspaces, but it is not free. `wsm ls --all
--paths` filters and annotates nothing, so it skips validation entirely:

```sh
cd "$(wsm ls --all --paths | fzf)"
```

**Exit codes.** `0` success, `1` not found, `2` ambiguous, `3` matched but stale (the path is
still printed), `64` usage, `65` bad marker or registry data, `69` `install` needs yq, git or
anfs and one is missing, `73` target exists, `75` could not lock.

## Tests

```sh
bats packages/wsm/tests/
```

The suite runs the script straight out of the package with `HOME` and `XDG_STATE_HOME` pointed at
a temporary directory, so it never touches your real registry. One test deliberately waits out
the five-second lock timeout.
