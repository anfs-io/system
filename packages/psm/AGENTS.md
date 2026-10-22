# psm — Personal Skills Manager

Syncs agent skills to every AI agent ppm has installed, through the `skills`
CLI (`npx skills`). `psm help` documents the commands; this file covers what
the code and the usage text can't.

The engine is `lib/anfs/skill.sh` (core/anfs): agent detection, the CLI with a
scope, rows, what is installed. psm runs it with the global scope (`-g`); wsm
runs it with a space's directory (`wsm skill`, core AGENTS.md "wsm: spaces").
The CLI's version is `ANFS_SKILLS_CLI_VERSION` in `anfs.conf` (default
`latest`), for both; `PSM_CLI_VERSION` is gone.

## Shipping a skill from a source

Put it at `skills/<name>/SKILL.md` at the top of any anfs source repo, next to its
`packages/`, `containers/` and `spaces/`. psm syncs every source holding `skills/`
as a repo named by the source's alias — no config file, no entry anywhere. The anfs
repo ships the tools' own skills that way (`skills/pcm-containers`), and so can an
org's repo (`anfs src install lgat` syncs `lgat/skills/*`). `~/.config/psm/*.yml` stays
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

### With a project scope (no `-g`)

Checked 2026-10-21 against `skills@1.7.4` in a scratch directory with no git
and no `package.json`, a temp `HOME` (what wsm does in a space's directory):

- **The scope is the current directory**, no project marker needed.
  `add <path> -y -a claude-code opencode` writes `./.agents/skills/<name>/`
  (the copy), `./.claude/skills/<name> -> ../../.agents/skills/<name>` for the
  non-universal agent, and `./skills-lock.json` (`version`,
  `skills.<name>.{source, sourceType, computedHash}`; the source relative to the
  canonical cwd even when given absolute). **With only non-universal agents**
  (`-a claude-code`) there is no `.agents`: the copy is `./.claude/skills/<name>/`.
- `list --json` answers for the cwd only (`[]` from a subdirectory). Rows carry
  `name`, `path`, `scope: project`, `agents` and, for a local source, its
  absolute path (the global scope says `source: none`). **Pi is not listed**
  for a skill installed for it (OpenCode, the other universal agent, is), so
  `anfs_skill_has` counts a universal agent (`pi`, `opencode`) as installed when
  the copy is in `.agents/skills/`.
- **`remove <name> -y` without `-a` sweeps every agent's project directory**,
  and three of them are not hidden: `skills/<name>`, `data/skills/<name>`,
  `agent/skills/<name>` (the CLI's agent table). In a space, `skills/<name>` is
  as likely as not the space's own files or the user's: a test removed a user's
  `skills/hello/SKILL.md`. So wsm never removes without `-a` (the agents the skill
  is on), and deletes itself what that leaves for universal agents: the
  `.agents/skills/<name>` copy and its `skills-lock.json` entry. The CLI also
  lists a skill as installed for AstrBot when a `data/skills/<name>` of the
  user's exists.
- **The global scope sweeps too** (checked by the orchestrator and again here, 1.7.4, temp
  `HOME`): `remove -g -y foo` deleted a user's own `~/agent/skills/foo/` (it left `~/skills` and
  `~/data/skills`). So every remove psm makes (`remove`, `prune`, `implode`; `agents rm` already
  did) goes through `anfs_skill_remove -g`: `-a` for the agents `list` puts the skill on, then the
  `~/.agents/skills/<name>` copy and the `~/.agents/.skill-lock.json` entry go if the CLI kept
  them. A skill not installed is skipped; one only on agents with no known id stays, with a
  warning. **Never call `skills remove` without `-a`, in any scope.**
- `remove -a <agent>` removes that agent's link or copy only; a full remove
  leaves empty `.agents/skills`, `.claude/skills` and a `skills-lock.json` with
  `"skills": {}`, which wsm tidies (`rmdir`, and the lock deleted when empty).
- Inside an agent session it prints `Agent detected — installing
  non-interactively`.

### Claude Code and project skills in parent directories

From Claude Code's documentation (code.claude.com/docs/en/skills, read
2026-10-21): "Claude Code loads project skills from `.claude/skills/` in the
directory where you start it and in every parent directory up to the
repository root, so starting in `packages/frontend/` still picks up skills
defined at the root." Skills in a `.claude/skills/` below the start directory
load lazily, the first time Claude reads or edits a file there. In a linked git
worktree the walk stops at the worktree root. The page does not say what the
walk does outside any git repository (where a space's directory under
`~/spaces` usually is), and does not mention `.agents/skills`.

So: started in a child space that is not in a repository, whether a parent
space's `.claude/skills` loads is undocumented; started inside a clone in a
space (a repository), the walk stops at the clone's root and the space's own
skills above it are not loaded from there. Nothing is built for either (unit
decision 16): a space's skills are its own.

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
- `path` is plumbing for the `psm cd` function in `sh/psm.sh`, deliberately kept
  out of the usage and the completion.
- Commands name other commands in their output ("Run: psm prune"), so
  renaming one means grepping the strings, not just the dispatch.

## Two traps in the source

- `_config_sources` checks `yq` on its own rather than through the pipeline.
  Under `pipefail` a consumer that stops reading (`psm list | head`) would
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
