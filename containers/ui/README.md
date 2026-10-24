# anfs-ui

A local dashboard over the anfs tools. It runs each tool's list command with `--json`, shows the results, and updates open pages as they change. Packages can be installed and removed, and containers and machines brought up and down, from their rows.

Every table sorts by the header clicked (again: the other way), with ▲/▼ and `aria-sort` on that column. Versions sort by version (0.10.0 after 0.9.0), times by time, numbers by number, text without case and naturally (item2 before item10), blanks last. The choice is kept per table in the browser (`localStorage`), and applied again each time the table is re-rendered by an update and on every page; nothing chosen, the server's order stands.

It ships as a pcm service of core (`containers/ui`, in the `system` stack, running). In the container it reaches the tools through the toolkit API (`anfs rpc`, core AGENTS.md "The toolkit API"), and hears what changes from the bus (core/nats and anfsd, core AGENTS.md "The bus"). The bus is required: install core/nats and core/anfsd first.

## Run

```sh
pcm up ui               # http://localhost:9292 (bound to 127.0.0.1 only)
pcm down ui && pcm up ui   # after an edit outside views/
# after a Gemfile change the dev image needs building again: pcm up reuses the one it has
pcm down ui && podman rmi localhost/anfs-ui:dev && pcm up ui
```

Where it listens is `.env.schema` (`varlock load --path .` checks it). Overrides go in `~/.config/pcm/containers/ui/local.env`, then `pcm up ui` (it recreates the container when its environment changed):

```sh
# every interface: the LAN can reach it. There is no login, so name what you browse to
ANFS_UI_BIND=0.0.0.0
ANFS_UI_HOSTS=mymac.local,192.168.1.20
# or one address only (the Mac's LAN IP, a tailscale IP): ANFS_UI_BIND=100.64.0.7
```

