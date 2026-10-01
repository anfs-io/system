---
objective: Shell snippet load order is declared and enforced, and provenance is queryable
status: proposed
---

# Shell Snippet Load Order & Namespacing

A protocol for how packages contribute files to `~/.config/{sh,zsh,bash}/`, what
determines the order they load in, and how a personal repo extends a package's snippet
without replacing it.

Read this alongside the **Shell Integration** and **Source Precedence** sections of
`CLAUDE.md`, which this proposal amends.

---

## 1. Problem

### 1.1 Load order is accidental, not declared

`.zshrc:181` sources snippets with a single sorted glob:

```zsh
for file in $SH_CONFIG/**/*.sh(N) $ZSH_CONFIG/**/*.zsh(N); do
```

This is deterministic — zsh sorts glob results lexicographically by full path — but the
order carries no meaning. Nothing declares that one file must precede another, so nothing
protects the order when a file is added or renamed.

The load-bearing dependency today: `pde/zsh`'s `aliases.zsh` defines `zcomp` (line 13),
`load_conf`, `os` and `zsrc`. Eight files call `zcomp` **unguarded at source time**:

```
fnox.zsh  op.zsh  pcm.zsh  podman.zsh  psm.zsh  solana.zsh  ruby/tools.zsh
```

They work only because `aliases` sorts before all of them. Two other files —
`ppm/system`'s `mise.zsh:8` and `ppm.zsh:7` — wrap the same call in
`(( $+functions[zcomp] )) &&`. That guard is the tell: the order was already known to be
untrustworthy, and the workaround was applied in two places out of ten.

### 1.2 zsh and bash already disagree

`.zshrc:181` uses zsh's recursive `**/`, which **interleaves** subdirectory files into the
sort by full path. `pde/bash`'s `.bashrc:71-72` uses two sequential globs
(`*.sh` then `*/*.sh`), which loads **all** top-level files before **any** subdirectory
file. Verified:

```
files: mise.sh, zz.sh, sub/aaa.sh

zsh   ->  mise.sh  sub/aaa.sh  zz.sh
bash  ->  mise.sh  zz.sh       sub/aaa.sh
```

The shared `~/.config/sh/` tier therefore loads in a different order depending on which
shell reads it. No snippet depends on this today, so it is latent rather than broken.

### 1.3 Provenance is invisible

`~/.config/zsh/` is a flat directory of 40 symlinks. Answering "which repo shipped
`op.zsh`?" means `ls -l` and reading a path. Answering "which layer won?" is harder still.

### 1.4 The obvious fix is wrong

The instinct is to namespace by source repo: `~/.config/zsh/user/rjayroach.zsh`,
`~/.config/zsh/pde/git.zsh`. Three reasons not to:

1. **It breaks the config immediately.** Under stow, a package's path *is* its `$HOME`
   path, so the repo alias becomes part of the sort key. `ai/psm.zsh` would then sort
   before `pde/aliases.zsh`, `zcomp` would be undefined, and the call would silently
   no-op. Section 1.1 is a precondition for any namespacing work, not a separate task.

2. **It breaks layering.** ppm's override model is "a higher-priority layer ships the same
   `$HOME` path and wins via the stow ignore list" (`CLAUDE.md`, Source Precedence). If
   the path encodes the repo alias, `user/…/zsh/user/git.zsh` and `pde/…/zsh/pde/git.zsh`
   are different paths, both get stowed, and file-level override stops working.

3. **It breaks `ppm move`.** `ppm move pde/rails pdt` relocates a package without touching
   its content — deliberately. A repo alias baked into a file path would make every move a
   content change.

**Conclusion: namespace by phase, not by source. Serve provenance from a query, not from a
directory name.**

### 1.5 Layering is barely used

Across all seven repos, exactly one path is shipped by more than one package:

```
.config/ppm/ppm.conf  ->  ppm/system  user-ppm/ppm  user/system
```

A config file, where whole-file replacement is correct. **No `.zsh` snippet has ever been
layered.** There is no installed behaviour to preserve here; the convention is free to be
set correctly the first time.

