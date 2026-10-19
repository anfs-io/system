# anfs-ui

A local dashboard over the anfs tools. It runs each tool's list command with `--json`, shows the results, and updates open pages as they change. Packages can be installed and removed, and containers and machines brought up and down, from their rows.

Plan and findings: `~/spaces/user/dev/products/anfs-ui.md`.

## Run

```sh
bundle install
bundle exec puma        # http://localhost:9292
```

| Variable | Default | Purpose |
|---|---|---|
| `HOST` | `localhost` | Address to bind; `0.0.0.0` for every interface |
| `PORT` | `9292` | Port to listen on |
| `ANFS_BIN` | `~/.local/bin` | Where the tools are |
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
| `event_stream.rb` | The SSE connection that pushes Turbo Streams |
| `lib/anfs/kinds.rb` | The table of asset kinds: command, interval, status, source, columns |
| `lib/anfs/cli.rb` | Runs a tool and parses its JSON |
| `lib/anfs/store.rb`, `hub.rb`, `poller.rb` | Cache, fan-out, and the refresh threads |
| `lib/anfs/jobs.rb` | Commands that change something, run in the background |
| `views/` | Phlex components |
| `public/` | CSS, the one Stimulus controller, vendored Turbo 8.0.23 and Stimulus 3.2.2 |

To add a kind of asset, add an entry to `KINDS`. To give its rows a button, give the entry an `action`. Nothing else needs to change.
