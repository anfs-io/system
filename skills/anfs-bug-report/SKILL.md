---
name: anfs-bug-report
description: Report a bug in an anfs tool (anfs, ppm, pcm, pmm, psm, wsm, or a stack tool such as ovm or tsm) with `anfs report`, then follow it until the fix is on this machine. Use when one of those tools does something wrong — a wrong result, a crash, a misleading message — not for a bug in the code you are writing with them. Invoked with no bug in hand (`/anfs-bug-report check`, or just to try it), it runs `anfs report check`.
---

# Reporting a bug in an anfs tool

Triggers when an anfs tool (core or stack) misbehaves; not for bugs in your own project.

`anfs report` builds the issue (your fields plus the diagnostics it gathers: versions, each
source's commit and state, installed packages, the log's recent failures) and files it where this
machine's `ANFS_REPORT_TO` says: GitHub or a file. **You never choose the destination, never call
`gh`, and never write the issue anywhere yourself.**

## Check mode

Invoked with no bug in hand (`/anfs-bug-report check`, or to test the skill): run
`anfs report check` and relay its rows as printed (`CHECK STATUS DETAIL`, `ok` or `fail` each:
where reports go and from which settings file, gh and its login or the file, the core and stack
origins, this skill's install). Exit 1 means a row failed; its DETAIL says what to do.

## Reporting

1. **Reproduce it minimally.** The smallest command line that shows it; in a temp `HOME` when it
   can be (never against real state you are not sure of). Note the exact output and exit code.
2. **Run `anfs report`** with the fields:

   ```bash
   anfs report --package core/pcm --title "pcm up hangs when the network is missing" \
     --expected "an error naming the network" \
     --actual "hangs; ^C after 60 s; exit 130" \
     --steps "pcm up x  (x's compose.yml names network y, which does not exist)"
   ```

   `--package` is the package (`source/name`, or an installed name); its source owns the report
   (none: core). Long text: `--body-file F`, or `--body-file -` with it on stdin. `-n` shows the
   report and where it would go without filing.
3. **Exit 77** (GitHub asks before filing, and you have no terminal): show the person what it
   printed (the repo, any possible duplicates) and rerun with `-y` only when they say so. If a
   duplicate is the same bug, say so and do not file.
4. **Keep the id it prints** (`r-20261022-1`, or `owner/repo#42`) and name it in later messages,
   plans and commits about this bug.

## Waiting for the fix

Run `anfs report wait <id> [--timeout SECS]` as a **background command**, so your harness tells
you when it exits: 0 means the fix is in this host's checkout of the source (`anfs report status
<id>` says `available`), 1 a timeout. It waits on events, not on a timer: it looks again when the
report is closed (`report.closed`) and when a source is updated (`source.updated`, from `anfs src
update`), so it costs nothing while it waits. Meanwhile carry on with other work, or
hand the blocked part to someone else; when it exits 0, resume what the bug blocked.

The event way, for the closing itself rather than its arrival here: `wsm events ls -f --once
--type report.closed --subject <id>` (in the space the report is filed in; `anfs events ls` for a
GitHub report, which goes to the host scope), also as a background command: it prints the
`report.closed` event and exits 0 when whoever merges the fix runs `close`, at once if that
already happened.

`anfs report status <id>`: `open`, `fixed` (closed, not yet in this checkout: `anfs src update`
brings it), or `available`; exit 0 only for `available`, 2 for an unknown id.

## Closing

Whoever merges the fix runs `anfs report close <id> --commit <sha> [--source core|stack]`. It
records the commit on the report (a file's `Status:` line; a GitHub comment, then the issue
closed), which is what `status` and `wait` read.
