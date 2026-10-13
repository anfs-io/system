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

@test "missing iso for a declared arch, a bad sha256, an unknown backend and arch" {
  image "$PMM_IMAGES_HOME/a" "distro: debian
arch: [arm64, amd64]
iso: {arm64: {url: https://x/a.iso, sha256: nothex}}"
  image "$PMM_IMAGES_HOME/b" "backend: vbox"
  image "$PMM_IMAGES_HOME/c" "distro: debian
arch: [riscv]"
  v a b c
  [ "$status" -ne 0 ]
  [[ "$output" == *"iso.arm64.sha256 is missing or not a sha256"* ]]
  [[ "$output" == *"iso.amd64.url is missing"* ]]
  [[ "$output" == *"backend 'vbox'"* ]]
  [[ "$output" == *"arch 'riscv'"* ]]
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

@test "tart: base is required" {
  image "$PMM_IMAGES_HOME/m" "backend: tart
distro: macos"
  v m
  [ "$status" -ne 0 ]
  [[ "$output" == *"base: is required"* ]]
}
