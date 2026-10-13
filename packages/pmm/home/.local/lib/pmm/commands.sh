#!/usr/bin/env bash
# pmm library: the commands, declared (lib/anfs/cli.sh). Usage lines, help, the check of what was
# typed and tab completion all come from here. Sourced by ~/.local/bin/pmm, and by the tests.

cli_cmd run "A machine from an image, started. No definition is written: its settings
are kept with its disk. The name is the image's, then <image>-2, <image>-3.
With --media and no image: a blank machine" \
  --opt "--name NAME: Its name" \
  --opt "--rm: Remove it when it is shut down" \
  --opt "--no-start: Make it and leave it stopped" \
  --opt "--profile PROFILE: A named shape" \
  --opt "--cpus N: Virtual CPUs" --opt "--memory SIZE: 8G, 512M, or MB" \
  --opt "--disk SIZE: Grow its disk to this (a blank machine: its size)" --opt "--share PATH: Share a directory: PATH[:tag][:ro]" \
  --opt "-p --publish PORT: Forward a port: host:guest" \
  --opt "--media MEDIA: An ISO or disk image to boot from when its disk does not: a file, or an ISO's id. With no image: a blank machine" \
  --opt "--user USER: Who shell logs in as" \
  --opt "--arch ARCH: Of that architecture" --arg "[image]"
cli_cmd up "Start machines: a defined one is made first if it is not yet" \
  --opt "--console: Attach to its console" \
  --opt "--display: Give it a screen: a window, or VNC on 127.0.0.1 where the host has none" \
  --opt "--media MEDIA: For this run, boot from an ISO or disk image first: a file, or an ISO's id" \
  --opt "--share PATH: For this run, share a directory: PATH[:tag][:ro]" \
  --opt "-p --publish PORT: For this run, forward a port: host:guest" --arg "[machine...]"
cli_cmd down "Shut machines down (guest poweroff, then QMP, then kill)" --alias stop --arg "machine..."
cli_cmd shell "Log in to a running machine" \
  --alias ssh --passthrough --opt "-u --user USER: As that user" --arg "machine" --arg "[word...]"
cli_cmd exec "Run a command in a running machine: <machine> -- <cmd>..." \
  --passthrough --opt "-u --user USER: As that user" --arg "machine" --arg "word..."
cli_cmd ps "Running machines: NAME ARCH BACKEND PID SSH"
cli_cmd list "Every machine, defined, made or running: NAME SOURCE IMAGE STATE ADDRESS" --alias ls
cli_cmd show "Settings, the build it is on, snapshots" --arg "machine"
cli_cmd reset "Recreate the machine from a snapshot, or onto its image's current build" \
  --opt "-y --yes: Do not ask" --arg "machine" --arg "[snapshot]"
cli_cmd remove "Stop and delete machines and their snapshots; a definition is kept" \
  --alias rm --opt "-y --yes: Do not ask" --arg "machine..."
cli_cmd path "Print the definition directory" --arg "machine"
cli_cmd cd "Change to a machine definition (requires pmm.zsh)" --arg "[machine]"
cli_cmd validate "Check definitions (all if none given); up runs it first" --arg "[machine...]"
cli_group snapshot "Saved copies of a machine's disk"
cli_cmd "snapshot list" "A machine's snapshots: NAME BUILD" --alias ls --arg "machine"
cli_cmd "snapshot create" "Save the machine's disk (stopped first, restarted after); with no
name, named for the time" --arg "machine" --arg "[snapshot]"
cli_cmd "snapshot remove" "Delete a snapshot" --alias rm --opt "-y --yes: Do not ask" --arg "machine" --arg "snapshot"
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
cli_cmd "network create" "Make a network now; recorded with pmm's data, no definition" \
  --opt "--kind KIND: nat, isolated or bridged" --opt "--subnet CIDR: For nat and isolated: 10.20.0.0/24" \
  --opt "--interface BRIDGE: For bridged: a bridge the host has" \
  --opt "--domain DOMAIN: Names resolve under it: web1.lab" --arg "network"
cli_cmd "network show" "Settings, bridge, addresses, the machines on it" --arg "network"
cli_cmd "network path" "Print the definition directory" --arg "network"
cli_cmd "network install" "Make networks from their definitions; source/ is every network
that source defines. A machine's networks are installed with it" --arg "network-spec..."
cli_cmd "network remove" "Take networks away; refused while machines are on one. A definition
is kept" --alias rm --opt "-y --yes: Do not ask" --arg "network..."
cli_cmd install "Create and start machines; source/ is everything that source defines:
its images are built, its networks installed, then its machines (\`anfs
install\` uses this). PMM_INSTALL=create starts nothing, PMM_INSTALL=validate
only validates" --arg "machine-spec..."
cli_cmd implode "Stop every machine and delete everything pmm created: machines, builds, networks" --opt "-y --yes: Do not ask"
cli_standard
