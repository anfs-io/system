#!/usr/bin/env bash
# pcm library: the commands, declared (lib/anfs/cli.sh). Usage lines, help, the check of what was
# typed and tab completion all come from here. Sourced by ~/.local/bin/pcm, and by the tests.

cli_cmd list "Services: CONTAINER STATUS (running, stopped, shadowed) VERSION" --alias ls
cli_cmd show "Definition (container.yml), images, env names, dependencies, data,
containers, ports and mounts (declared ones when nothing is created)" --arg "service"
cli_cmd path "Print the path of a service definition" --arg "service"
cli_cmd cd "Change to a service definition (requires the pcm shell function)" --arg "[service]"
cli_cmd install "Validate and start services; source/ is every service that
source defines (\`anfs install\` uses this)" \
  --opt "-y --yes: Do not ask before installing a whole source/" --arg "service-spec..."
cli_cmd up "Start services, detached unless -d/--detach is given; other
options go on to podman compose" --passthrough --arg "service..."
cli_cmd down "Stop services; refuses if running services depend on them;
other options go on to podman compose" --passthrough \
  --opt "-f --force: Stop the dependents first" --arg "service..."
cli_cmd remove "Down, then delete everything pcm created for it: containers,
networks, built images, its data under \${PCM_VOLUMES_HOME}/<name>/;
runs dependencies' deprovision hooks. The definition is kept." --alias rm \
  --opt "-y --yes: Do not ask before deleting" --opt "-f --force: Stop running dependents" --arg "service..."
cli_cmd provision "Run the service's provision hook for a consumer that is not a pcm
definition (a host-run app), as up runs it for a dependent: starts the service
if it is not running, waits for it to be healthy; settings are key=value args.
Prints the hook's KEY=VALUE lines (secrets: never logged); --json, an object" \
  --opt "--as NAME: PCM_DEPENDENT, who it is for (default: external)" --arg "service" --arg "[setting...]"
cli_cmd deprovision "Run the service's deprovision hook for that consumer, with the
same settings; a service that is not running is not started (what it
provisioned is left in place, exit 1)" \
  --opt "--as NAME: PCM_DEPENDENT, who it was for (default: external)" --arg "service" --arg "[setting...]"
cli_cmd ps "pcm's containers (podman ps; options go on to it)" --passthrough --arg "[service...]"
cli_cmd exec "Run a command in a running service's container: <service> -- <cmd>..." --passthrough \
  --opt "-u --user USER: As that user" --opt "-s --service NAME: In that compose service" \
  --arg "service" --arg "word..."
cli_cmd run "A one-off container of a service (compose run): its image, env,
network, mounts and labels; removed on exit. No command runs what the service
runs. Starts what it requires (x-pcm.depends_on, compose depends_on) as up
does. For a stock image, plain podman run --rm <image> is the tool" --passthrough \
  --opt "--keep: Keep the container when it exits" --opt "-u --user USER: As that user" \
  --opt "-s --service NAME: Of that compose service (needed when there are several)" \
  --arg "service" --arg "[cmd...]"
cli_cmd shell "A login shell in a running service's container" \
  --opt "-u --user USER: As that user" --opt "-s --service NAME: In that compose service" --arg "service"
cli_cmd snapshot "Save the service as it is: containers committed to images,
its data copied. No name lists the snapshots (* = active)" \
  --opt "-y --yes: Do not ask before replacing a snapshot of that name" --arg "service" --arg "[snapshot]"
cli_cmd reset "Recreate the service from a snapshot, or from its definition
with fresh data; replaces its data" --opt "-y --yes: Do not ask before replacing its data" --arg "service" --arg "[snapshot]"
cli_cmd validate "Check services against pcm conventions (all if none given);
\`up\` runs it before starting anything" --arg "[service...]"
cli_group machine "The podman machine containers run in (macOS)"
cli_cmd "machine resize" "Stop, resize and start the podman machine; no size is what
runs needs (container.yml memory:) plus headroom. Confirms when containers run" \
  --opt "-y --yes: Do not ask before stopping running containers" --arg "[size]"
cli_cmd implode "Delete every container, network, volume and directory pcm
created, whichever definition it came from" --opt "-y --yes: Do not ask before imploding"
anfs_config_declare
cli_standard
