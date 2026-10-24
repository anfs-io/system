# nats

NATS with JetStream, the anfs bus: `nats-server` and the `nats` CLI at pinned versions
(`pins.yml`: nats-server v2.15.1, natscli v0.5.0, the releases' own sha256s), run as a service of
yours. anfsd (core/anfsd) publishes the event log to it; programs subscribe. AGENTS.md, "The bus".

```bash
ppm install core/nats        # usually with core/anfsd: ppm install core/nats core/anfsd
anfs bus status
anfs bus nats -- stream info ANFS
```

## What it puts where

- `~/.local/share/nats/<version>/{nats-server,nats}`, linked from `~/.local/bin`; the downloads
  in `~/.cache/nats/<version>/` (checked against the pins; a mismatch installs nothing).
- `~/.local/state/nats/` (0700): `server.conf` (0600, rendered from the settings: never edit it),
  `users/{anfsd,admin,reader,<layer>...}` (a password each, made once, kept by a reinstall), `port`,
  `jetstream/` (the store), `nats-server.log` (macOS).
- The service: `~/Library/LaunchAgents/io.anfs.nats.plist` (macOS), or
  `~/.config/systemd/user/anfs-nats.service` (Linux), written by the install, removed by `ppm
  remove core/nats` (which keeps STATE and DATA).

NATS listens on `127.0.0.1:47222` (not 4222, which apps in containers publish), its monitoring on
`127.0.0.1:47223`. The users: `anfsd` publishes, `admin` is yours (`anfs bus nats`), `reader`
subscribes to `anfs.>` and keeps its own consumers on `ANFS` (the ui's: `ui`, with the password file mounted read-only into its container), and one publisher per layer in `ANFS_BUS_LAYERS` (`cnfs`, `lgat`), named after its namespace: it publishes only its layer's subjects, `anfs.*.<layer>.>` (never anfs's `anfs.*.anfs.>` or another layer's), and reads and keeps its own consumers as `reader` does, never managing a stream. The subjects are `anfs.<scope>.<type without io.>` for every layer (`anfs.<space id>.anfs.report.filed`, `anfs.host.anfs.container.started`, `anfs.<space id>.cnfs.partitia.report.filed`): the event spec, https://github.com/anfs-io/events (SPEC.md, "Subjects on NATS", "The publisher user per layer").

## Settings

`~/.config/nats/nats.env` (linked) documents them; this machine's values go in
`nats.local.env`, then `anfs bus restart nats`: `ANFS_NATS_PORT`, `ANFS_NATS_HTTP_PORT`,
`ANFS_NATS_MAX_FILE` (JetStream's disk cap), `ANFS_NATS_MAX_MEM`, `ANFS_BUS_LAYERS` (the layers
that publish directly: a user each; none by default).

On Debian, a user service runs only while you are logged in unless `loginctl enable-linger $USER`
(by hand; `anfs bus status` says so).

## Bumping a version

Change `version` in `pins.yml`, run `tests/pins --print` (it fetches the assets) and paste the
sums; `tests/pins` checks them. The bats tests (`bats packages/nats/tests`) never reach the
network: curl, launchctl and systemctl are stubs.
