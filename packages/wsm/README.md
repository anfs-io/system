# wsm — work space manager

Spaces from anfs sources, put in place the way ppm puts packages in place.

A **space** is any directory of a source's `spaces/` that holds a `space.yml`, at any depth. Its
id is its path, qualified by the source: `spaces/space.yml` is the space `lgat`,
`spaces/tech/web/space.yml` the space `lgat/tech/web`. A directory without a `space.yml` is only a
directory, so `spaces/` can be organized any way you like.

```
lgat/spaces/
  space.yml             the space lgat (optional: without it, lgat has no root space)
  mise.toml             lgat's file: a file belongs to the nearest space above it
  tech/
    space.yml           the space lgat/tech
    README.md
    web/
      space.yml         the space lgat/tech/web: its files are its own, not lgat/tech's
  spikes/               a directory, not a space
    rails/
      space.yml         the space lgat/spikes/rails
```

A file under no space (with no `space.yml` above it) is not linked, and wsm warns about it once.

`wsm install lgat/tech` links that space's files into `$WSM_SPACES_HOME/lgat/tech/`, one relative
link per file (so the directories stay real and what you put in them stays yours), then clones the
repositories its `space.yml` declares. It installs the spaces it `depends:` on first, but not the
spaces above it.

There is one root, `WSM_SPACES_HOME` (default `~/spaces`). Set it in
`~/.config/wsm/wsm.local.env` (`wsm.env` beside it documents it), or with `wsm config set WSM_SPACES_HOME=<dir>`; `wsm help` prints the value in use. A source's spaces are always under
`<root>/<source>/`.

The tree you work in mirrors the source. `wsm new` and `wsm add` carry what you create there back
into the source, and `wsm ls` shows what differs. The source then holds everything but the clones.

wsm comes with anfs (`core/wsm`, part of the base install), and `anfs src install <source>` runs
`wsm install <source>/` after the other tools.

## Commands

