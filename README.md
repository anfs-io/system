# anfs — Agent Native Full Stack

anfs makes a machine reproducible from git repositories you control — not just its dotfiles and
tools, but its services, its agents' skills and its workspaces. It is a small toolkit of bash
tools that share one idea of where things come from:

| Tool | Reads | Does |
| --- | --- | --- |
| `ppm` | `packages/` | software and dotfiles: a manifest of what a package needs, files symlinked with GNU Stow |
| [`pcm`](packages/pcm/README.md) | `containers/` | podman compose services, with their configuration schema and dependencies |
| `psm` | `skills/` | agent skills, synced to every AI agent installed |
| `wsm` | `spaces/` | workspaces: where they live, what they depend on, the repos inside them |
| `anfs` | — | the sources every tool reads, and the commands that span them |

A **source** is one repo that may hold any of those directories, so an organization can ship its
whole stack — the toolchain, the database, the skills, the workspaces — as a single repo:

```bash
anfs src add git@github.com:lgat/lgat-anfs.git lgat
anfs src update lgat
anfs install lgat          # its packages, containers, skills and spaces, in that order
```

Each tool still picks single resources on its own: `ppm install lgat/rails`,
`pcm install lgat/postgres`, `wsm install lgat/tech`.

Two ideas shape everything else:

- **Your repo wins.** Sources are layered in priority order, and the layering is per resource
  (per file, for packages), so you can override one thing from a shared repo without forking it.
- **A machine is disposable.** Everything that makes a machine yours is committed somewhere, so a
  new one is a single install command away — and `anfs implode` takes one back to vanilla, which
  is how the toolkit proves it only writes where it says it does.

anfs manages itself as a package, so it updates like anything else it installs.

## Quick Start

**macOS**
```bash
curl -fsSL https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh | bash
```

**Debian 13**
```bash
wget -qO- https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh | bash
```

**Fedora**
```bash
curl -fsSL https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh | bash
```

Run it as your normal user, not root. Open a new shell when it finishes, then `anfs src list` to
see the sources, `ppm list` to see what packages are available, and `anfs` on its own for the
commands.

## Getting Started

`ppm list` shows every package available to you, `ppm list @` the categories they are grouped in
(`ppm install @ai` installs one), and `ppm show <package>` explains one. A package
brings its own software with it — you never install the tool and its configuration separately —
and several can be named at once. Some places to start:

**A terminal you'd want to live in**

```bash
ppm install zsh tmux nvim git
```

zsh with oh-my-zsh and powerlevel10k, and the rc file that sources everything else ppm installs;
tmux with tmuxinator for per-project window layouts; neovim with a working plugin set and
configuration rather than an empty `init.lua`; git configuration, a system-wide `.gitignore` and
GitHub's `gh`.

**Secrets and ssh, without private keys on disk**

```bash
ppm install op fnox ssh ghostty
```

1Password's CLI and desktop app, with ssh pointed at the 1Password agent so your keys never touch
the filesystem, and a service account token that follows you onto remote hosts so `op` works there
too. `fnox` is where a project declares which secrets it needs; `ssh` adds the hook registry those
integrations plug into, plus mounting remote directories over sshfs. `ghostty` is a macOS-only
terminal, and ppm will simply skip it elsewhere.

**Languages, managed by mise**

```bash
ppm install ruby node python
```

Each installs a current runtime through mise and puts the shell activation in place, so versions
are per project rather than per machine.

**Then make it yours**

```bash
ppm customize
```

This creates a git repo for your own machine configuration and puts it at the top of your source
list, so from then on your packages and your edits override the shared ones — file by file, without
forking anything. It is the step that turns ppm from someone else's setup into yours, and it is
what lets the next machine be one command. See
[the `ppm` package](packages/ppm/README.md#your-own-repo).

## What the Installer Does

The installer is the only part of ppm that has to work on a machine with nothing on it, so it
installs the irreducible prerequisites and then hands over to ppm itself:

- Homebrew's prerequisites (Debian: `build-essential procps curl file git`; Fedora:
  `gcc gcc-c++ make procps-ng curl file git`; macOS: the Xcode Command Line Tools)
- Homebrew, if the machine has none — then `stow`, `yq` and `mise` from it, plus a current `bash`
  on macOS, where the system copy is still 3.2
- GitHub's published SSH host keys, added to `~/.ssh/known_hosts`
- anfs itself, by stowing its two base packages, [`anfs`](packages/anfs/README.md) and
  [`ppm`](packages/ppm/README.md), which is what puts `anfs` and `ppm` on your PATH and seeds
  `~/.config/anfs/` (your source list, `anfs.local.conf`)
