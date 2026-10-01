# ppm — the package manager

This package *is* ppm: the `ppm` command, its libraries (`~/.local/lib/ppm`) and its shell
integration all live under `home/` and are stowed onto the machine exactly like any other
package's files. It is one of the anfs toolkit's two base packages, with
[`anfs`](../anfs/README.md), which holds the source list and `anfs.conf` ppm reads.

That is deliberate. ppm has no separate update mechanism, no self-updater and no special case in
the installer beyond the first bootstrap: `ppm install anfs/anfs` is how ppm (and the whole toolkit) updates itself, and a
higher-priority repo can override any single file it ships — its default configuration, its shell
snippets — the same way it would override a file from any other package.

Run `ppm` for the command list and `ppm <command>` for its usage. What follows is what those
commands are for, not how to type them.

## Sources and Precedence

Packages — like containers, skills and spaces — come from source repositories, read from two
lists:

- `user.list` — yours, edited by `anfs src` (both live in `~/.config/anfs/`)
- `system.list` — the defaults, shipped by this package

The user list is read first, and within the merged result the order is the priority order. An alias
that appears in both lists is taken from yours, which is how you replace a default repo with your
own fork without editing a file ppm manages.

Priority matters because **a package can exist in several repos at once, and each copy is a
layer**. Installing `git` installs every `git` package in source order, sharing one ignore list, so
a file already placed by a higher-priority layer is skipped by the ones below it. The result is
per-file override: your repo can ship one line of git configuration and inherit everything else
from the shared repo. Installing a single layer by name (`ppm install pde/git`) deliberately
does not do this — it will conflict on files a higher layer owns, because that is the honest answer
when you ask for exactly one layer.

## Your Own Repo

`ppm customize` creates a git repository for this machine's customizations, registers it as the
`user` source at the top of your list, and moves your source list into it. From then on your
configuration has somewhere to live that is yours, versioned, and portable to the next machine by
URL.

The repo is ordinary — packages in it look like packages anywhere else. What makes it special is
only that it is always highest priority and that `ppm file claim` defaults to it.

## Owning Individual Files

There are three levels of ownership for any file ppm manages, because "ppm owns everything" and
"ppm owns nothing" are both wrong answers for a file you want to tweak:

- **ppm owns it** (the default) — a symlink into a package. Updates to the package change the file.
- **You own it in your repo** — `ppm file claim` copies the file into your repo and stows it from
  there, so it is still managed, still versioned, but now by you. This is the right answer when the
  change should follow you to other machines.
- **You own it locally** — `ppm file protect` turns the symlink into a plain file and detaches ppm
  from it entirely. ppm will never relink or force-remove it, including under `-f`. This is the
  right answer for something that is true of this machine only.

A file no package owns yet goes into a package with `ppm file add <repo/package> <file...>`: it
moves the files to the same path under the package's `home/`, creating the package if needed, and
stows them back. It takes files, not directories — `ppm file add spaces/frank .wsm/*` — so exactly
what the shell expanded is moved. `reset` undoes it, leaving plain files behind.

`ppm file reset` and `ppm file unprotect` walk each of those back. None of them touch git; the
commits in your repo are yours to make.

## Updates

`anfs src update` pulls every source repo, and **skips any repo with uncommitted changes**. That is
the point rather than a limitation: a source repo is usually one you are editing, and silently
merging into a dirty working tree is a good way to lose work. A skipped repo stays stale and is
retried next time.

`ppm install` updates repos on its own, but only those older than `ANFS_UPDATE_CACHE_DURATION`
(24 hours by default), so an install is not a network round trip for every repo every time.

## Declared Software, Not Installed Software

A package declares what it needs — Homebrew formulas, casks, distro packages, mise tools — in
`package.yml`, and ppm installs the missing ones in one batch per manager before any of the
package's hooks run. Hooks exist for the things that genuinely require code (starting a service,
generating a config file, running a vendor installer), not for installing software.

The reason for the split is that declarations can be reasoned about and hooks cannot: ppm can batch
them into a single sudo prompt, skip a package whose platform doesn't match, tell a non-owner which
formulas to ask the Homebrew owner for, and remove exactly what it installed when the package goes
away. A hook that shells out to `brew install` gives up all of that.

## Homebrew Ownership

Homebrew allows one owner per prefix. ppm treats that as a fact about the machine: the owner
installs and upgrades formulas, everyone else uses them. Second users need no sudo and get a clear
message naming the command the owner has to run, instead of a permission error from deep inside
`brew`.

## Shell Integration

Packages contribute shell snippets in three tiers, and ship only the ones they need:

| Where | Sourced by | For |
| --- | --- | --- |
| `~/.config/sh/` | bash and zsh | anything portable: aliases, exports, PATH, plain functions |
| `~/.config/zsh/` | zsh | zsh-only: completions, `mise activate zsh` |
| `~/.config/bash/` | bash | bash-only: `mise activate bash`, bash completions |
| `~/.config/fish/conf.d/` | fish itself | fish, which autoloads the directory |

Portable code goes in the first tier, which is what stops every package from triplicating the same
aliases into per-shell files.

This package's own snippet defines `ppm` as a shell function wrapping the script, for the two
things a subprocess cannot do to the shell that started it: `ppm cd` changes your directory, and a
successful `install`, `remove` or `src update` reloads your shell configuration, so a newly
installed package's aliases and completions work immediately instead of after the next login.

The shell *rc* files themselves belong to a shell package (`pde/zsh`, `pde/bash`), never to this
one. ppm must work on a machine with no shell package installed, so it ships snippets and lets
whoever owns `.zshrc` decide to source them. The dependency only runs one way: this package's
snippets use helpers from `pde/zsh` when they are present and degrade silently when they are not.

This package also ships mise's activation, because mise is part of ppm's bootstrap rather than a
package: `install.sh` installs it alongside `stow` and `yq`. Packages therefore declare the mise
*tools* they want and never depend on mise itself.