| Command | What it does |
| --- | --- |
| `wsm ls [SPEC]` | Every space the sources define, and the state of each installed one: `SPACE STATUS DIR NOTE` |
| `wsm repo ls [SPEC]` | The repositories the `space.yml` files under `SPEC` declare, and their state: `REPOSITORY STATUS URL` |
| `wsm repo install [SPEC\|REPOSITORY] [-n]` | Clones what the installed spaces under `SPEC` declare and is missing, or one repository; links nothing, pulls nothing (the clone half of `install`) |
| `wsm repo ssh [SPEC]` | Switches the clones under `SPEC` whose origin is a GitHub https URL to ssh (`<id>: origin -> git@...`), as `anfs src ssh`. `space.yml` is the source's and is not edited: an https URL in it is noted (`<id>: https in space.yml`) |
| `wsm repo push [SPEC\|REPOSITORY...] [--all] [-n]` | Pushes the current branch of each named clone (as `repo ls` names it), of the clones under each SPEC (resolved as `repo ls` resolves it: `cnfs/partitia` that space's, `cnfs/` every space under it; ahead ones pushed, the rest `up to date`; a bare id with none of its own but children with some says `did you mean cnfs/?`), or of every one ahead of its upstream (`--all`), with plain `git push`: never forced, no `--set-upstream`; uncommitted changes stay and the commits still go. One row each, `REPOSITORY STATUS BRANCH UPSTREAM` (`pushed N`, `up to date`, `no upstream`, `detached`, `rejected`, `not cloned`); `-n` says what would be pushed. Exit 1 when one was not pushed. Neither names nor `--all` lists the ones ahead. As `anfs src push` |
| `wsm skill ls [SPEC]` | Each skill the spaces under `SPEC` declare, and its state in the space: `SKILL STATUS REPO` (`ok`, `partial`, `missing`, `waiting` for an agent, `*` for a whole remote repo; `-` while the space is not installed) |
| `wsm skill install [SPEC] [-n]` | Installs the declared skills of the installed spaces under `SPEC` into their directories (the skills half of `install`) |
| `wsm skill rm [-y] SPEC...` | Asks, then removes a space's declared skills from it, or one (`<space id>/<name>`); skills it does not declare stay |
| `wsm install [SPEC...] [-n] [-f] [-y]` | Links spaces into `$WSM_SPACES_HOME/<id>`, copies their `files:`, clones their repositories, makes their `links:` out of the tree and installs their `skills:`, dependencies first. With no `SPEC`, the space at `.`, which must hold a `space.yml` |
| `wsm remove [-y] SPEC...` | Asks, then unlinks installed spaces; cloned repos and your own files stay |
| `wsm new [SOURCE/]PATH` | Creates a space in a source, with a new id; installs it when the space around it is installed |
| `wsm id [SPEC] [--new]` | Prints a space's id (`id:` in its `space.yml`; no `SPEC`: the space around `.`; a prefix: `SPACE ID` rows). `--new` writes one into each space `SPEC` names that has none, and never changes one. `wsm ls` notes `no id` and `duplicate id` |
| `wsm events ls [SPEC...] [-f [--once]] [--type G] [--subject S] [--since D] [--by A] [--after ID]` | The event log of the space around `.`, or of the spaces `SPEC` names: `EVENT SUBJECT SPACE BY`, oldest first; `--json` the CloudEvent lines. `-f --once` waits for a match (lib/anfs/events.sh; AGENTS.md "Events") |
| `wsm add FILE...` | Moves files (or every file under a directory) into the source, then links them back |
| `wsm move [-n] [-f] SOURCE/PATH TO-SOURCE` | Moves a space and the spaces under it to another source with its history (commits in both, nothing pushed); when installed, its directory under the root moves too (clones and your files inside untouched) and its links are made again. Ids that name it are not rewritten: the check lists them |
| `wsm cd [-s] [QUERY]` | Jumps to an installed space; with no `QUERY`, to the deepest one you are in. `-s`, `--source`: to its directory in the source instead |
| `wsm path [-s] [QUERY]` | Prints that path (what `cd` is built on) |
| `wsm implode [-y]` | Unlinks every installed space and deletes wsm's state; contents are kept |

`SPEC` is an **id** or a **prefix**:
- an id, `lgat`, `lgat/tech/web`: that space only (`lgat` is the source's root space);
- a prefix ending in `/`, `lgat/`, `lgat/tech/`: every space at or under it (`install` asks first);
- the first segment is the source when it is the alias of a source with `spaces/`; otherwise the
  spec is a path (`tech/web`, `tech/`), taken from the highest-priority source that has it.

`install` takes several specs (`wsm install lgat/ cnfs/partitia`); a spec that names no space fails
before anything is linked. `remove` takes the same forms, matched against what is installed.

`QUERY` for cd and path is an installed id; failing that, the installed ids that end in it (`web`,
`tech/web`); failing that, a source (`lgat` or `lgat/`) names `<root>/lgat`. An ambiguous query
lists the candidates and exits 2. With `-s`, a source-qualified query needs nothing installed:
`wsm cd -s lgat/spikes` is `<lgat>/spaces/spikes`.

`wsm cd` needs the shell function in `~/.config/sh/wsm.sh`: a subshell cannot change its parent's
directory, so the binary prints the path and the shell does the `cd`.

## The state: wsm ls

Nothing is recorded. What is installed is read off the links:

| STATUS | Meaning |
| --- | --- |
| `-` | not installed: `<root>/<source>/<path>/space.yml` is not a link to the space's `space.yml` |
| `ok` | installed, and every file's link is right |
| `partial` | installed, and NOTE counts what is not: `missing` (no link yet, e.g. a file new in the source: `wsm install`), `wrong` (a link to something else), `in the way` (a file or directory of yours where a link goes: `wsm add FILE` or `wsm install -f`), `leftover` (a link whose file left the source: `wsm install` removes it) |
| `not in the source` | the tree has the space's `space.yml` link, the source no longer has the space (`wsm remove` takes it) |

`wsm ls --json` has the counts as `missing`, `wrong`, `in_the_way` and `leftover`, and `wsm ls
<id> --json` adds `files`: each of the space's files and its state (`ok`, `missing`, `wrong`,
`in the way`, `leftover`), relative to the space.

`repo ls` reports each repository as `clean`, `dirty`, `unpushed`, `no upstream` (both may follow
`dirty, `), `missing`, `not a repo`, `not installed`, `no path` or `invalid`; its `--json` adds
`space`, `path` and `dir` (where it is cloned, null while its space is not installed).

There is no `repo update`: a space's repositories are never pulled (what is checked out is
yours), and no `repo add`/`remove`: a repository is declared in the source's `space.yml`. Cloning
and the states are `lib/anfs/repo.sh`, shared with `anfs src`, and so is `repo push` (`anfs src
push`): pushing is the one thing wsm does to a clone after it is made, and only when asked.

