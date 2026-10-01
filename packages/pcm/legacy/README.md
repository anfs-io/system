# psm legacy: ideas from the ppm services backend

> **Note for Claude:** psm (Podman Service Manager) has been renamed to **pcm (Personal
> Container Manager)**. The package, binary, `pcm.zsh`, `~/.config/pcm`, the `x-pcm` compose key
> and the `PCM_*` env vars all use the new name. This folder deliberately still says psm: read
> every `psm`/`PSM_` below as `pcm`/`PCM_`, and port into `home/.local/bin/pcm`.

These files are verbatim copies of `ppm/lib/services/*.sh` from the ppm repo. That code was
psm's first design, which ran on top of ppm (`PPM_ASSET_DIR=services`). They are kept here
so the ideas survive when the psm code is deleted from ppm.

**Nothing here runs.** This folder is not stowed (ppm only stows `home/` and
`$PPM_GROUP_ID`), nothing sources it, and it depends on ppm internals (`collect_repos`,
`resolve_deps`, `find_package_dir`, `meta_mark_installed`, `debug`, `PPM_*`). Treat it as
reference material for porting into `home/.local/bin/psm`.

## Not in current psm (worth porting)

### Quadlet / systemd: `quadlet.sh`
- `_generate_quadlet` writes `/etc/containers/systemd/psm-<network>-<service>.container`:
  - `Image=` and `Volume=` come from the compose file's single service.
  - `Network=<network>` and `EnvironmentFile=<instance>/config/quadlet.env`.
  - `After=`/`Requires=` point at each dependency's unit, so systemd starts things in dependency order.
  - `Restart=always`, `TimeoutStartSec=300`, `WantedBy=multi-user.target`.
- It skips multi-container compose files with a warning, because one `.container` unit holds one container.
- `_build_quadlet_env` writes a persistent env file: `PSM_DATA/CONFIG/CACHE/SERVICE/NETWORK/TYPE`
  followed by the service's `.env`.
- `_remove_quadlet` runs `systemctl disable` and `stop`, removes the unit file and env file, then `daemon-reload`.
- Install runs `daemon-reload` and `enable`. `up`/`down` run `systemctl start`/`stop`. `status` runs
  `systemctl list-units 'psm-*'` (`service.sh`).
- Mapping to current psm:
  - Dependencies come from `x-psm.depends_on` (`service_deps`).
  - Env comes from `varlock load --format env` (`load_env`) rather than a raw `.env`.
  - The network comes from `registry.yml` `shared_network`.
  - Volumes are already restricted to `$PSM_VOLUMES_HOME/<service>/`.

### User vs system scope: `scope.sh`
- Scope comes from the `--user`/`--system` flags or `scope=` in `psm.conf`, and defaults to `user`.
- User scope: instances live in `$XDG_STATE_HOME/psm`. System scope: instances live in `/opt/psm`.
- System scope requires root on install (`service.sh` `profile_install`).
- Quadlets were generated only for system scope.

### Per-service isolated networks: `network.sh`
- A service can declare `network: <name>` in its metadata.
- Dependencies inherit the requesting service's network (install "context"), so a stack shares an
  isolated network. With no declaration it uses podman's built-in `default` network.
- `_ensure_network` creates the network on demand.
- Current psm has a single shared network (`registry.yml` `shared_network`, default `dev-net`) that
  services join via `network_attached_services` or by having dependencies.

### Instance layout and lifecycle: `service.sh`
- One instance per network: `<services-home>/<network>/<service>/{data,config,service→definition}`.
  The same service can run on several networks.
  - Compose project name is `<network>-<service>`.
  - `network/service` argument syntax, with an error when the name is ambiguous (`_parse_service_arg`,
    `_find_installed_network`).
- Remove stops containers and drops the definition link but **keeps `data/`**.
  - The current package instead refuses removal while containers run (`install.sh` `pre_remove`).
- Commands with no current equivalent:
  - `restart` runs down then up.
  - `logs <svc> [-f]`. Currently you can get this through `podman compose --psm logs`.
  - `status`: with no argument, every service grouped by network as running/stopped; with a service, `compose ps`.
- `up` auto-installs missing services in dependency order. `down` stops in reverse order.
- `show` extras (`backend_show`):
  - `description` and `ports` from the metadata.
  - Isolated vs shared network.
  - `pcm.yml` credentials present.
  - Resolved start order, and instances with data/config paths and running state.
- `install --up` starts services after installing (`scope.sh` flag, `ppm/ppm` `install()`).

### Small ideas: `compose.sh`
- Accept `compose.yaml`, `docker-compose.yml` and `docker-compose.yaml`, not just `compose.yml`.
- Export `PSM_DATA`, `PSM_CONFIG`, `PSM_CACHE`, `PSM_SERVICE`, `PSM_NETWORK` and `PSM_TYPE` to compose.
- `--skip-validation` bypasses varlock.
- `_require_podman` fails early when podman or podman-compose is missing.

## Already covered by current psm (don't port)
- Running compose with varlock: `compose_run` / `service_run` (plus fnox).
- Finding compose files: `compose_file`, `is_service`.
- Dependency start/stop order: `x-psm.depends_on`, `start_deps`, `shutdown_order` (ppm's graph was used before).
- Completion: `cmd_completion`.

## psm hooks still in `ppm/ppm` (for the later refactor)
- `list_commands`: the "Service lifecycle" block, shown when `backend_command` exists.
- `PPM_ASSET_DIR/HOOK/LABEL/META` overrides ("e.g. psm shell function"), and sourcing `lib/$PPM_ASSET_DIR/*.sh`.
- `install()`: `_PSM_INSTALL_NETWORK` network propagation and `PSM_START_AFTER_INSTALL` (`--up`).
- `main()`: the `parse_backend_flag` and `_resolve_scope` calls, and `backend_command` dispatch.
- `show()` → `backend_show`, and `completion()` → `backend_completion`.
