#!/usr/bin/env bats
# image-validate.sh: what an image definition must get right
load helper

setup() { setup_images; }

v() { load_images; run cmd_image_validate "$@"; }

@test "a good debian image validates" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  v d
  [ "$status" -eq 0 ]
  [[ "$output" == *"local/d ok"* ]]
}

@test "iso: an id per declared arch, in the catalogue, with a pinned sha256; inline url and sha256 are gone" {
  printf -- '- {id: loose, url: https://x/l.iso, checksum_url: https://x/SHA256SUMS}\n' >> "$HOME/.config/anfs/isos.yml"
  image "$PMM_IMAGES_HOME/a" "distro: debian
arch: [arm64, amd64]
iso: {arm64: nosuch}"
  image "$PMM_IMAGES_HOME/l" "distro: debian
arch: [arm64]
iso: {arm64: loose}"
  image "$PMM_IMAGES_HOME/old" "distro: debian
arch: [arm64]
iso: {arm64: {url: https://x/a.iso, sha256: $SHA}}"
  v a l old
  [ "$status" -ne 0 ]
  [[ "$output" == *"iso.arm64: no ISO 'nosuch' in the catalogue"* ]]
  [[ "$output" == *"iso.amd64 is missing"* ]]
  [[ "$output" == *"iso.arm64: the catalogue entry 'loose' pins no sha256"* ]]
  [[ "$output" == *"iso.arm64: an inline url and sha256 are gone; name an id in the ISO catalogue"* ]]
  # and a build says the same instead of installing from an unpinned file
  run cmd_image_build l
  [ "$status" -ne 0 ]
  ! grep -q qemu-system "$PMM_CALLS"
}

@test "a root image with no answer file fails; a from: image has none" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  rm "$PMM_IMAGES_HOME/d/preseed.cfg"
  image "$PMM_IMAGES_HOME/e" "$(deb_yml)"
  image "$PMM_IMAGES_HOME/c" "from: e"
  v d
  [ "$status" -ne 0 ]
  [[ "$output" == *"no answer file: a debian image installs with its own preseed.cfg"* ]]
  v c e
  [ "$status" -eq 0 ]
  cp "$PMM_IMAGES_HOME/e/preseed.cfg" "$PMM_IMAGES_HOME/c/preseed.cfg"
  v c
  [ "$status" -eq 0 ]
  [[ "$output" == *"preseed.cfg is ignored on a from: image"* ]]
}

@test "an unknown backend and arch; the old shape is said, not ignored" {
  image "$PMM_IMAGES_HOME/b" "backend: vbox"
  image "$PMM_IMAGES_HOME/c" "distro: debian
arch: [riscv]"
  image "$PMM_IMAGES_HOME/o" "$(deb_yml 'memory: 4096
anfs: {sources: host}
scripts: {defaults: false}')"
  mkdir -p "$PMM_IMAGES_HOME/o/scripts" "$PMM_IMAGES_HOME/o/provision"
  echo 'echo x' > "$PMM_IMAGES_HOME/o/scripts/10-x.sh"
  : > "$PMM_IMAGES_HOME/o/provision/20-empty.sh"
  v b c o
  [ "$status" -ne 0 ]
  [[ "$output" == *"backend 'vbox'"* ]]
  [[ "$output" == *"arch 'riscv'"* ]]
  [[ "$output" == *"memory: is build.memory now"* ]]
  [[ "$output" == *"scripts/ is never run: the steps are in provision/ now"* ]]
  [[ "$output" == *"scripts: is gone"* ]]
  [[ "$output" == *"provision/20-empty.sh is empty"* ]]
  [[ "$output" == *"anfs: is gone: a step holds it now (provision/50-toolkit.anfs"* ]]
  # every file in provision/ is a step now: provision.bats
}

@test "the shipped images validate: every file a build reads is in the image, every ISO in core's catalogue" {
  core_source
  v core/debian-13 core/fedora-44 core/anfs-dev core/anfs-test-macos
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"4 image(s): 0 error(s), 0 warning(s)"* ]]
  [ "$(img_answer_file core/anfs-dev)" = "$(img_dir core/debian-13)/preseed.cfg" ]
  [ "$(img_steps core/fedora-44)" = "$(img_dir core/fedora-44)/provision/10-base.sh" ]
  # anfs-dev's toolkit is a step for the anfs provisioner, not a key
  [ "$(img_steps core/anfs-dev)" = "$(img_dir core/anfs-dev)/provision/50-toolkit.anfs" ]
  ! grep -rn '^anfs:' "$BATS_TEST_DIRNAME/../../../machines/images"
  [ "$(img_test_script core/anfs-dev)" = "$(img_dir core/debian-13)/test.sh" ]
  # the ids are core's own entries, each pinned
  for i in debian-13 fedora-44; do for a in arm64 amd64; do
    [ "$(img_iso_id "core/$i" "$a")" = "$i-$a" ]
    [[ "$(iso_sha256 "$i-$a")" =~ ^[0-9a-f]{64}$ ]]
    [ "$(yq -r ".[] | select(.id == \"$i-$a\") | .architecture" "$BATS_TEST_DIRNAME/../../../isos/isos.yml")" = "$a" ]
  done; done
}

@test "an answer file with an unknown variable, and keys a from: image ignores" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  printf 'd-i x string ${NOT_A_VAR}\n' > "$PMM_IMAGES_HOME/d/preseed.cfg"
  image "$PMM_IMAGES_HOME/c" "from: e
distro: fedora"
  image "$PMM_IMAGES_HOME/e" "$(deb_yml)"
  v d c
  [[ "$output" == *"preseed.cfg:1: unknown variable \${NOT_A_VAR}"* ]]
  [[ "$output" == *"distro: is ignored on a from: image"* ]]
}

@test "a from: image's vars: and user: are its root's, and said; build: holds cpus, memory and disk" {
  image "$PMM_IMAGES_HOME/e" "$(deb_yml 'build: {cpus: 2, memory: 4096, disk: 30G}')"
  image "$PMM_IMAGES_HOME/c" "from: e
vars: {TIMEZONE: X}
user: {name: bob}
build: {memory: 4096}"
  image "$PMM_IMAGES_HOME/b" "$(deb_yml 'build: {mem: 1, cpus: lots, disk: big}')"
  image "$PMM_IMAGES_HOME/l" "$(deb_yml 'build: [2]')"
  v e c
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"local/e ok"* ]]
  [[ "$output" == *"vars: is ignored on a from: image"* ]]
  [[ "$output" == *"user: is ignored on a from: image"* ]]
  [[ "$output" == *"0 error(s), 2 warning(s)"* ]]
  v b l
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"build.mem is not a setting (cpus, memory, disk)"* ]]
  [[ "$output" == *"build.cpus 'lots' is not a number"* ]]
  [[ "$output" == *"build.disk 'big' is not a size"* ]]
  [[ "$output" == *"build: is a map"* ]]
}

@test "tart: base is required" {
  image "$PMM_IMAGES_HOME/m" "backend: tart
distro: macos"
  v m
  [ "$status" -ne 0 ]
  [[ "$output" == *"base: is required"* ]]
}