| Variable | Default | Purpose |
|---|---|---|
| `ANFS_UI_BIND` | `127.0.0.1` | Host address the port is published on; on macOS podman's VM forwards it to the host |
| `ANFS_UI_PORT` | `9292` | Host port (the container's is 9292) |
| `ANFS_UI_HOSTS` | none | Names and IPs you browse to, when not localhost |
| `ANFS_UI_REMOTE_ACTIONS` | `0` | `1` lets other machines run commands. No login, and the container holds the toolkit's write grant |
| `ANFS_UI_BUS_URL` | `nats://host.containers.internal:47222` | Where the container reaches NATS; change it only with `ANFS_NATS_PORT` in `nats.local.env` |

The reader's password is not a setting: `compose.yml` mounts core/nats's own `~/.local/state/nats/users/reader` read-only at `/run/secrets/anfs-bus-reader` (allowed by `x-pcm.allow_mounts`). It is never in the image, the environment or a log.

Or on the host, for quick work on it with the tools reachable:

```sh
bundle install
bundle exec puma        # http://localhost:9292, on the host's bus (its port file and users/reader)
```

**The tools, two modes, one switch** (`Anfs::RPC.from_env`): with `ANFS_RPC_URL` set (`tcp://host:port` or `unix:///path`; pcm sets it from `container.yml`'s `toolkit: write`) every list and command goes through the toolkit API: lists as `{"run":[...]}`, commands as a stream with `yes`. The token line goes first when `ANFS_RPC_TOKEN` is set. Without it the tools run from `ANFS_BIN` (on the host). With neither, every panel says the tools are not reachable. A command that needs a terminal (exit 77) shows "Run this in a terminal: <command>"; a write refused under a read grant says so.

**What changes, from the bus** (`lib/anfs/bus.rb`, `poller.rb`): the ui is NATS's `reader` user, with the durable consumer `ui` on stream `ANFS` (every `anfs.>` subject; made once, new events only), and each event updates the kind it names and nothing else:

| Event | Updates |
|---|---|
| `container.started`, `.created`, `.died`, `.stopped`, `.paused`, `.unpaused`, `.removed` | the service's row in Containers (`data.pcm`), from the event's data: no command |
| `podman.connected`, `podman.disconnected` | Containers: one `pcm list` |
| `source.updated` | Sources: one `anfs src list` |
| the rest (`report.*`, `run.*`, `pod.*`, `container.health`) | only the Events page |

Reads and re-renders an event causes are coalesced: the first at once, then at most one per kind every 2 s. Every kind is also listed every 5 minutes (`Anfs::RECONCILE`), and when a command run from here ends. Stacks, packages, images, machines, spaces, repositories and skills have no events yet, so a change made in a terminal shows at the next of those. The bus unreachable (or the password unreadable): the overview and the Events page say so, with why and the next try (1, 2, 5, 10, 30, then every 60 s), and the 5-minute lists go on. The password is never logged.

## The image

`Containerfile` has two targets:

| Target | What |
|---|---|
| `dev` | Ruby and the gems (`bundle install` from `Gemfile.lock`), no app source. `compose.yml` builds it and mounts this directory read-only at `/app`, with `RACK_ENV=development` |
| `release` | `dev` plus `COPY . /app`, `RACK_ENV=production`: what a published image will be |

Gems are in the image (`/usr/local/bundle`) and puma writes only under `/tmp`, so `/app` stays read-only. In development `config.ru` reloads `views/` when a file changes (rack-unreloader), so a view edited on the host shows on the next request. `app.rb` and `lib/` hold the store, the hub and the poller's threads, which a reload would orphan: restart for those.

| Variable | Default | Purpose |
|---|---|---|
| `HOST` | `localhost` | Address to bind; `0.0.0.0` for every interface |
| `PORT` | `9292` | Port to listen on |
| `ANFS_RPC_URL` | none | The toolkit API: `tcp://host:port` or `unix:///path`. Set, it replaces `ANFS_BIN` and `anfs.log` |
| `ANFS_RPC_TOKEN` | none | Sent as the first line, `{"token":"..."}` (the macOS listener) |
| `ANFS_BIN` | `~/.local/bin` | Where the tools are without `ANFS_RPC_URL`; when one is not there its panel says the tools are not reachable |
| `ANFS_UI_HOSTS` | none | Extra host names to answer to, comma-separated (required whenever it is reached by another name) |
| `ANFS_UI_REMOTE_ACTIONS` | off | `1` lets other machines run commands, not only view. There is no login |
| `ANFS_BUS_URL` | `nats://127.0.0.1:<~/.local/state/nats/port>` | The bus (compose sets it from `ANFS_UI_BUS_URL`) |
| `ANFS_BUS_USER` | `reader` | Its user |
| `ANFS_BUS_PASSWORD_FILE` | `~/.local/state/nats/users/reader` | The file holding its password (in the container `/run/secrets/anfs-bus-reader`) |

## Test

```sh
bundle exec rspec       # the bus's specs also run against a throwaway nats-server when one is on PATH,
                        # and sort_spec runs node --test spec/js when node is
bundle exec rubocop
```

## Layout

| Path | What it is |
|---|---|
| `app.rb` | Roda app: plugins and every route |
| `config.ru` | Starts the bus and the poller; reloads `views/` in development |
| `Containerfile`, `compose.yml`, `container.yml` | The pcm service: image targets, how pcm runs it, its manifest |
| `event_stream.rb` | The SSE connection that pushes Turbo Streams |
| `lib/anfs/kinds.rb` | The table of asset kinds: command, interval, status, source, columns |
| `lib/anfs/cli.rb` | Runs a tool and parses its JSON |
| `lib/anfs/store.rb`, `hub.rb`, `poller.rb` | Cache, fan-out, and the refresh threads; what an event updates |
| `lib/anfs/bus.rb`, `bus_config.rb`, `bus_status.rb` | The bus: the consumer, its backoff, its state for the pages |
| `lib/anfs/container_rows.rb` | Containers kept current from container.* events |
| `lib/anfs/coalescer.rb`, `event_log.rb` | The 2 s guard for re-renders; the latest events for `/events` |
| `lib/anfs/jobs.rb` | Commands that change something, run in the background |
| `views/` | Phlex components; `Views::Sortable` (components.rb) makes a table sortable: `sortable_table(key)`, `sort_header(label, type:)`, cells' `data-sort-value` |
| `public/` | CSS, the Stimulus controllers (filter, sort), `sort.js` (how values compare), vendored Turbo 8.0.23 and Stimulus 3.2.2 |

To add a kind of asset, add an entry to `KINDS`. To give its rows a button, give the entry an `action`. Nothing else needs to change.
