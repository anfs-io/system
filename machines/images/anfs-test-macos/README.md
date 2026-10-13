# anfs-test-macos

The macOS test box's image (`ppm vm`, `packages/anfs/tests/roundtrip-macos`), on the tart
backend: Apple silicon only. It starts from Cirrus Labs' vanilla macOS (`base:`, a 25 GB pull the
first time), not an ISO, so it has no answer file.

| File | What it is |
| --- | --- |
| `image.yml` | the base image, 4 cpus and 8 GB for the build, the user and the stock image's account |
| `provision/10-provision.sh` | the two test users, their ssh access, sudo's timeout, `/src` |
| `test.sh` | what `pmm image test anfs-test-macos` checks |

## What a machine gets

- **`owner`**, an admin whose password is `owner` (the sudo prompt is part of what is tested),
  and **`other`**, who is not. Both accept the image's ssh key. `pmm shell` logs in as `owner`.
- **`admin`/`admin`**, the stock image's account (`user.bootstrap`): pmm uses it once, with its
  password, to install the key, and the provision steps run as root through its sudo.
- **`/src`**, a link (`/etc/synthetic.conf`) to where tart mounts shares: the machine
  `machines/anfs-test-macos` shares the host's sources there, read-only.
- **No Homebrew and no Xcode command line tools**, on purpose: a run exercises all of
  `install.sh`.

It matches the Linux test boxes (`containers/anfs-test-*`), so the same tests mean the same thing
on both. Apple allows two macOS guests running at once.
