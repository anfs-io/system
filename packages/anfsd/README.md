# anfsd

anfsd, the anfs daemon (anfs-io/runtime, Go), as a service of yours, and `anfs bus` and `anfs
agents`. anfsd ships every line of the event log (`~/.local/state/anfs/events/`) to the NATS stream
`ANFS`, exactly once per event id; runs the dispatch rules of the installed spaces (`dispatch:` in
`space.yml`), each run an agent CLI in its own job, supervised; and renders the report records into
the report file (BACKLOG.md as a view); and follows `podman events`, writing what containers and
pods do as `container.*` and `pod.*` events in the host scope. AGENTS.md, "The bus" and "Dispatch"; the code and its own
docs are in anfs-io/runtime.

```bash
ppm install core/nats core/anfsd
anfs bus status                     # nats, jetstream, anfsd, the shipper's lag, dispatch, podman
anfs bus logs anfsd -f
anfs bus restart anfsd
anfs bus reload                     # the dispatch rules again (SIGHUP)
anfs agents rules                   # RULE STATUS SPACE ON AS HARNESS
anfs agents match --type report.filed --space anfs-dev --subject r-1 --data to=file \
  --data package=core/pcm          # what the rules would do with that event; starts nothing
anfs agents ls                      # the runs: RUN STATUS RULE ROLE SPACE HARNESS JOB AGE
anfs agents show <run>; anfs agents logs <run> -f; anfs agents stop <run>
anfs events ls --type 'container.*' -f   # containers as podman reports them
```

## The binary: a release, or built from source

`pins.yml` pins anfs-io/runtime's release (`anfsd-<tag>-<os>-<arch>.tar.gz`, from its `v*` tags):
fetched into `~/.local/share/anfsd/<version>/`, checked, linked from `~/.local/bin/anfsd`.

From source (this Mac before the first release, or to try a branch):

```bash
cd <a runtime checkout>/go && go build -o ~/.local/share/anfsd/dev/anfsd ./cmd/anfsd
echo 'ANFSD_BIN=~/.local/share/anfsd/dev/anfsd' >> ~/.config/anfsd/anfsd.local.env
anfs bus restart anfsd              # the unit now runs it; anfs bus status says "from source"
```

Unset `ANFSD_BIN` (and `anfs bus restart anfsd`) to go back to the release. While no release is
pinned (`sha256: {}`), `ppm install core/anfsd` needs `ANFSD_BIN`.

## What it puts where

- The service: `io.anfs.anfsd` (launchd) or `anfsd.service` (systemd user: after
  `anfs-nats.service`, `KillMode=process`), running `<anfsd> run`.
- `~/.local/state/anfsd/`: `cursors.json` (how far each month file is shipped), `anfsd.pid`,
  `anfsd.log` (macOS), `runs/<run id>/` (`run.json`, `event.json`, `prompt.md`, the harness's
  settings file, `out.log`, `exit`, a `cancel` marker), `podman.json` (podman's state for `anfs
  bus status`: connected, away with the error and the next try, or off). Kept by `ppm remove core/anfsd`.
- Settings: `~/.config/anfsd/anfsd.env` (linked; `anfsd.local.env` for this machine):
  `ANFSD_BIN`, the stream's `ANFSD_STREAM_MAX_AGE` (90d) and `ANFSD_STREAM_MAX_BYTES` (1GiB), the
  duplicate window `ANFSD_DUP_WINDOW` (24h), the shipper's `ANFSD_SHIP_RATE` (100/s per space)
  and `ANFSD_SHIP_BURST` (1000), `ANFSD_MAX_RUNS` (2: runs at once on this host), and
  `ANFSD_PODMAN` (on; `off` never runs podman).

## Podman

anfsd runs `podman events --format json --filter type=container --filter type=pod` (from now, no
history) and keeps a container's create, start, stop, died, remove, pause, unpause and a change of
health, and a pod's create, start, stop, remove: `container.started` and so on, subject the
container's name, data `id` (12), `image`, `pod` (the pod's id, 12), `exit` (died), `health`,
`pcm` (the `io.pcm.name` label), actor `podman`. The same container, status and second is one
event; at most 20 a second, the rest counted in the log once a minute. When podman is away (not
installed; on macOS the podman machine stopped) the child ends and is started again after 5, 10,
30, then every 60 s, one log line per change; `podman.connected` when it is back (list once to
reconcile), `podman.disconnected` when it goes. `anfs bus status` shows it `away` without failing
the exit: on macOS a stopped machine is normal. podman is found on the service's PATH (the one
the install had).

## Pins after a release

`tests/pins --print` fetches the release's four assets and prints their sums: paste them under
`sha256:` in `pins.yml`; `tests/pins` checks them.
