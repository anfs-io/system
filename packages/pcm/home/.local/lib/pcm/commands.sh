#!/usr/bin/env bash
# pcm library: the commands, declared (lib/anfs/cli.sh). Usage lines, help, the check of what was
# typed and tab completion all come from here. Sourced by ~/.local/bin/pcm, and by the tests.

cli_cmd list "Services: CONTAINER STATUS (running, stopped, shadowed)" --alias ls
cli_cmd show "Definition, dependencies, data, containers, ports and mounts
(declared ones when nothing is created)" --arg "service"
cli_cmd path "Print the path of a service definition" --arg "service"
cli_cmd cd "Change to a service definition (requires pcm.zsh)" --arg "[service]"
cli_cmd install "Validate and start services; source/ is every service that
source defines (\`anfs install\` uses this)" --arg "service-spec..."
cli_cmd up "Start services, detached unless -d/--detach is given; other
options go on to podman compose" --passthrough --arg "service..."
cli_cmd down "Stop services; refuses if running services depend on them;
other options go on to podman compose" --passthrough \
  --opt "-f --force: Stop the dependents first" --arg "service..."
cli_cmd remove "Down, then delete everything pcm created for it: containers,
networks, built images, its data under \${PCM_VOLUMES_HOME}/<name>/;
runs dependencies' deprovision hooks. The definition is kept." --alias rm \
  --opt "-y --yes: Do not ask" --opt "-f --force: Stop running dependents" --arg "service..."
cli_cmd ps "pcm's containers (podman ps; options go on to it)" --passthrough --arg "[service...]"
cli_cmd exec "Run a command in a running service's container: <service> -- <cmd>..." --passthrough \
  --opt "-u --user USER: As that user" --opt "-s --service NAME: In that compose service" \
  --arg "service" --arg "word..."
cli_cmd shell "A login shell in a running service's container" \
  --opt "-u --user USER: As that user" --opt "-s --service NAME: In that compose service" --arg "service"
cli_cmd snapshot "Save the service as it is: containers committed to images,
its data copied. No name lists the snapshots (* = active)" --arg "service" --arg "[snapshot]"
cli_cmd reset "Recreate the service from a snapshot, or from its definition
with fresh data; replaces its data" --opt "-y --yes: Do not ask" --arg "service" --arg "[snapshot]"
cli_cmd validate "Check services against pcm conventions (all if none given);
\`up\` runs it before starting anything" --arg "[service...]"
cli_cmd implode "Delete every container, network, volume and directory pcm
created, whichever definition it came from" --opt "-y --yes: Do not ask"
cli_standard