---

## 2. Design

### 2.1 Phase bands

Packages ship into a numbered band directory instead of the tier root. The band is
identical across `sh/`, `zsh/` and `bash/`.

| Band | Holds | Rule |
| --- | --- | --- |
| `00-env` | exports, `ensure_path`, PATH construction | No `command -v` guards — PATH is not final yet |
| `10-lib` | functions other snippets call **at source time**: `zcomp`, `load_conf`, `os`, `zsrc` | Definitions only, no side effects |
| `20-tools` | per-tool activation and config, guarded on `command -v` | May call anything from `10-lib` |
| `30-ui` | keybindings, prompt, fzf, interactive aliases | Last band that assumes nothing about other bands |
| `80-user` | repo-tracked personal overrides | Runs after everything; exempt from §2.2 |
| `90-local` | machine-local, uncommitted | Runs last; exempt from §2.2 |

A path sort puts the band first, so the band dominates ordering. Six buckets is few enough
that the choice is obvious and nobody negotiates a seventh.

Example placements from the current tree:

```
pde/zsh   aliases.zsh   ->  home/.config/zsh/10-lib/aliases.zsh
pde/zsh   zsh.zsh       ->  home/.config/zsh/30-ui/zsh.zsh
pde/zsh   p10k.zsh      ->  home/.config/zsh/30-ui/p10k.zsh
ppm/sys   mise.zsh      ->  home/.config/zsh/20-tools/mise.zsh
pde/git   git.zsh       ->  home/.config/zsh/20-tools/git.zsh
pde/op    ssh/op.zsh    ->  home/.config/zsh/20-tools/ssh-op.zsh
user/zsh  rjayroach.zsh ->  home/.config/zsh/80-user/rjayroach.zsh   (see §3.4)
```

Because every package ships the same path in every repo
(`20-tools/git.zsh`, not `pde/20-tools/git.zsh`), layering and `ppm move` are untouched.

### 2.2 The invariant

> **Within a band, load order must not matter.**

If two files in the same band depend on each other's source-time effects, one of them is
in the wrong band. This is what converts "sorted by luck" into "sorted by contract," and
unlike the current arrangement it is mechanically checkable (§2.5).

`80-user` and `90-local` are explicitly exempt. Running last *is* their purpose, and that
is stated rather than inferred.

### 2.3 Tier interaction stays tier-major

The rc keeps sourcing the whole `sh/` tier, then the whole shell-specific tier:

```zsh
for file in $SH_CONFIG/*/*.sh(N) $ZSH_CONFIG/*/*.zsh(N); do
```

Not band-major (`00-env/*.sh`, `00-env/*.zsh`, `10-lib/*.sh`, …). Tier-major preserves the
existing documented rule — *a `sh/` file must not rely on a `<shell>/` helper at source
time* — unchanged. Band-major would make that rule conditional on the band and buy
nothing: a portable snippet that needs a zsh-only helper is already a design error.

Two consequences fall out:

- **Every file is exactly one level deep**, so `*/*.zsh` is sufficient and zsh's `**/` can
  go. This satisfies the two-level-glob constraint `CLAUDE.md` documents for bash 3.2
  (no `globstar`) without a special case.
- **§1.2 disappears.** With no files at the tier root, `*/*.sh` and `**/*.sh` produce
  identical order, so zsh and bash agree by construction.

The loop exists in three places and all three change together:

- `pde/zsh` — `home/.zshrc:181`
- `pde/zsh` — `home/.config/zsh/aliases.zsh:96` (inside `zsrc`, the reload helper)
- `pde/bash` — `home/.bashrc:71-72`

### 2.4 `ppm shell` — provenance as a query

A new lib extension at `packages/system/home/.local/lib/ppm/shell.sh`. A function named
`shell` there becomes `ppm shell`, the same mechanism as `ppm hooks` and `ppm move`
(`CLAUDE.md`, Lib Structure).

```
ppm shell order [zsh|bash]     # resolved load order, annotated with repo/package
ppm shell doctor               # lint the live tree
```

