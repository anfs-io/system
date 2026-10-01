# anfs — Agent Native Full Stack

## What This Is

anfs is a toolkit of bash tools that share one model of where things come from: **sources**.
A source is a git repo (or a local directory) that may hold any of:

| Top-level dir | Tool | What it holds |
| --- | --- | --- |
| `packages/` | `ppm` | software and dotfiles: GNU Stow plus install hooks (most of this file) |
| `containers/` | `pcm` | podman compose services (`containers/<name>/compose.yml`) |
| `skills/` | `psm` | agent skills (`skills/<name>/SKILL.md`) |
| `spaces/` | `wsm` | workspaces (`spaces/<name>/space.yml`) |

`anfs` owns the sources (`anfs src`) and the commands that span the tools: `anfs install
<source>` installs everything a source holds, tool by tool (ppm, pcm, psm, wsm), and `anfs
implode` runs every tool's `implode` in reverse, then deletes the sources. Picking single
resources is each tool's own `install` (`ppm install lgat/rails`, `pcm install lgat/postgres`,
`psm install lgat/skill`, `wsm install lgat/tech`; `source/` means all of that kind).

What the tools share lives in `lib/anfs/` and nothing else does: paths (`paths.sh`), the
source lists and clones (`sources.sh`), and finding resources plus ordering them by dependency
(`resolve.sh`). What `install` *does* stays in each tool.

## Repository Layout

Every source is cloned once under `~/.local/share/anfs/sources/`:

```
~/.local/share/anfs/sources/   (each directory is named by its source alias)
  anfs/             ← this repo (the toolkit itself)
  ai/ pdt/ pde/     ← default sources (system.list)
  user/             ← your customization repo: the "user" source, highest priority
```

This repo (`anfs/`) contains:
- `packages/anfs/` — the toolkit's own package: the `anfs` command, the libraries every tool
  sources (`~/.local/lib/anfs`: paths, sources, resolve), the source list and the toolkit's
  settings (`~/.config/anfs/{system.list,anfs.conf}`). It depends on every tool and what they run
  on, so `ppm install anfs/anfs` is the whole toolkit. Its `tests/` hold the shared-lib bats
  suites and the end-to-end round trip (Testing).
- `packages/ppm/` — ppm itself: the `ppm` command, its libraries (`~/.local/lib/ppm`) and its shell
  integration (`~/.config/{sh,zsh,bash}/{ppm,mise}.*`)
- `packages/{pcm,psm,wsm}` — the other tools, each its own package (deps, hooks, tests)
- `packages/{podman,varlock,node}` — the software the tools run on, part of the base install
- `packages/dev` — dev/test tooling: containers, macOS VMs, `ppm user`, `ppm move`, the git hooks
- `skills/` — the tools' own skills (`pcm-containers`), synced by psm like any source's
- `containers/` — the test boxes (`anfs-test-debian`, `anfs-test-fedora`) as pcm services
- `install.sh` — bootstrap installer for new machines (installs the irreducible prereqs —
  Homebrew, stow, yq, mise — clones this repo, stows the base packages `anfs/anfs` and `anfs/ppm`,
  then `ppm install anfs/anfs`)
- `chorus/units/` — development plans (Chorus methodology)

The tools don't declare `depends: [anfs]` although they source `lib/anfs`: anfs depends on them,
and like stow and yq it is base software that is always present.

Every tool, anfs included, keeps to `<dir>/<tool>`: `~/.local/bin/<tool>`, `~/.local/lib/<tool>/`,
and `$XDG_{CONFIG,DATA,STATE,CACHE}_HOME/<tool>/` for its own files. Nothing is namespaced under
anfs except anfs's own (the sources, the lists, `anfs.conf`).

## Configuration: anfs.conf

One file configures the whole toolkit: `~/.config/anfs/anfs.conf` (shipped by `anfs/anfs`, so a
higher layer — your `user/anfs` — can replace it) and `~/.config/anfs/anfs.local.conf` (this
machine only, seeded by install.sh with `PPM_GROUP_ID`). Every tool loads them through
`lib/anfs/paths.sh` (`anfs_load_conf`):

- Each variable is named for the tool that reads it: `PCM_HEALTH_TIMEOUT`, `PSM_CLI_VERSION`,
  `HOMEBREW_*` (ppm); `ANFS_` for what every tool shares (`ANFS_UPDATE_CACHE_DURATION`,
  `ANFS_QUIET_SKIPPED_REPOS`).
- **The environment wins**, then `anfs.local.conf`, then `anfs.conf`: a variable already set is
  never overwritten, so `PCM_HEALTH_TIMEOUT=300 pcm up x` does what it says.
- The files are read, not sourced: `NAME=value` lines, a value optionally quoted. A setting can't
  run code or clobber a variable a tool set itself.

## Package Structure

Each package is a directory under `<repo>/packages/<n>/`:

