# anfsd

anfsd, the anfs daemon (anfs-io/runtime, Go), as a service of yours, and `anfs bus`. In 02a anfsd
only ships: every line of the event log (`~/.local/state/anfs/events/`) to the NATS stream `ANFS`,
exactly once per event id. AGENTS.md, "The bus"; the code and its own docs are in anfs-io/runtime.

```bash
ppm install core/nats core/anfsd
anfs bus status                     # nats, jetstream, anfsd, the shipper's lag
anfs bus logs anfsd -f
anfs bus restart anfsd
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
  `anfsd.log` (macOS). Kept by `ppm remove core/anfsd`.
- Settings: `~/.config/anfsd/anfsd.env` (linked; `anfsd.local.env` for this machine):
  `ANFSD_BIN`, the stream's `ANFSD_STREAM_MAX_AGE` (90d) and `ANFSD_STREAM_MAX_BYTES` (1GiB), the
  duplicate window `ANFSD_DUP_WINDOW` (24h), the shipper's `ANFSD_SHIP_RATE` (100/s per space)
  and `ANFSD_SHIP_BURST` (1000).

## Pins after a release

`tests/pins --print` fetches the release's four assets and prints their sums: paste them under
`sha256:` in `pins.yml`; `tests/pins` checks them.