`order` resolves each link with `readlink` and attributes it via the install trackers at
`~/.local/share/ppm/.installed/<repo>/<pkg>.yml`, which already record stowed files:

```
$ ppm shell order zsh
  1  sh/10-lib/ppm.sh          ppm/system
  2  sh/20-tools/mise.sh       ppm/system
  3  zsh/00-env/…
  …
```

This is the actual answer to "I want to see what's from where" — better than a directory
name, because it shows the *resolved* order including which layer won, and it costs
nothing at shell startup.

`doctor` reports:

- a file at a tier root, or in an unknown band
- a source-time call to a function defined in a later band (the §1.1 class of bug)
- a `.zsh`/`.sh` file in the tier that is not a symlink and not in `protected.yml`
- a band-order disagreement between the zsh and bash rc loops

### 2.5 Enforce at commit

`ppm/dev` already ships a `pre-commit` hook
(`packages/dev/home/.config/git/ppm-hooks/`) wired into every source repo by `ppm hooks`.
Extend it: **reject a file under `home/.config/{sh,zsh,bash}/` that is not inside a known
band.** That is what keeps the protocol honest across seven independently-edited repos,
and it is the cheapest possible enforcement point.

---

## 3. The add-vs-replace protocol

The question this protocol exists to answer: `pde/git` ships `20-tools/git.zsh`, and
`user/git` wants to contribute git shell code too. What is the filename?

**Stow has exactly one semantic: replace.** Same path → higher layer wins, lower layer's
file is never linked. There is no append. So the answer is not a naming trick — it is
recognising that "add to" and "replace" are different intents, and refusing to overload
the filename to mean both.

### 3.1 Add new things → new filename, same band

New aliases, new functions, new exports; nothing `pde/git` already defines.

```
pde/git   ->  home/.config/zsh/20-tools/git.zsh
user/git  ->  home/.config/zsh/20-tools/git-worktree.zsh
```

Both stow, both load, neither hides the other.

Name the file for **what it adds**, never for where it came from. Not `git.user.zsh`,
not `git.local.zsh`. A `user` infix bakes a repo alias into a path (§1.4 reasons 2 and 3)
and duplicates what `ppm shell order` already reports. `git-worktree.zsh` is
self-documenting and survives being promoted into `pde/git` later — which is exactly what
happens when a personal helper turns out to be general.

This case satisfies §2.2 for free: code that only defines new names is order-independent
by construction.

### 3.2 Replace the whole file → `ppm file claim`

```
ppm file claim ~/.config/zsh/20-tools/git.zsh
```

Copies it into `user/git`, stows from there, records it in `claims.yml`, drops it from
`pde/git`'s tracker. `ppm file reset` is the undo.

Do **not** hand-create the overriding file in the user repo. `claim` is the supported
path and is the only one that leaves the trackers consistent.

### 3.3 Redefine one thing, keep the rest → `80-user`

`pde/git` sets `alias gs='git status'`; you want `gs` to mean something else but want the
other forty aliases intact. This is the only case where load order genuinely matters, and
it is not additive.

```
user/git  ->  home/.config/zsh/80-user/git.zsh
```

`80-user` runs after every phase band, so a redefinition there wins. This is the one
place a personal file is placed by *whose* it is rather than by *when* it runs.

### 3.4 The trap

**Do not reach for `80-user` just because a file came from the user repo.** A user-repo
contribution belongs in the band matching **its phase**. A personal `ensure_path` call
placed in `80-user/` runs after every `20-tools` file has already guarded on
`command -v` and silently no-opped.

The band means *when*, never *whose*. That distinction is the whole reason bands work
where repo-namespacing does not.

Rule of thumb: reach for `80-user` only to undo or shadow something a lower band did.
Defining new names is §3.1, and belongs next to the package being extended.

### 3.5 Summary

| Intent | Mechanism | Path |
| --- | --- | --- |
| Add new names | new filename, same band | `20-tools/git-worktree.zsh` |
| Replace whole file | `ppm file claim` | `20-tools/git.zsh` (same path, higher layer) |
| Redefine one name | override tail band | `80-user/git.zsh` |
| Machine-specific | uncommitted tail band | `90-local/…` |