```
packages/<n>/
  package.yml     # metadata: version, author, depends
  install.sh      # optional: pre/post_install hooks, OS-specific install
  home/           # optional: stow target → $HOME
```

### package.yml

```yaml
version: 0.1.0
author: rjayroach
depends:
  - ruby
  - node
```

- `version` — semver; the patch level is auto-bumped by ppm's git hook (see Git Hooks)
- `author` — package author
- `depends` — list of package names (resolved across repos in source order)
- No `depends` key if package has no dependencies
- `meta` — free-form map that ppm never reads, for other packages to read. `ai/*` agent packages
  declare `meta: {agent: <skills-cli-id>}` (one id or a list), which `psm` targets. Package
  metadata goes here rather than in a new top-level key, which would be a declared resource.

Software a package needs is declared, not installed from hooks:

```yaml
platforms: [macos]          # optional: macos, linux, debian, fedora; omit = every platform

brew: [tmux, bat]           # list: every platform
cask: [claude-code]         # Homebrew casks install on Linux too; GUI apps need a map (below)

system:                     # distro package manager
  debian: [nfs-kernel-server]
  fedora: [nfs-utils]         # keys are platform() values: debian, fedora (or linux for any distro)

# a map picks per platform: exact platform first, then "linux" on any distro
brew:
  macos: [podman, podman-compose]
system:
  linux: [podman, podman-compose]
cask:
  macos: [ghostty]          # GUI apps: macOS only
```

- `ppm install` refuses packages whose `platforms` exclude this machine (`ppm install repo/` skips them), then installs what is missing in one batch per manager before any hook runs: system packages (one sudo prompt), brew formulas, casks (on macOS and Linux). Only the Homebrew owner installs brew/cask; other users get the command to ask for.
- A `system` map with entries for other distros but not this one (and no `linux` key) is an error.
- Mise tools: stow `home/.config/mise/conf.d/<tool>.toml`; after stowing, ppm runs `mise install` for the tools named in the resolved packages' toml files. mise itself is a **core ppm component** — `install.sh` brews it alongside stow and yq, and `anfs/anfs` ships its shell activation — so packages declare the *tools* they want and never `depends: [mise]`.
- Trackers record the formulas/casks ppm installed (`installed_deps`). `ppm remove` uninstalls them when no other installed package recorded or declares them. System packages are never removed.
- `-c` skips all of this, like hooks.

### Declared Resources (a package.yml key ppm core does not own)

ppm owns `version`, `author`, `depends`, `platforms`, `brew`, `cask`, `system` and `meta`
(`PPM_CORE_KEYS` in `packages.sh`). **Any other top-level key is a declared resource**: during
`install_single_package`, right after stow and before the `install_<os>`/`post_install` hooks, ppm
calls `ppm_resource_<key> <repo> <package> <package_dir>` — a function another package contributes
by stowing a file into `~/.local/lib/ppm/`. (wsm used to declare spaces this way, with a
`wsm:` key; spaces are now a source's `spaces/` directory, which is the better seam for anything
that is not a package: give it a top-level directory and a tool, not a package.yml key.)

- The handler records what it created with `meta_add_resource <repo> <pkg> <key> <path>`. That
  lands in the tracker under `resources:`, which `meta_mark_installed` preserves across the
  rewrite at the end of the install, and which `ppm show` prints.
- On remove, ppm calls `ppm_resource_<key>_remove <repo> <package>` and the handler reads the
  paths back with `meta_resources`. The keys come from the *tracker*, not from package.yml: the
  package directory may already be gone. With no `_remove` handler, ppm just reports the paths.
- **A key with no handler is reported** in the end-of-run messages, without failing the install:
  since `meta:` is where metadata for other packages belongs, an unowned top-level key is either a
  resource whose provider is not installed (add it to `depends:`) or a typo. Declaring something
  and silently doing nothing is the one outcome worth ruling out.
- A handler that fails is `ppm_fail`ed and the run continues: one unreachable git remote must not
  abandon the rest of the install or skip the tracker write.
- `-c` skips resources entirely, like hooks and declared deps.

Libraries a package stows into `~/.local/lib/ppm/` are **re-sourced as soon as they are
stowed** (`_reload_stowed_libs`), so `ppm install <thing that depends on a handler>` gets the
handler in that same run rather than needing a second one. That applies to contributed commands too.

Load order in that directory is a plain alphabetical glob, so a contributed lib is sourced after
ppm's own and *can* redefine core functions. Don't: `ppm_resource_<key>` is the supported seam,
and a redefinition silently wins over ppm core with no way to tell.

### install.sh Hooks

```bash
pre_install()      # runs before stow
install_macos()    # OS-specific install (brew)
install_linux()    # OS-specific install (apt)
post_install()     # runs after stow + OS install
pre_remove()       # runs before unstow
remove_macos()     # OS-specific removal
remove_linux()     # OS-specific removal
post_remove()      # runs after unstow
```

