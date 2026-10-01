# psm — Personal Skills Manager

Syncs agent skills to every AI agent ppm has installed, through the `skills`
CLI (`npx skills`). `psm help` documents the commands; this file covers what
the code and the usage text can't.

## Shipping a skill from a source

Put it at `skills/<name>/SKILL.md` at the top of any anfs source repo, next to its
`packages/`, `containers/` and `spaces/`. psm syncs every source holding `skills/`
as a repo named by the source's alias — no config file, no entry anywhere. The anfs
repo ships the tools' own skills that way (`skills/pcm-containers`), and so can an
org's repo (`anfs install lgat` syncs `lgat/skills/*`). `~/.config/psm/*.yml` stays
for third-party skill repos that are not anfs sources.

The skills dir is handed to the CLI resolved through links (`cd -P`): a local-path
source is a symlink under `~/.local/share/anfs/sources`, and the CLI does not follow
symlinked directories (below).

## What the skills CLI actually does

Found by experiment against `skills@latest` on 2026-09-15, none of it
documented upstream. Re-check it if the CLI changes.

- **Symlinked skill directories are invisible to it.** A hub of
  `hello -> …/pkg/hello` links yields `No skills found`; it filters directory
  entries without following links.
- **Symlinked *files* are followed.** A real `<name>/` holding a symlinked
  `SKILL.md` is found, and supporting files (`references/`, …) are copied
  through dereferenced. This is why the old stowed hub worked: ppm stows with
  `--no-folding`, so skill directories are real and only their files are links.
- **It copies, it does not link back to the source.** Editing a skill in its
  package changes nothing until `psm update` re-copies it.
- **`skills list --json` reports `source: none` for anything installed from a
  local path** (remote skills carry `owner/repo`). Hence `builtin` enumerates
  its skills by name instead of passing `-s '*'`: prune protects declared
  names, and a local `*` source would leave nothing to match against.
- **Agents are named two ways**: display name in `list --json` ("Claude Code"),
  id on the command line (`claude-code`). `_agent_display` maps between them and
  returns 1 for ids it doesn't know, so an unmapped agent gets re-added rather
  than wrongly skipped.
- **`remove -a <id>` unlinks from that agent only** and leaves the skill for the
  others (checked 2026-09-25). `-a` is variadic: it takes every argument after
  it as an agent, so skill names go first — `remove hello -g -y -a claude-code`,
  never `remove -g -y -a claude-code hello` ("Invalid agents: hello").
- **Universal agents (OpenCode, and whatever else `add` reports as
  `universal:`) have nothing to unlink.** They read `~/.agents/skills`, the
  canonical copy, directly. `remove -a opencode` reports success and keeps the
  copy, so they go on listing every skill. `psm agents rm` notes it rather
  than treating it as a failure.

## Reacting to agent packages

`post_install` registers `psm_ppm_changed` with ppm (`ppm_register_callback`),
which ppm calls after every install/remove run with the packages involved:

- install: `psm sync` when psm itself or any `meta.agent` package is in the run.
- remove: `psm agents rm <id>` for each removed package's `meta.agent` ids,
  unless another installed package still declares the id.

## Command surface

- Nouns take verbs: `repo`, `skills`, `agents`. A bare noun prints that group's
  usage; an unknown verb prints it to stderr and exits 1.
- `sync` and `update` stay top-level. Their argument is a *config* name, and
  they span all three nouns — read repos, install skills, target agents.
- `path` is plumbing for the `psm cd` function in `psm.zsh`, deliberately kept
  out of the usage and the completion.
- Commands name other commands in their output ("Run: psm skills prune"), so
  renaming one means grepping the strings, not just the dispatch.

## Two traps in the source

- `_config_sources` checks `yq` on its own rather than through the pipeline.
  Under `pipefail` a consumer that stops reading (`psm skills | head`) would
  otherwise surface as an unparseable config.
- For the same reason, never `return` early from a loop reading
  `< <(_config_sources)`: it closes the pipe under the writer, whose `yq` then
  fails and gets reported as a bad config. `_repo_config` drains, then returns.

## Deliberately not built

- Local `*` sources re-add on every sync, because psm can't enumerate them
  ahead of time. It could do what `_anfs_skill_sources` does and give them real
  `ok`/`missing` status — worth it if the re-adding becomes annoying.
- No way to scope a source's skill to one agent; it goes to every detected
  agent. The escape hatch is an ordinary config entry pointing at the skills dir with
  an `agents:` key.