## Working in the tree

`wsm new` takes a path from where you are:

- **`SOURCE/PATH`** works anywhere (`wsm new lgat/tech/api`).
- **`PATH`** is below where you are: inside the tree (`wsm new web` in `~/spaces/lgat/tech` is
  `lgat/tech/web`), or below `spaces/` in a source checkout (anywhere else in the checkout, under
  `spaces/`, which is created if missing).

The space is created in the source. If the nearest space around it is installed, it is installed
too; a space made inside a space takes the files below it, and their links are already right.
Commit it in the source yourself; wsm never touches git history.

`wsm add` moves each file to the same place in the source and links it back as install would; it
then belongs to its nearest space, which must be installed. A directory adds every plain file
below it. It refuses, or skips quietly under a directory:

- anything inside a git repo (a clone);
- a repository's path;
- what the source's `.gitignore` ignores, so keep `.env` and the like there;
- a file under no space;
- `.DS_Store`.

Some tools save by renaming over a file, which replaces wsm's link with a plain copy (`in the
way`). `wsm add FILE` named explicitly puts the copy in the source, where `git diff` shows what
changed.

## space.yml

```yaml
depends: [lgat/tech, org]   # installed first: an id, or a path in this source (or a lower one)
repositories:               # paths relative to the space's directory
  - url: git@github.com:lgat/app
    path: repos/app         # optional; left out, the name git clone would use (app)
    ref: main               # optional; a branch, tag or commit, checked out after the clone
  - url: git@github.com:lgat/docs    # cloned into docs
skills:                     # agent skills installed into the space's directory, for it alone
  - repo: vercel-labs/agent-skills   # owner/repo, a URL or a path, as the skills CLI takes it
    skills: [deploy-to-vercel]       # optional: every skill in it when left out
  - repo: ./skills                   # relative: from this space.yml in the source
links:                      # how the space's files are linked: each on its own unless said here
  - docs/                            # a directory as one link: a file added upstream is there at once
  - {path: notes.md, platforms: [macos]}   # only on those platforms (macos, linux, debian, fedora)
  - src: ~/.local/share/anfs/sources # a link out of the tree: ~ and $VAR expanded; relative: from
    dest: sources                    #   the space's directory; dest: src's basename, inside the space
files:                      # copied when missing, then yours: never overwritten, left by remove
  - local.conf