Hooks are for imperative work (services, generated config, vendor installers). Software a package needs is declared in `package.yml` (`brew`, `cask`, `system`) and installed by ppm before the hooks run.

Available functions packages can call from their hooks:
- `debug "message"` — log debug info (visible with `--debug` flag)
- `user_message "message"` — queue a message for the user (displayed after install completes). Supports `\n` for line breaks. Auto-prefixed with `[repo/package]`.
- `ppm_fail "message"` — signal a non-fatal install failure. Prints to stderr immediately and queues for end-of-run summary. Caller should `return` after calling.
- `_system_sudo "<what>" ["<message>"]` — obtain sudo for a hook that needs root. Returns 0 with the credential cache primed, so the real command can use `sudo -n` and never block an unattended install; on failure it `ppm_fail`s with `<message>` (default: the system-package wording) and returns 1. `pde/bash` uses it to write `/etc/shells`.
- `ppm_register_callback <function>` — call from `post_install` to hear about every later run
  (below). `ppm_unregister_callback` drops it.

### Post-run Callbacks

A package that reacts to *other* packages coming and going registers a function defined in its
own `install.sh`:

```bash
post_install() { ppm_register_callback psm_ppm_changed; }
psm_ppm_changed() { local event="$1"; shift; ... "$@" ... }   # event: install | remove
```

- Once a `ppm install` or `ppm remove` has finished everything (hooks, trackers, `mise install`),
  ppm calls each registered function once with the event and every `repo/pkg` that run installed
  (dependencies included) or removed. The registering package is in the list of the run that
  installs it, so that first callback can do the setup `post_install` would otherwise do.
- It runs like a hook: a subshell with the package's `install.sh` sourced and
  `PPM_CURRENT_PACKAGE` set to the registering package. A failing callback is `ppm_fail`ed and the
  others still run.
- Registrations live in `~/.local/state/ppm/installed/callbacks.yml` (`repo/pkg: function`).
  Removing the package drops its entry, so it is never called about its own removal.
- Not called with `-c`, and `-r`'s internal remove is not a removal.
- For a removal, the package directory normally still exists, so the callback can read the
  removed packages' `package.yml`. It is gone only if its repo was removed first.
- `ai/psm` uses this to sync skills when an agent package (`meta.agent`) is installed, and to
  unlink them (`psm agents rm`) when one is removed.

## Key Files