---

## 4. Non-goals and rejected alternatives

**Per-file numeric prefixes** (`20-op.zsh` at the tier root). Finer-grained, but every
layer of a package must agree on the number or the override silently breaks, and it
invites specifying a total order when only a partial order is needed. Bands give the same
guarantee with a bounded vocabulary.

**Declarative `shell_after:` in `package.yml` plus a ppm-generated manifest.** The most
expressive option, and it fits ppm's existing topological sort of `depends:`. Rejected for
now because it puts a generated artifact on the critical path of every shell startup — a
staleness failure mode an rc should not have. Bands are forward-compatible with it: a
manifest could order bands first and files within a band by declared edges. Revisit only
if band granularity proves too coarse in practice.

**ppm rewriting stow destinations into `<repo>/`.** Delivers literal repo namespacing, but
gives up stow's conflict detection, clean `stow -D`, and `ppm file protect`. Not worth it.

**Changing the rc to band-major tier interleaving.** See §2.3.

---

## 5. Migration

Mechanical and incremental. Each step is a `git mv` in a package repo followed by
`ppm install -f <pkg>`.

1. **Land the rc change first**, accepting both shapes during the transition:
   `$ZSH_CONFIG/*.zsh(N) $ZSH_CONFIG/*/*.zsh(N)` — top-level files keep working while
   packages migrate. All three loops in §2.3 together.
2. **`10-lib` first.** Move `pde/zsh`'s `aliases.zsh`. This is the file the §1.1 bug hangs
   on; once it is in a band that provably precedes `20-tools`, the eight unguarded
   `zcomp` callers are correct by structure rather than by luck.
3. **`00-env`, then `20-tools`, then `30-ui`**, one package at a time.
4. **Ship `ppm shell`** (§2.4) and use `ppm shell doctor` to find stragglers.
5. **Tighten the rc** to `*/*.zsh` only, and **enable the pre-commit check** (§2.5).
   Order matters: the lint must not land before the last package has moved.
6. **Drop the `(( $+functions[zcomp] ))` guards** in `mise.zsh` and `ppm.zsh` — or keep
   them, since `ppm/system` must not depend on `pde/zsh` (`CLAUDE.md`, Shell Integration).
   The guard is about a *missing package*, not a bad order, so it should stay. Update the
   comments, which currently justify it by ordering.

Nothing in steps 1–4 is breaking; a half-migrated tree loads correctly.

---

## 6. Verification

No automated suite; verify manually, per `CLAUDE.md`.

- `ppm shell order zsh` matches `ppm shell order bash` for the shared `sh/` tier
- `zsh -ic 'echo $functions[zcomp]'` is non-empty; `ls $PPM_FPATH` shows the completions
  the eight §1.1 callers generate
- `zsrc` reload produces the same order as a fresh login shell
- `ppm install -f pde/zsh` then a fresh shell: no unbound-function errors
- A throwaway `ppm container` run installs cleanly from scratch
- `ppm file claim` on a banded path still stows and still reverses with `ppm file reset`

---

## 7. Open questions

- **Should `sh/` need all six bands?** The portable tier is small. `10-lib` / `20-tools`
  may cover it, with the rc creating only what exists.
- **`ssh/` and `ruby/` subdirectories.** `pde/op` ships `zsh/ssh/op.zsh`, `pde/ghostty`
  ships `zsh/ssh/ghostty.zsh`, `pde/ruby-tools` ships `zsh/ruby/tools.zsh`. Flattening to
  `20-tools/ssh-op.zsh` keeps the one-level rule and the two-level glob. Confirm nothing
  sources those directories as a group.
- **Does `80-user` need a band number gap?** `40`–`70` are unallocated on purpose; leaving
  them empty is the current bet.
- **`ppm shell doctor`'s later-band call detection** is a static grep against the set of
  function names defined in each band. Good enough to catch the §1.1 class; decide whether
  false positives on same-named local functions are tolerable.