```

`links:` and `files:` are the vocabulary a package's `package.yml` has (`lib/anfs/manifest.sh`;
core's AGENTS.md, "package.yml", has the table and every refusal). A refused one makes the space
`invalid` in `wsm ls` (the first error is its note) and `wsm install` says every error and links
nothing: a `links:` path without a trailing `/`, a path not in the space, a directory link that
holds, is or lies in a child space or a repository, a directory link at a hidden directory when the
space declares `skills:` (the skills CLI writes there), `space.yml` in `files:`, and the rest of
the list. A `src:` entry wrong on its own (an unset variable, a `dest` that leaves the space) is
only that entry: `invalid`, warned and skipped while the rest installs (`wsm install` exits 1).

`depends` resolves the way ppm's package dependencies do: an id names its source (by its alias on
this machine), and a bare path is the declaring source's, else a lower-priority one's. Spaces do
not layer: an id means one space, the highest-priority one.

A repository's id is `<space id>/<path>` (`lgat/tech/web/app`). Its path may not leave the space,
lie inside a child space or hold one (`invalid`), so the longest prefix of an id that is a space is
always its space. Two repositories of one `space.yml` may not share a path.

**A `links:` `src`** is made as a relative link (`anfs_link_one`; absolute only to a path that
shares nothing but `/` with the space, another volume). One made absolute before reads `ok` and is
left as it is. `wsm ls <id> --json`'s `links` has each one's state: `ok`, `missing`, `missing src`
(said, not made, not a failure: the target may come later), `wrong` (a link elsewhere), `in the
way`, `invalid`. `wrong` and `in the way` fail install; `-f` moves them aside as for files. `remove` takes a
link only while it still points at its `src`.

**`files:`** are copied when missing at install (after the files are linked, before the clones),
and never touched again: edit them. A copy that is missing or in the way makes the space `partial`;
one that differs does not. `wsm ls <id> --json`'s `copies` has each one's state (`missing`,
`present`, `differs`, `in the way`). `remove` leaves them, so their directory stays.

**`skills:`** go through the skills CLI (`npx skills`, without `-g`, run in the space's directory),
for the agents ppm installed (packages that declare `meta.agent`). The CLI writes
`.agents/skills/<name>/`, an agent's own directory (`.claude/skills/<name>`) and
`skills-lock.json`; `wsm add` steps around them. A path's skills are copied again on every
install (edits in the source arrive that way); a remote's when missing for an agent. No agent yet
is `waiting` and no npx a warning: neither fails an install, and a space without `skills:` never
runs npx. A space's skills are its own: a child space's install never installs its parent's.
Installing an agent package (`ppm install`) installs every installed space's skills for it;
removing one unlinks them from it. `remove` takes a space's declared skills first, never one you
added by hand. The CLI version is `ANFS_SKILLS_CLI_VERSION` in `anfs.env`.

Install never pulls: what is checked out is yours. Re-running it is how a space picks up files
and repositories added since, and drops the links to files the source no longer has.

## How it is kept

- **Linked, as ppm links packages** (`lib/anfs/link.sh`): one relative link per file (a directory
  link one link), exactly as `stow --no-folding` wrote them, so a clone never lands in the source. Every file is linked,
  `README.*`, `LICENSE.*` and `.gitignore` included; only `.DS_Store` is not. Anything already in
  the way fails that space before anything is linked, every file named. **`-f` moves it aside**,
  to `$WSM_STATE_HOME/backup/<source>/<path>` (`.1`, `.2` when taken), and links; nothing puts it
  back (`remove` does not restore: there is no record).
- **Nothing is recorded.** A space is installed when its `space.yml` link is there; each file's
  state is its link checked against the source, with one `readlink` for every link. A link whose
  file left the source is found by looking only at the directories of `<root>/<source>/` that
  mirror one of the source's `spaces/`, plus one level for a space that vanished. So a clone of
  any size inside a space costs one directory entry, and **a space that vanished two or more levels
  below the nearest directory the source still has is not seen** (remove its directory by hand).
- **No root inside a source**: the source would be linked into itself, and the clones would land
  in it.
- **wsm acts only on what it derives from the source**: the spaces' files, its leftovers, the
  repository paths (cloned when missing, never pulled, never deleted), the `links:` dests, the
  `files:` copies (made when missing, never changed or removed after), and
  what the skills CLI writes for the skills a space declares. Your files, your links and
  other tools' links in the tree (ovm's) are never listed, changed or removed.
- **remove and implode only take links** still pointing at the space's files, the leftovers, and
  `space.yml` last (an interrupted remove leaves the space `partial`), then the directories that
  leaves empty. Clones, your own files and a child space's links keep a directory alive. `implode`
  also deletes `$WSM_STATE_HOME`, the backups included.

**Exit codes.** `0` success, `1` not found or failed, `2` ambiguous, `64` usage, `69` yq or git
missing, `73` already exists.

## Tests

```sh
bats packages/wsm/tests/
```

The suite runs the script straight out of the package with `HOME`, the XDG dirs and
`WSM_SPACES_HOME` in a temporary directory, and clones over `file://` from bare repos it makes; no
network.