- `~/.config/anfs/system.list` — default sources, shipped/stowed by `anfs/anfs` (don't edit)
- `~/.config/anfs/user.list` — your sources (edited by `anfs src`); higher priority than system.list
- `~/.local/share/anfs/sources/<alias>/` — one clone per source; a local-path source is a link here
- `~/.cache/anfs/updated/<alias>` — each source's last successful clone/pull. `ppm install`,
  `pcm up`/`install` and `anfs install` auto-update only the sources older than
  `ANFS_UPDATE_CACHE_DURATION` (default 24h); a source skipped for uncommitted changes stays stale
  on its own and is rechecked next time. Install prints one `Not updated (uncommitted changes):
  <repos>` line for them; `ANFS_QUIET_SKIPPED_REPOS=true` in `anfs.conf` moves it to `--debug`
- `~/.config/anfs/anfs.conf` — settings for every tool (see Configuration)
- `~/.config/anfs/anfs.local.conf` — machine-local settings (not committed)
- `~/.local/state/ppm/installed/<repo>/<pkg>.yml` — per-package install tracker (version, timestamp, stowed files, `installed_deps`, `resources`)
- `~/.local/state/ppm/installed/callbacks.yml` — packages registered for post-run callbacks (`ppm_register_callback`)
- `~/.local/state/ppm/installed/protected.yml` — files `ppm file protect` detached from ppm; seeded into stow's ignore list so they are never re-linked
- `~/.local/bin/<tool>` — each stowed from its package (`anfs/anfs`, `anfs/ppm`, `anfs/pcm`, ...)
- `~/.config/sh/*.sh`, `~/.config/zsh/*.zsh`, `~/.config/bash/*.bash` — package-contributed shell snippets (see Shell Integration). `ppm.*` and `mise.*` come from `anfs/ppm`, `anfs.sh` from `anfs/anfs`
- `~/.local/lib/anfs/*.sh` — what every tool sources (paths, sources, resolve)
- `~/.local/lib/ppm/*.sh` — ppm's own libraries (stowed from `anfs/ppm`) plus package-contributed library extensions. Extensions add helpers for hooks (e.g. `pde/ruby`'s `install_gem`) or commands: a function named `foo` becomes `ppm foo` (e.g. `anfs/dev`'s `ppm user`)
- `~/.cache/ppm/brew_last_update`
- Each tool keeps its own state in its own XDG dirs: `$XDG_{CONFIG,DATA,STATE,CACHE}_HOME/<tool>`

## Shell Integration

ppm supports multiple shells by convention, not by machinery: a package ships one file per
shell it supports, and a file for a shell you don't use is simply never sourced. There are
three tiers under `$XDG_CONFIG_HOME`, and a package ships only the ones it needs:

| Path in the package | Sourced by | Holds |
| --- | --- | --- |
| `home/.config/sh/<name>.sh` | the bash **and** zsh rc | portable: aliases, exports, PATH, plain functions |
| `home/.config/zsh/<name>.zsh` | the zsh rc | zsh-only: completions, `mise activate zsh`, `$+functions` |
| `home/.config/bash/<name>.bash` | the bash rc | bash-only: `mise activate bash`, bash completions |
| `home/.config/fish/conf.d/<name>.fish` | fish itself | fish autoloads `conf.d`, so no rc glue is needed |

Rules:

- **Portable first.** Anything that works in both shells goes in `sh/`. Only genuinely
  shell-specific code gets a per-shell file. This is what stops every package from
  triplicating the same aliases.
- **Order is `sh/` then `<shell>/`.** A `sh/` file must not rely on a helper defined in a
  `<shell>/` file at *source* time; calling one at *runtime* is fine. `sh/ppm.sh` does exactly
  that: it defines the `ppm()` wrapper and calls `_ppm_shell_reload` (defined per shell) only
  after a successful `install`/`remove`/`src update`.
- **The rc file belongs to a shell package, never to `anfs/anfs`.** `pde/zsh` owns
  `.zshrc`/`.zshenv` and its sourcing loop; `pde/bash` owns `.bashrc`/`.bash_profile`. With no
  shell package installed nothing sources anything — `ppm` still works, but `ppm cd` and mise
  activation are absent. A rc that adds the `sh/` tier must also add it to any reload helper it
  ships (`pde/zsh` updates both `.zshrc` and `zsrc`).
- **The rc sets the base environment before it sources any snippet** — XDG vars, `$BIN_DIR`,
  Homebrew, `$BIN_DIR` first on PATH. It must not live in a snippet: snippets guard on
  `command -v <tool>`, so a tool that isn't on PATH yet makes them silently no-op. This is why
  `pde/zsh` keeps that block in `.zshrc` rather than in `aliases.zsh`, and `pde/bash` in
  `.bashrc`. Reloading must stay idempotent (`ensure_path` strips before prepending).
- **Re-assert Homebrew's PATH entries on every rc run, outside the `shellenv` guard.**
  `brew shellenv` forks, so it sits behind `if [ -z "$HOMEBREW_PREFIX" ]` — everything else it
  exports (`HOMEBREW_*`, `FPATH`, `INFOPATH`) survives being inherited, but PATH does not. macOS
  runs `/usr/libexec/path_helper` from `/etc/zprofile` and `/etc/profile` in *every* login shell,
  including nested ones (tmux starts one by default, as do `zsh -l`, ssh to self, and an editor's
  or agent's shell), and it rebuilds PATH with `/etc/paths` in front. A nested login shell
  inherits `$HOMEBREW_PREFIX`, the guard skips `shellenv`, and the demotion stands:
  `/opt/homebrew/bin` below `/bin`, so `bash` silently resolves to Apple's 3.2.57 again. Both rcs
  therefore call `ensure_path` on `$HOMEBREW_PREFIX/sbin`, then `$HOMEBREW_PREFIX/bin`, then
  `$BIN_DIR`, unconditionally. Each call prepends, so that order leaves `~/.local/bin` first.
- **`ensure_path` is rc-provided base API in both shells.** `.zshrc` and `.bashrc` each define it
  before their snippet loop, so a portable `sh/` snippet may call it, not only a `zsh/` or
  `bash/` one (`pde/ruby-tools` and `pdt/solana` do today from `.zsh`). The bash copy is written
  for bash 3.2.
- **A shell whose rc path is fixed has to move the distro's file aside.** `~/.bashrc` exists on
  stock Debian and Fedora, so `pde/bash`'s `pre_install` renames it to `.bashrc.pre-ppm` (and
  `post_remove` restores it); otherwise stow aborts the install and `-f` would delete it. Note
  that shipping `~/.bash_profile` also stops login bash from reading `~/.profile`, which is what
  puts `~/.local/bin` on PATH on Debian — another reason the rc owns the base environment.
- **The shell package owns the login shell.** `pde/zsh`'s `post_install` chsh's to the distro
  zsh; `pde/bash`'s does the same for `$(brew_prefix)/bin/bash`, **on macOS only**. There
  `/etc/shells` lists just `/bin/*`, and `chpass` rejects anything unlisted, so the hook
  registers the path first (`grep -qxF`, then `_system_sudo` and `sudo -n tee -a`) and only then
  chsh's — falling back to `sudo -n chsh -s <shell> <user>` because an unprivileged `chsh` cannot
  authenticate without a TTY. A macOS update rewrites `/etc/shells`, so re-running the install is
  what puts the entry back; every step is a no-op once settled. Register the brew *prefix*
  symlink: a `readlink -f` Cellar path breaks on the next `brew upgrade bash`, and
  `command -v bash` is worse still — hooks run under whatever bash won the PATH race, possibly
  the 3.2 being escaped. On Linux the distro bash is already 5.2+ and stays the login shell:
  brew's Linux prefix is under `/home` (may be unmounted at login via autofs or NFS), SELinux
  labels binaries there `user_home_t` not `shell_exec_t`, and brew may link its own glibc.
  Neither package rolls the login shell back on remove — `pde/bash` does not uninstall the
  formula, so the shell keeps working, and `/etc/shells` is machine-wide.
- **The rc only loads for interactive shells** (`case $- in *i*)` in bash, zsh's own rule for
  `.zshrc`). So `ssh host 'ppm ...'` gets the real `ppm` binary from PATH, not the wrapper, and
  no mise activation. Test with `bash -lic`, never `bash -lc`.
- **Glob two levels** (`*.sh` and `*/*.sh`), which is what packages actually use
  (`~/.config/zsh/op/`, `ssh/`, `ruby/`). Don't reach for bash's `globstar`: macOS ships bash
  3.2, which doesn't have it.
- **Guard every helper borrowed from another package.** `anfs/anfs`'s files use `pde/zsh`'s
  `zcomp`, `zsrc` and `load_conf` when present and degrade silently when not, because ppm must
  not depend on a package repo. The dependency is one-way: `pde/zsh` knows nothing of ppm.
- **Don't declare software the bootstrap owns.** `anfs/anfs` ships mise's activation but no
  `brew: [mise]`, and `pde/bash` declares no `brew: macos: [bash]` — both are untracked
  `install.sh` bootstrap formulas, and declaring them would let `ppm remove` uninstall what ppm
  itself runs on.

## Source Precedence

Sources come from two lists, read in priority order: `user.list` (yours) first, then
`system.list` (shipped defaults). An alias declared in both is taken from `user.list`.
`anfs src add/remove/ssh` only ever edit `user.list`; `anfs src list` shows both, with what each
source provides. The order is global — one order for every tool — and within it each tool sees
only the sources holding its directory. When a package exists in multiple repos, each copy is a
layer:

- `ppm install git` installs every `git` package in source order (e.g. `user/git`, then `pde/git`). The layers share one stow ignore list (`PPM_IGNORE_ARGS`), so files stowed by a higher-priority layer are skipped by lower ones. This lets personal repos override individual files.
- `ppm install pde/git` installs only that layer. It hits a stow conflict on files owned by a higher layer; this is intended.
- `anfs` is last in `system.list`, so every other source may layer over its packages and depend
  on what it ships (`depends: [node]` resolves to `anfs/node`).

## Your Customization Repo

The alias `user` (`PPM_USER_REPO_ALIAS` in `core.sh`) is always your own repo:

- `ppm customize` creates it locally: `git init` at `~/.local/share/anfs/sources/user`, an `anfs` package holding `user.list` (listing the repo itself, as a local path), registered at the top of `user.list`, then `ppm install -f user/anfs` swaps the plain `user.list` for a link into the repo. It is dispatched through `main()` because it calls `install`.
- Its `anfs` package is a layer of `anfs/anfs`, so files it ships win over the toolkit's defaults: its `user.list`, and its own `anfs.conf` for every tool's settings. One package is all a customization repo needs to configure the toolkit.
- `install.sh --repo <url>` registers that URL as `user` and installs `user/anfs` with `-f`.
- `ppm file claim` defaults to it.
- Local-path sources are never pulled: after pushing it, set the `user` line in `user.list` to the git URL.

## Homebrew Ownership

Homebrew supports one owner per installation (`/opt/homebrew` on Apple silicon macOS, `/home/linuxbrew/.linuxbrew` on Linux; Intel Macs are not supported). The user who installed it owns it and is the only one who installs, updates or upgrades formulas. Other users on the machine run the tools but never write to the prefix. ppm puts brew on PATH itself (`brew_env`), skips `brew update` for non-owners, and uses `brew_require_owner` to tell a non-owner which command the owner has to run.

## Claiming and Protecting Files

Three levels of ownership for an individual file: ppm owns it (default), *you* own it in
*your repo* (`claim`), or *you* own it locally with ppm detached (`protect`).

- `ppm file claim <file...> [--repo REPO] [--package NAME]` copies files into `REPO/NAME/home/` and stows them from there. The default repo is `$PPM_DEFAULT_REPO` (default `user`, settable in `anfs.conf`). The default package has the same name as the owning package. A new package with a different name gets `depends: [<owner>]`.
- `ppm file add <repo/package> <file...>` is `claim` for files no package owns yet (`ppm file claim <file...> --package repo/package`; `--package` accepts that form everywhere). The target is mandatory and the package is created if missing. Directories are refused: pass `dir/*` and let the shell expand it, so exactly the named files move. Stow's `--no-folding` keeps the directory real with a link per file, so files a tool creates there later stay local until added too.
- **Stowing a wsm marker (`<space>/.wsm/`)**: only for a space that is *not* itself a git repo, declared with `wsm:` *without* `repo_url`. Stow runs before declared resources, so a stowed `.wsm/` makes `ppm_resource_wsm` refuse the clone ("in the way and is not a git repo"). A space that is a git repo commits its own `.wsm/id`.
- Protected files are refused by `claim`/`add` (unprotect first): claim's stow does not use the protected ignore list.
- `ppm file reset <file...>` deletes the claimed copy, restores the owner's link, and removes the claimant package if it becomes empty.
- `ppm file protect <file...>` turns a package-managed symlink into a plain local copy (preserving its content) and records it in `protected.yml`. ppm then never re-links or force-removes it — including under `-f` — so you can customize it without a repo. The file is also dropped from its package's tracker.
- `ppm file unprotect <file...>` removes it from `protected.yml`; the next `ppm install -f <package>` re-links it.
- Claims are recorded in `~/.local/state/ppm/installed/claims.yml` (file → claimant, owner); protections in `~/.local/state/ppm/installed/protected.yml` (a plain list of `$HOME`-relative paths). The per-package trackers are updated to match.
- None of these touch git. Commit the changes in the repo yourself.

## Dependencies

- `yq` (mikefarah/yq) — for YAML parsing of package.yml and tracker files
- `stow` — GNU Stow for symlink management
- `git` — repo cloning and updates

## Development

Plans are in `chorus/units/`. Follow the Chorus methodology:
1. Read the unit `.md` for objectives
2. Read the plan's `plan.md` for implementation spec
3. Implement and test
4. Write `log.md` on completion

### Git Hooks

`anfs/dev` ships a `pre-commit` hook that bumps a package's patch version when a commit touches
it, and creates `package.yml` for a package that has none. The files live in the package at
`packages/dev/home/.config/git/ppm-hooks/` and are stowed to `~/.config/git/ppm-hooks/`.

`ppm hooks` wires them up, because **git does not carry hooks through a clone** — so this is an
install step, not repo content:

```
ppm hooks                        # status (default)
ppm hooks install [--all] [repo...]
ppm hooks uninstall [--all] [repo...]
```

With no repo names it acts on the `system.list` repos; `--all` adds your `user.list` ones.
`anfs/dev`'s `post_install` runs `ppm hooks install`, and its `post_remove` runs
`ppm hooks uninstall --all`. Re-run `ppm hooks install` after `anfs src add`, since `post_install`
can't know about a repo added later.

How it is wired, and why:

- Each repo gets **`core.hooksPath` set locally**, pointed at the stowed directory. Pointing at
  the stowed path (not into the package) means editing a hook takes effect in every repo at once,
  and a higher-priority layer can override a single hook file through stow.
- **Never set `core.hooksPath` globally.** A global value applies to every repo on the machine
  *and* suppresses each repo's own `.git/hooks`, which would silently disable husky/lefthook/
  overcommit in unrelated projects. `init.templateDir` is no good either: it copies at
  `git init`/`clone` only, isn't retroactive, and the copies go stale.
- `core.hooksPath` replaces a repo's `.git/hooks` wholesale, so `ppm hooks install` warns when
  the repo already has real hooks there, and leaves a `core.hooksPath` it didn't set alone.
  `uninstall` only unsets the value ppm wrote.
- A `core.hooksPath` pointing at a missing directory is harmless — git finds no hooks and commits
  normally — so a leftover setting can never block a commit.

The bump rule is **once per unpushed series**: the hook compares the working version against the
version at the push base (`@{upstream}`, else `origin/HEAD`/`main`/`master`) and only bumps when
they match. So a run of commits before one push bumps once, `git commit --amend` doesn't bump
again, and a version you set by hand is respected. A repo with nothing pushed yet has had zero
pushes, so it gets zero bumps: a new package settles at `0.1.0` and stays until its first push.
A version that isn't `N.N.N` is left alone rather than mangled.

`lib/package-meta.sh` next to the hook is deliberately standalone — it uses `sed` rather than
`yq` so a hook never depends on ppm's environment, and it stays out of `~/.local/lib/ppm/`
because its `meta_*` names would share a namespace with `packages.sh`'s.

### Moving a Package Between Repos

`anfs/dev` ships `ppm move`, which relocates a package from one source repo to another. The files
live in the package at `packages/dev/home/.local/lib/ppm/move.sh`, stowed to
`~/.local/lib/ppm/move.sh` — a function named `move` there becomes `ppm move`, like `ppm hooks`
and `ppm user`.

```
ppm move <repo/package> <target-repo>      # e.g. ppm move pde/rails pdt
  -f, --force   move despite uncommitted changes or a broken dependency
```

It unstows the package, moves the directory, stows it again from its new home, moves the install
tracker (`installed/<repo>/<pkg>.yml`, keeping its version, files and `installed_deps`), repoints
any `claims.yml` entry that names the package as claimant or owner, and commits both repos. The
source spec must be fully qualified: a bare name matches a layer in every repo.

- **Install hooks are not re-run.** The package's content is unchanged, only its path, so
  `pre_remove`/`post_install` would tear down services and rewrite generated config for nothing.
- **Restowing is not a plain `stow_package`.** `stow -D` only removed the links that point into
  *this* package dir, so re-stowing the whole directory would collide with the files a
  higher-priority layer owns. The tracker lists what this layer actually had, so `move` stows with
  the *complement* as the ignore list — which also leaves `ppm file protect`ed files alone. stow
  aborts the whole operation on the first conflict, so a failed stow rolls the move back; if the
  same conflict then fails the restore, it says to run `ppm install -f <pkg>`.
- **It refuses a move that would break a dependent**, unless `-f`. `_resolve_one` passes the
  depending layer's repo index as `min_index`, so a dependency only ever resolves to the same or a
  lower-priority repo — moving a package *up* in priority orphans anything below it that depends
  on it. `depends:` names a package, not a repo, so no dependent needs editing otherwise; there is
  deliberately no rename.
- **It refuses a repo with uncommitted changes**, unless `-f`. The commits are pathspec-limited to
  `packages/<pkg>`, so even under `-f` unrelated changes stay out of them, and the index is
  re-added afterwards because a partial commit leaves the pre-hook content staged for whatever the
  `pre-commit` hook rewrote (the version bump).
- **An existing package of that name in the target is refused outright**, `-f` included: `-f` must
  never overwrite package sources.

### Lib Structure

ppm is the `anfs/ppm` package: the `ppm` script and its libraries live under
`packages/ppm/home/` and are stowed to `~/.local/bin/ppm` and `~/.local/lib/ppm/`
(its shell snippets go to `~/.config/{sh,zsh,bash}/` — see Shell Integration). What every tool
shares is the `anfs/anfs` package's `~/.local/lib/anfs/`.
The `ppm` script holds only bootstrap: paths, library sourcing, flag parsing and dispatch. Each
command lives in the lib file for its area, next to its helpers:

```
packages/anfs/home/.local/lib/anfs/     what every tool sources
  paths.sh     # ANFS_* paths, anfs_tool_paths <tool> (<TOOL>_{CONFIG,DATA,STATE,CACHE}_HOME),
               # anfs_load_conf (anfs.local.conf, anfs.conf; the environment wins)
  sources.sh   # gitsrc_*: source lists, clone/pull/link, status, provides, the `src` command;
               # anfs_gitsrc_env points it at anfs's lists
  cli.sh       # the command line: cmd_<name> functions, cli_cmd registry (help and zsh
               # completion are generated from it), cli_alias, cli_dispatch
  resolve.sh   # anfs_sources <dir>, anfs_find, anfs_list, anfs_resolve <dir> <deps_fn> (layered
               # topo sort with the same-or-lower-priority dependency rule; ANFS_RESOLVE_FIRST for
               # kinds that don't layer)
packages/ppm/home/.local/lib/ppm/
  core.sh        # API for package hooks: os(), arch(), add_to_file(), remove_from_file(),
                 # debug(), user_message(), ppm_fail()
  platform.sh    # platform() (macos/debian/fedora), system_pkg_*() (apt/dnf), _system_sudo(), brew_prefix(), brew_env(), brew_owner(),
                 # brew_is_owner(), brew_require_owner(), update_brew_if_needed()
  sources.sh     # customize; collect_repos() (the sources holding packages/), update_ppm_if_needed()
  packages.sh    # list, show, path, deps; collect_packages(), find_package_dirs() and resolve_deps()
                 # (over resolve.sh), package.yml reads, install trackers
  installer.sh   # install, remove; install_single_package(), remover(), stow_package(), PPM_IGNORE_ARGS,
                 # _install_declared_resources()/_remove_declared_resources(), _reload_stowed_libs()
  file.sh        # file claim|reset|protect|unprotect (file_command), claims.yml, protected.yml
  implode.sh     # implode: every installed package removed, dependents first, then ppm's dirs
  completion.sh  # completion
```

Rules for `lib/anfs`: it only defines functions (and paths.sh its variables), depends on no tool
(`debug` is used only if defined), takes its configuration from its own variables (`GITSRC_*`),
and runs under bash 3.2 with `set -euo pipefail`. Every tool sources it from `~/.local/lib/anfs`
and nowhere else.

**Every tool's command line is `cli.sh`'s.** A command is a function named `cmd_<name>`; the tool
registers each public one with `cli_cmd <name> "<usage>" "<summary>"` in the order its help lists
them, and `cli_dispatch` runs it. Help and the zsh completion's command list are generated from
that registry, so neither can drift from what exists. A `cmd_` function left unregistered still
runs (plumbing such as `psm path`), and *only* `cmd_` functions run, so a tool's internals are
never reachable from its command line — and a command can never shadow a system binary in package
hooks (`install`, `file`). An extension registers its command where it defines it: `anfs/dev`'s
`container.sh` calls `cli_cmd container ...` next to `cmd_container`. What stays each tool's own
is how it parses its flags.

Flags (`force`, `config`, `reinstall`, `skip_deps`, `yes`) are locals of `main()` that commands read through dynamic scoping.

Library sourcing in `ppm`: every `*.sh` in `$PPM_LIB_DIR` (`~/.local/lib/ppm/`) is
sourced. That directory holds both ppm's own core libraries (stowed from `anfs/ppm`)
and package-contributed extensions (e.g. `anfs/dev`'s `container.sh`, `vm.sh` and `hooks.sh`). During a fresh
install `install.sh` sources the core libs directly from the clone and stows `anfs/anfs` and `anfs/ppm`
so they are present before `ppm` first runs.

### Testing

Unit tests are bats, no network (local bare repos over file://):

```
bats packages/anfs/tests     # lib/anfs: sources.sh, resolve.sh
bats packages/ppm/tests      # ppm: callbacks, meta
bats packages/pcm/tests      # pcm: sources, validate, remove
bats packages/psm/tests      # psm: skills from sources, install, implode (skills CLI stubbed)
bats packages/wsm/tests      # wsm: registry, scan, install (space.yml, dependencies)
```

End to end, on a fresh Linux box:

```
packages/anfs/tests/roundtrip [debian|fedora] [source...]
    # install.sh, ppm install ai/pi, anfs install acme (or the named sources), checks,
    # anfs implode, then $HOME diffed against its pre-install state
```

- `packages/anfs/tests/harness` builds and runs the same boxes as `ppm container` (the repo's
  `containers/anfs-test-<distro>/Containerfile`) with podman alone, so changing anfs — pcm
  included — can never break the thing that tests it. `--nested` runs the box privileged with
  `/dev/fuse`, which is what rootless podman inside it needs (pcm's containers really start in
  the round trip).
- `--all` holds `$HOME` to the stricter standard of `anfs implode --all`, and `--scratch` starts
  from a bare image so install.sh installs Homebrew itself (and `--all` must remove it).
- `packages/anfs/tests/fixtures/acme` is a stand-in org source with every resource kind: a package depending on
  another source's, a container, a skill, and spaces that depend on each other.
- The round trip starts from a `bootstrap` snapshot (Homebrew, stow, yq, mise; passwordless sudo),
  built on first use, and tests a copy of `~/anfs-dev/*` (`ROUNDTRIP_SRC_ROOT`).
- Anything the diff reports is a tool writing outside its own directories, or an implode missing
  it. What implode keeps on purpose (Homebrew and its caches, mise's tools, podman's storage,
  GitHub's host keys, space contents) is listed in the script's `IGNORE_RE`.

`anfs/dev` provides the throwaway machines to validate them on. `ppm container` (Debian, Fedora; the
boxes are pcm services, `containers/anfs-test-<distro>`) and
`ppm vm` (macOS on Apple silicon, via tart) share one contract: two test users, `owner` (sudo with
a password) and `other` (none), and the host's source repos mounted **read-only at `/src/<alias>`**,
so a box tests the working tree rather than the pushed repos. `ppm user` makes a throwaway user on
the host instead, which is the cheapest way to exercise the non-owner Homebrew path.

Both harnesses link the mounted sources into `~/.local/share/anfs/sources` and list them in
`~/.config/anfs/user.list` *before* `install.sh` runs, which would otherwise clone anfs from GitHub
and test the pushed repo instead of the mount.

`ppm vm` differs from `ppm container` in four places, each forced by the platform rather than by
taste (see `chorus/units/testing/01-macos-vm/` for the evidence):

- **`/src` comes from `/etc/synthetic.conf`**, realized at boot. tart mounts shares under
  `/Volumes/My Shared Files/<name>`, and `collect_repos` splits source lines on whitespace, so a
  path with spaces is unusable; `/` is read-only, so the link cannot be made directly.
- **A snapshot recreates the box rather than restarting it.** `tart clone` of a stopped VM captures
  its state correctly, but the restarted original has been observed to come back without those
  writes. `_vm_shutdown` also shuts the guest down from inside and waits, because `tart stop` can
  return while writes are still buffered and the clone then catches an older APFS checkpoint.
- **Provisioning raises sudo's `timestamp_timeout`.** `_system_sudo` primes the cache then uses
  `sudo -n`, but macOS defaults to 5 minutes with per-tty tickets and there is no tty over ssh, so
  a cold run outlives it. The password stays — the prompt is part of what is being tested.
- **ssh re-parses the remote command line** where `podman exec` passes argv straight through, so
  multi-word values travel as env vars, not positional arguments.

`vm.sh` runs under ppm's `set -euo pipefail`, so every best-effort `tart` call needs an explicit
guard (`tart delete` on a missing VM exits 2 and would otherwise kill the command mid-run).
