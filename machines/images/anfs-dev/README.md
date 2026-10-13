# anfs-dev

`debian-13` with the anfs toolkit installed from **this machine's sources**: a disposable VM to
try a change to anfs in (systemd, login shells, a real kernel), beside the podman boxes.

| File | What it is |
| --- | --- |
| `image.yml` | `from: debian-13`: the user (`pmm`), the ssh key, the packages and `test.sh` are debian-13's. `build: {memory: 4096}`: the install is heavier than debian-13's |
| `provision/50-toolkit.anfs` | `sources: host`, a step for pmm's `anfs` provisioner |

The step is not a script: its extension names the provisioner that runs it. `anfs` runs on the
host. It copies every source clone under `~/.local/share/anfs/sources/` into the guest and runs
`install.sh` there as the user, so the image gets exactly what this machine has, uncommitted
changes included, and needs no network for the sources.

The build key includes each source's commit and whether it has local changes (the provisioner's
`fingerprint` names them), so `pmm image build anfs-dev` rebuilds when a source moved and is a
no-op when none did.

    pmm image build anfs-dev
    pmm run anfs-dev --rm
    pmm shell anfs-dev
