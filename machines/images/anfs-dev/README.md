# anfs-dev

`debian-13` with the anfs toolkit installed from **this machine's sources**: a disposable VM to
try a change to anfs in (systemd, login shells, a real kernel), beside the podman boxes.

It has no files of its own but `image.yml`:

- `from: debian-13`: the user (`pmm`), the ssh key, the packages and `test.sh` are debian-13's.
- `anfs: {sources: host}`: after the provision steps, pmm copies every source clone under
  `~/.local/share/anfs/sources/` into the guest and runs `install.sh` there as the user. The
  image gets exactly what this machine has, uncommitted changes included, and needs no network
  for the sources.
- `build: {memory: 4096}`: the install is heavier than debian-13's.

The build key includes each source's commit and whether it has local changes, so
`pmm image build anfs-dev` rebuilds when a source moved and is a no-op when none did.

    pmm image build anfs-dev
    pmm run anfs-dev --rm
    pmm shell anfs-dev
