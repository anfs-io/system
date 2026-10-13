#!/usr/bin/env bash
# pmm library: the commands, declared (lib/anfs/cli.sh). Usage lines, help, the check of what was
# typed and tab completion all come from here. Sourced by ~/.local/bin/pmm, and by the tests.

cli_cmd list "Machines: NAME SOURCE IMAGE STATE ADDRESS" --alias ls
cli_cmd ps "Running machines: NAME ARCH BACKEND PID SSH"
cli_cmd show "Definition, settings, the build it is on, snapshots" --arg "machine"
cli_cmd path "Print the definition directory" --arg "machine"
cli_cmd cd "Change to a machine definition (requires pmm.zsh)" --arg "[machine]"
cli_cmd validate "Check definitions (all if none given); up runs it first" --arg "[machine...]"
cli_cmd create "Make a machine without starting it. With --image and a new name, a
definition is written first (\$PMM_MACHINES_HOME)" \
  --opt "--image IMAGE: The image it runs from" \
  --opt "--media MEDIA: An ISO or disk image to boot from when its disk does not: a file, or an ISO's id. Without --image: a blank machine" \
  --opt "--profile PROFILE: A named shape" \
  --opt "--cpus N: Virtual CPUs" --opt "--memory SIZE: 8G, 512M, or MB" \
  --opt "--disk SIZE: Grow its disk to this (a blank machine: its size)" --opt "--share PATH: Share a directory: PATH[:tag][:ro]" \
  --opt "-p --publish PORT: Forward a port: host:guest" --opt "--user USER: Who shell logs in as" \
  --opt "--arch ARCH: Of that architecture" --arg "machine"
cli_cmd up "Start machines, creating one that is defined and not made yet.
With --image and no name: a machine named after the image" --alias run \
  --opt "--image IMAGE: Define it from this image first, if it is not defined" \
  --opt "--console: Attach to its console" \
  --opt "--display: Give it a screen: a window, or VNC on 127.0.0.1 where the host has none" \
  --opt "--media MEDIA: For this run, boot from an ISO or disk image first: a file, or an ISO's id" \
  --opt "--share PATH: For this run, share a directory: PATH[:tag][:ro]" \
  --opt "-p --publish PORT: For this run, forward a port: host:guest" --arg "[machine...]"
cli_cmd down "Shut machines down (guest poweroff, then QMP, then kill)" --alias stop --arg "machine..."
cli_cmd shell "Log in to a running machine, or run a command: <machine> [-- cmd...]" \
  --alias ssh --passthrough --opt "-u --user USER: As that user" --arg "machine" --arg "[word...]"
cli_cmd snapshot "Save the machine's disk (stopped first, restarted after); no name
lists its snapshots" --arg "machine" --arg "[snapshot]"
cli_cmd reset "Recreate the machine from a snapshot, or onto its image's current build" \
  --opt "-y --yes: Do not ask" --arg "machine" --arg "[snapshot]"
cli_cmd remove "Stop and delete machines and their snapshots; a local definition
goes too, a source's is kept" --alias rm --opt "-y --yes: Do not ask" --arg "machine..."
cli_cmd install "Create and start machines; source/ is everything that source defines:
its images are built, its networks installed, then its machines (\`anfs
install\` uses this). PMM_INSTALL=create starts nothing, PMM_INSTALL=validate
only validates" --arg "machine-spec..."
cli_group image "What machines run from: definitions and their builds"
cli_cmd "image list" "Images, a row per built arch: NAME SOURCE ARCH STATE KEY ..." --alias ls --arg "[image...]"
cli_cmd "image show" "Definition, its from: chain and builds" --arg "image"
cli_cmd "image build" "Build an image (and its from: parents) unless the build is current" \
  --opt "-f --force: Rebuild" --opt "-v --verbose: Show script output" \
  --opt "--arch ARCH: For that architecture" --opt "--console: Show the installer's console" \
  --opt "--test: Run test.sh on the result" --arg "image..."
cli_cmd "image test" "Boot a throwaway copy of the build and run the image's test.sh" \
  --opt "--arch ARCH: Of that architecture" --arg "image"
cli_cmd "image export" "Write the build as one standalone qcow2" \
  --opt "-c --compress: Compressed" --opt "-o --output FILE: There (default: \$PMM_DATA_HOME/exports/)" \
  --opt "--arch ARCH: Of that architecture" --arg "image"
cli_cmd "image remove" "Delete every build of the image; the definition is kept" --alias rm \
  --opt "-y --yes: Do not ask" --opt "-f --force: Even if other builds or machines are on it" --arg "image..."
cli_cmd "image prune" "Delete superseded builds nothing is on" --opt "--isos: The ISOs the images name too"
cli_cmd "image path" "Print the definition directory" \
  --opt "--disk: The built disk instead" --opt "--arch ARCH: Of that architecture" --arg "image"
cli_cmd "image cd" "Change to an image definition (requires pmm.zsh)" --arg "[image]"
cli_cmd "image validate" "Check definitions (all if none given); build runs it first" --arg "[image...]"
cli_group network "Networks machines are on: names, fixed addresses, bridges (Linux)"
cli_cmd "network list" "Networks: NAME SOURCE KIND SUBNET STATE MACHINES" --alias ls
cli_cmd "network show" "Definition, bridge, addresses, the machines on it" --arg "network"
cli_cmd "network path" "Print the definition directory" --arg "network"
cli_cmd "network create" "Define a network (\$PMM_NETWORKS_HOME) and install it" \
  --opt "--kind KIND: nat, isolated or bridged" --opt "--subnet CIDR: For nat and isolated: 10.20.0.0/24" \
  --opt "--interface BRIDGE: For bridged: a bridge the host has" \
  --opt "--domain DOMAIN: Names resolve under it: web1.lab" --arg "network"
cli_cmd "network install" "Make networks from their definitions; source/ is every network
that source defines. A machine's networks are installed with it" --arg "network-spec..."
cli_cmd "network remove" "Take networks away; refused while machines are on one. A local
definition goes too, a source's is kept" --alias rm --opt "-y --yes: Do not ask" --arg "network..."
cli_cmd implode "Stop every machine and delete everything pmm created: machines, builds, networks" --opt "-y --yes: Do not ask"
cli_standard
