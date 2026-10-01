# dev — working on ppm

Install this package when you are changing ppm itself rather than using it. It adds commands for
testing installs on machines you can throw away, and wires up the git hooks that version packages.

```bash
ppm install ppm/dev
```

Run `ppm container`, `ppm user` or `ppm hooks` for their usage. What follows is what each one is
for and when to reach for it.

## Three Ways to Test an Install

ppm's riskiest code is the part that runs once, on a machine that has nothing: prerequisites,
Homebrew, the first stow. That is exactly the code you cannot test on your own workstation, because
your workstation is already set up. So this package offers three kinds of throwaway machine, and
the differences between them are the whole point:

| | Isolation | Cost | Reaches |
| --- | --- | --- | --- |
| `ppm user` | a second user on **your** machine | seconds | user-level install, a second user against your Homebrew |
| `ppm container` | a Debian or Fedora container | seconds | everything except the kernel and the session |
| `ppm vm` | a full macOS guest | ~11s from a snapshot | everything, including login shells |

**`ppm user`** creates a throwaway user, runs the installer as them and logs you in. It is the
cheapest way to see what a *second* user experiences — the non-owner Homebrew path in particular —
but it shares your machine, so it proves nothing about a bare one.

**`ppm container`** is the workhorse. It builds a Debian or Fedora image with two test users
(`owner`, who has sudo with a password, and `other`, who has none) and mounts your source repos
read-only at `/src`, so the container tests your **working tree** — edits show up without
committing. Snapshots make the expensive part reusable: install Homebrew once, snapshot, and every
later run starts from there in seconds. It needs podman (`ppm install podman`).

What containers cannot reach is the reason the third row exists: no systemd services, no login
sessions (so nothing that `chsh` touches, and no rc files being sourced for real), no kernel
features like NFS or KVM. And nothing on that list covers macOS at all, which is where ppm's most
fragile paths live — Xcode Command Line Tools, the Homebrew prefix, `sysadminctl`, `/etc/shells`.

**`ppm vm`** is the macOS answer, and deliberately the same motion: the same subcommands, the same
two users, the same read-only `/src` mounts, so a change is tested on macOS the way it is tested on
Debian. It needs Apple silicon, because that is where macOS guests can run at all, and `tart`:

```bash
brew trust --formula openai/tools/softnet && brew install openai/tools/tart
```

Building the base box downloads a stock macOS image (~25GB, once) and provisions it. The image is
deliberately a *vanilla* one with no Homebrew and no Xcode Command Line Tools, so a run against it
exercises the whole of `install.sh` — the part that only ever executes on a machine that has
nothing, and the part most likely to break.

Snapshots are what make that affordable. They are APFS copy-on-write clones, so a cold install
(~3 min, most of it Homebrew and the CLT) is paid once and every later run starts from the snapshot
in about ten seconds.

## Why a VM and Not Another Container

Containers share the host kernel and never start a session, so three things ppm does are invisible
to them: a login shell actually sourcing the rc files and mise activation, `chsh` and `/etc/shells`,
and anything a service manager runs. On top of that, none of ppm's macOS-specific code exists on
Linux at all — the Xcode CLT, the Homebrew prefix and its ownership, `sysadminctl`. Those paths had
no test before `ppm vm`, and they are the ones that run exactly once on a new machine, where a
failure is most expensive.

The design findings behind the implementation — why `/src` has to come from `synthetic.conf`, why a
snapshot recreates the box instead of restarting it, why sudo needs a longer timestamp on a
headless box — are recorded in `chorus/units/testing/01-macos-vm/`.

## Git Hooks

`ppm hooks` points a repo's `core.hooksPath` at the hooks this package stows, which bump a
package's patch version whenever a commit touches it.

This is an install step rather than repo content because **git does not carry hooks through a
clone** — a hook committed to a repository does nothing for whoever clones it. So the hook files
ship in a package, get stowed once, and each repo is pointed at the stowed copy. Editing a hook
then takes effect everywhere at once, and a higher-priority repo can override a single hook file
through the same stow layering as any other file.

The setting is always written per repo, never globally. A global `core.hooksPath` applies to every
repository on the machine *and* suppresses each one's own `.git/hooks`, which would silently
disable husky, lefthook or overcommit in unrelated projects.

The version bump happens **once per unpushed series**: the hook compares the working version
against the version at the push base, and only bumps when they match. A run of commits before one
push bumps once, `--amend` does not bump again, and a version you set by hand is left alone. A repo
with nothing pushed yet gets no bumps at all, so a new package sits at `0.1.0` until its first
push.

Because hooks are wired per repo, `ppm hooks install` has to be re-run after `ppm src add` — this
package's install hook cannot know about a repo you add later.