- `anfs src update`, then any packages you named, then `ppm install core/anfs`: the rest of the
  toolkit — `pcm`, `psm`, `wsm` — and the software they run on (podman, varlock, node). On macOS
  the podman machine is created the first time `pcm up` needs it, not at install.

It asks for your sudo password at most once, and only when something above is actually missing.
Passwordless sudo is not required, and re-running it on a machine that is already set up prompts
for nothing.

## Multiple Users on One Machine

Homebrew supports one owner per installation, and ppm follows that rule rather than fighting it.
The first user to run the installer owns Homebrew and is the only one who installs or upgrades
formulas. Everyone else runs the installer too — they get their own ppm, their own packages and
their own dotfiles, using the owner's Homebrew tools without writing to it, and needing no sudo at
all. When a package needs a formula that isn't installed, ppm tells the second user which command
to ask the owner to run.

## A New Machine From Your Own Repo

Once you have a customization repo (see [`ppm customize`](packages/ppm/README.md#your-own-repo)),
pass its URL to the installer. It is registered as the `user` source — the highest priority one —
and its `anfs` package is installed, which brings your source list and settings with it:

```bash
curl -fsSL https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh | bash -s -- \
  --repo git@github.com:user/my-ppm
```

Trailing arguments name packages to install, and the same thing can be said with environment
variables, which is easier to paste into a fresh shell:

```bash
export ANFS_INSTALL_REPO=git@github.com:user/my-ppm
export ANFS_INSTALL_PACKAGES="git nvim zsh"
curl -fsSL https://raw.githubusercontent.com/anfs-io/system/refs/heads/main/install.sh | bash
```

If your repo is private, the installer can only clone it once the machine can authenticate to
GitHub. When the key lives in 1Password, install its packages from
[stack](https://github.com/anfs-io/stack) first (`ppm install op ssh`), authorize the CLI from
the 1Password desktop app, and then register the repo by hand:

```bash
anfs src add --top git@github.com:user/my-ppm user
anfs src update user
ppm install -f user/anfs
```

## Advanced Installation

- `--script-only` installs anfs and ppm and stops, without installing any packages (or the rest
  of the toolkit).
- `--skip-deps` skips the prerequisites and Homebrew entirely, for a machine where you manage them
  yourself. ppm still needs `git`, `stow` and `yq` on your PATH.
- To read the script before running it, download it, `chmod +x` it and run it — the one-liners
  above are a convenience, not a requirement.

## Removing It All

```bash
anfs implode            # every tool's implode, then the sources; asks first (-y to skip)
anfs implode --all      # also stow, yq and mise (and bash on macOS) from Homebrew
```

wsm forgets its workspaces (their contents are kept), psm removes every skill, pcm deletes its
containers, networks and data, and ppm removes every package it installed — the toolkit included —
and the Homebrew formulas it installed for them. Homebrew itself is kept. Each tool's `implode`
also works on its own.

## Packages in This Repo

| Package | What it is |
| --- | --- |
| [`anfs`](packages/anfs/README.md) | the anfs command, the libraries every tool shares, the source list and `anfs.conf`; depends on everything below |
| [`ppm`](packages/ppm/README.md) | the package manager: its command, libraries and shell integration |
| [`pcm`](packages/pcm/README.md) | Personal Container Manager |
| `psm` | Personal Skills Manager |
| [`wsm`](packages/wsm/README.md) | work space manager |
| `podman`, `varlock`, `node` | what pcm and psm run on |
| [`dev`](packages/dev/README.md) | tooling for working on anfs: disposable test machines and the git hooks that version packages |

The repo's `skills/` holds the tools' own skills (`pcm-containers`); `packages/anfs/tests/` the
end-to-end round trip (see CLAUDE.md, Testing).

## Sources

anfs ships a default source list and reads yours first. In priority order:

| Repo | Alias | Contents |
| --- | --- | --- |
| [stack](https://github.com/anfs-io/stack) | `stack` | the packages (grouped by category: `ppm list @` to see them, `ppm install @ai` for one), `containers/` and `skills/` |
| [system](https://github.com/anfs-io/system) | `core` | this repository — last, so everything may layer over it |

`anfs src list` shows what each source provides. See each repo's README for what it holds, and
[the `ppm` package](packages/ppm/README.md#sources-and-precedence) for how the lists are
merged and how one source overrides another.
