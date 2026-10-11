#!/usr/bin/env bash
# pim library: the commands, declared (lib/anfs/cli.sh). Usage lines, help, the check of what was
# typed and tab completion all come from here. Sourced by ~/.local/bin/pim, and by the tests.

cli_cmd list "Images: NAME SOURCE STATUS (built arches, running, shadowed)" --alias ls
cli_cmd show "Definition, its from: chain, builds and instance" --arg "image"
cli_cmd path "Print the definition directory" \
  --opt "--disk: The built disk instead" --opt "--arch ARCH: Of that architecture" --arg "image"
cli_cmd cd "Change to an image definition (requires pim.zsh)" --arg "[image]"
cli_cmd validate "Check definitions (all if none given); build runs it first" --arg "[image...]"
cli_cmd install "Build images; source/ is every image that source defines
(\`anfs install\` uses this). PIM_INSTALL=validate only validates" --arg "image-spec..."
cli_cmd build "Build an image (and its from: parents) unless the build is current" \
  --opt "-f --force: Rebuild" --opt "-v --verbose: Show script output" \
  --opt "--arch ARCH: For that architecture" --opt "--console: Show the installer's console" \
  --opt "--verify: Run verify.sh on the result" --arg "image..."
cli_cmd verify "Boot a throwaway copy and run the image's verify.sh" \
  --opt "--arch ARCH: Of that architecture" --arg "image"
cli_cmd up "Start the image's VM (a persistent overlay on the build)" --alias run \
  --opt "--fresh: Recreate it" --opt "--snapshot: Discard what it writes" \
  --opt "--console: Attach to its console" --opt "--arch ARCH: Of that architecture" \
  --opt "--share PATH: Share a directory: PATH[:tag][:ro]" \
  --opt "-p --publish PORT: Forward a port: host:guest" --arg "image"
cli_cmd shell "Log in to a running VM (as the image's user), or run a command: <image> [-- cmd...]" \
  --alias ssh --passthrough --opt "-u --user USER: As that user" --arg "image" --arg "[word...]"
cli_cmd down "Shut a VM down (guest poweroff, then QMP, then kill)" --alias stop --arg "image..."
cli_cmd ps "Running VMs: NAME ARCH PID SSH"
cli_cmd snapshot "Save the stopped VM's disk; no name lists snapshots" --arg "image" --arg "[snapshot]"
cli_cmd reset "Recreate the VM from a snapshot, or from its build" \
  --opt "-y --yes: Do not ask" --arg "image" --arg "[snapshot]"
cli_cmd publish "Write the build as one standalone qcow2" \
  --opt "-c --compress: Compressed" --opt "-o --output FILE: There (default: ./<image>-<arch>.qcow2)" \
  --opt "--arch ARCH: Of that architecture" --arg "image"
cli_cmd remove "Stop and delete the VM and every build of the image; the
definition is kept" --alias rm \
  --opt "-y --yes: Do not ask" --opt "-f --force: Even if other builds are based on it" --arg "image..."
cli_cmd clean "Delete superseded builds nothing is based on" --opt "--isos: The ISO cache too"
cli_cmd implode "Stop every VM and delete everything pim created" --opt "-y --yes: Do not ask"
cli_standard
