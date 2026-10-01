# Personal Package Manager

ppm keeps your dotfiles and tool configuration in git repositories you control, and reproduces a
machine from them. A package is a directory of files to be symlinked into `$HOME` plus a manifest
of the software it needs; ppm resolves dependencies across repositories, installs what is missing
through the platform's package managers, and links the files with GNU Stow.

Two ideas shape everything else:

- **Your repo wins.** Repositories are layered in priority order, and the layering is per file, so
  you can override one file from a shared repo without forking it.
- **A machine is disposable.** Everything that makes a machine yours is committed somewhere, so a
  new one is a single install command away.

ppm manages itself as a package, so it updates like anything else it installs.

## Quick Start

**macOS**
```bash
curl -fsSL https://raw.githubusercontent.com/maxcole/ppm/refs/heads/main/install.sh | bash
```

**Debian 13**
```bash
wget -qO- https://raw.githubusercontent.com/maxcole/ppm/refs/heads/main/install.sh | bash
```

**Fedora**
```bash
curl -fsSL https://raw.githubusercontent.com/maxcole/ppm/refs/heads/main/install.sh | bash
```

Run it as your normal user, not root. Open a new shell when it finishes, then `ppm list` to see
what is available and `ppm` on its own for the commands.

## Getting Started

`ppm list` shows every package available to you and `ppm show <package>` explains one. A package
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
[the `system` package](packages/system/README.md#your-own-repo).

## What the Installer Does

The installer is the only part of ppm that has to work on a machine with nothing on it, so it
installs the irreducible prerequisites and then hands over to ppm itself:

- Homebrew's prerequisites (Debian: `build-essential procps curl file git`; Fedora:
  `gcc gcc-c++ make procps-ng curl file git`; macOS: the Xcode Command Line Tools)
- Homebrew, if the machine has none — then `stow`, `yq` and `mise` from it, plus a current `bash`
  on macOS, where the system copy is still 3.2
- GitHub's published SSH host keys, added to `~/.ssh/known_hosts`
- ppm itself, by stowing the [`system`](packages/system/README.md) package, which is what puts
  `ppm` on your PATH and seeds `~/.config/ppm/`
- `ppm src update`, then any packages you named (none by default)

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

Once you have a customization repo (see [`ppm customize`](packages/system/README.md#your-own-repo)),
pass its URL to the installer. It is registered as the `user` source — the highest priority one —
and its `system` package is installed, which brings your source list with it:

```bash
curl -fsSL https://raw.githubusercontent.com/maxcole/ppm/refs/heads/main/install.sh | bash -s -- \
  --repo git@github.com:user/my-ppm
```

Trailing arguments name packages to install, and the same thing can be said with environment
variables, which is easier to paste into a fresh shell:

```bash
export PPM_INSTALL_REPO=git@github.com:user/my-ppm
export PPM_INSTALL_PACKAGES="git nvim zsh"
curl -fsSL https://raw.githubusercontent.com/maxcole/ppm/refs/heads/main/install.sh | bash
```

If your repo is private, the installer can only clone it once the machine can authenticate to
GitHub. When the key lives in 1Password, install its packages from
[pde-ppm](https://github.com/maxcole/pde-ppm) first (`ppm install op ssh`), authorize the CLI from
the 1Password desktop app, and then register the repo by hand:

```bash
ppm src add --top git@github.com:user/my-ppm user
ppm src update user
ppm install -f user/system
```

## Advanced Installation

- `--script-only` installs ppm and stops, without installing any packages.
- `--skip-deps` skips the prerequisites and Homebrew entirely, for a machine where you manage them
  yourself. ppm still needs `git`, `stow` and `yq` on your PATH.
- To read the script before running it, download it, `chmod +x` it and run it — the one-liners
  above are a convenience, not a requirement.

## Packages in This Repo

| Package | What it is |
| --- | --- |
| [`system`](packages/system/README.md) | ppm itself — the script, its libraries, its default configuration and its shell integration |
| [`dev`](packages/dev/README.md) | tooling for working on ppm: disposable test machines and the git hooks that version packages |

## Package Repositories

ppm ships a default source list and reads yours first. In priority order:

| Repo | Contents |
| --- | --- |
| [ai-ppm](https://github.com/maxcole/ai-ppm) | AI tooling |
| [pdt-ppm](https://github.com/maxcole/pdt-ppm) | Product Development Toolkit |
| [pde-ppm](https://github.com/maxcole/pde-ppm) | Personal Development Environment |
| [ppm](https://github.com/maxcole/ppm) | this repository |

See each repo's README for the packages it provides, and
[the `system` package](packages/system/README.md#sources-and-precedence) for how the lists are
merged and how one repo overrides another.
