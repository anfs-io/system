# anfs-ui

A local dashboard over the anfs tools. It runs each tool's list command with `--json`, shows the results, and updates open pages as they change. Packages can be installed and removed, and containers and machines brought up and down, from their rows.

It ships as a pcm service of core (`containers/ui`, in the `system` stack). The API it will reach the tools through from a container is docs `units/toolkit-api.md`.

## Run

```sh
pcm up ui               # http://localhost:9292 (bound to 127.0.0.1 only)
pcm restart ui          # after an edit outside views/
```

Or on the host, for quick work on it with the tools reachable:

```sh
bundle install
bundle exec puma        # http://localhost:9292
```

**In the container the tools are not reachable** until the toolkit API (`anfs rpc`) exists: they run on the host, and so does `anfs.log`. Every panel then says "the tools are not reachable from here (no toolkit API yet)": there are no rows, so no actions either.

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
| `ANFS_BIN` | `~/.local/bin` | Where the tools are; when one is not there its panel says the tools are not reachable |
| `ANFS_UI_HOSTS` | none | Extra host names to answer to, comma-separated |
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
