# Package development and debug mode — ideas

A scratchpad for ppm's developer experience: what goes wrong while writing a package, and what ppm
could say or do about it. Nothing here is decided. Each entry states the problem, why it is worth
solving, and a rough shape, so a later session can pick one up without rediscovering the context.

---

## Surface a registered callback that cannot run

**Status:** proposed, deliberately not implemented yet.

`_run_callbacks` (`installer.sh`) skips a registration whose package has no install tracker or no
`install.sh`, with a `debug` line:

```bash
if [[ ! -f "$(_tracker_path ...)" || ! -f "$dir/install.sh" ]]; then
  debug "Skipping $qualified's callback $fn: not installed, or no install.sh"
  continue
fi
```

**The problem.** That state should not arise. `remover()` calls `_callback_unregister` when a
package goes, so a registration that survives with no tracker behind it means something got out of
step — a tracker deleted by hand, a package directory moved, an interrupted remove. The effect is
silent: `ai/psm` is the only registrant today, so the symptom would be skills quietly ceasing to
sync on install, with nothing in the output and no obvious place to look. It is the same class of
failure as a declared resource key with no handler, which is now reported rather than whispered.

**Why it is not just `user_message`.** The two arms of that condition are not equally suspicious:

- *No tracker* is the anomalous one. The registration and the tracker are written and removed
  together, so their disagreeing is a real inconsistency.
- *No `install.sh`* is plausible during ordinary development — you are editing a package, the file
  is briefly absent or renamed, and a warning on every unrelated `ppm install` would be noise you
  learn to scroll past. That is how a warning stops being read.

So the shape probably is: report the missing tracker, keep the missing `install.sh` at `debug`, and
in the missing-tracker case prune the stale registration rather than only complaining about it —
`_callback_unregister` is already there and idempotent. A self-healing check beats a message the
user has to act on.

**Open question.** A registration for a package that is merely *not installed right now* is not an
error at all in a multi-machine setup, where `callbacks.yml` could plausibly be shared. Today it is
machine-local state under `.installed/` and is not shared, so this does not arise — but if that
ever changes, pruning becomes the wrong reflex and this should be revisited.

---

## Related: ppm's silent-by-default seams

Worth tracking together, because they are one theme — ppm doing nothing and not saying so. Each
was a deliberate choice to keep normal output quiet, and each has cost someone an afternoon:

| Seam | Was | Now |
| --- | --- | --- |
| Resource key with no handler | `debug` | reported in the end-of-run messages |
| Registered callback that cannot run | `debug` | still `debug` — the entry above |
| Hook function absent from `install.sh` | silent by design | correct: hooks are all optional |

The rule that seems to be emerging: **silence is right when the absent thing is optional, and
wrong when the user wrote something down and it had no effect.** A missing `post_install` is the
first; a declared `wsm:` key with no handler is the second. When adding a new seam, ask which one
it is.

---

## Debugging notes worth keeping

Small things that have bitten during package development, recorded so they do not have to be
rediscovered.

**`--debug` goes after the command.** `main()` parses flags only after shifting the command, so
`ppm install --debug foo` works and `ppm --debug install foo` is an unknown-command error. Easy to
lose a few minutes to.

**Tab-separated output and `read` do not mix cleanly.** Tab is IFS whitespace, so
`IFS=$'\t' read -r a b` collapses adjacent tabs and strips leading ones — an empty first field
silently shifts every value along by one. `yq`'s `@tsv` therefore cannot be read back safely when
any field may be empty. Emitting one field per line instead (`yq -r '... | [a, b] | .[]'`) and
reading with chained `read`s preserves empties exactly; `pde/wsm` does this in both
`ppm_resource_wsm` and `wsm prepare`. `_run_callbacks` still uses the `@tsv` form, which is safe
only because both of its fields are non-empty by construction and it guards on that.

**zsh reserves names that bash does not.** A `~/.config/sh/*.sh` snippet is sourced by both rc
files, so `local status=...` and `read -r path` are landmines there: `status` is read-only in zsh
and `path` is tied to `$PATH`. Both were hit while writing `wsm`'s shell wrapper.

**Test a shell snippet interactively.** The rc files only load for interactive shells, so
`bash -lic '...'` exercises them and `bash -lc '...'` does not.
