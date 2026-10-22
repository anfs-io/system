# anfs-ui

A local dashboard over the anfs tools. It runs each tool's list command with `--json`, shows the results, and updates open pages as they change. Packages can be installed and removed, and containers and machines brought up and down, from their rows.

It ships as a pcm service of core (`containers/ui`, in the `system` stack, running). In the container it reaches the tools through the toolkit API (`anfs rpc`, core AGENTS.md "The toolkit API").

## Run

```sh
pcm up ui               # http://localhost:9292 (bound to 127.0.0.1 only)
pcm down ui && pcm up ui   # after an edit outside views/
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

Or on the host, for quick work on it with the tools reachable:

```sh
bundle install
bundle exec puma        # http://localhost:9292
```

**Two modes, one switch** (`Anfs::RPC.from_env`): with `ANFS_RPC_URL` set (`tcp://host:port` or `unix:///path`; pcm sets it from `container.yml`'s `toolkit: write`) every list, command and event goes through the toolkit API: lists as `{"run":[...]}`, commands as a stream with `yes`, and a `{"watch":true}` connection (reconnecting with backoff) instead of following `anfs.log`. The token line goes first when `ANFS_RPC_TOKEN` is set. Without it the tools run from `ANFS_BIN` and the poller follows `anfs.log` (on the host). With neither, every panel says the tools are not reachable. A command that needs a terminal (exit 77) shows "Run this in a terminal: <command>"; a write refused under a read grant says so.

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

## Test

```sh
bundle exec rspec
bundle exec rubocop
```

## Layout

| Path | What it is |
|---|---|
| `app.rb` | Roda app: plugins and every route |
| `config.ru` | Starts the poller; reloads `views/` in development |
| `Containerfile`, `compose.yml`, `container.yml` | The pcm service: image targets, how pcm runs it, its manifest |
| `event_stream.rb` | The SSE connection that pushes Turbo Streams |
| `lib/anfs/kinds.rb` | The table of asset kinds: command, interval, status, source, columns |
| `lib/anfs/cli.rb` | Runs a tool and parses its JSON |
| `lib/anfs/store.rb`, `hub.rb`, `poller.rb` | Cache, fan-out, and the refresh threads |
| `lib/anfs/jobs.rb` | Commands that change something, run in the background |
| `views/` | Phlex components |
| `public/` | CSS, the one Stimulus controller, vendored Turbo 8.0.23 and Stimulus 3.2.2 |

To add a kind of asset, add an entry to `KINDS`. To give its rows a button, give the entry an `action`. Nothing else needs to change.
