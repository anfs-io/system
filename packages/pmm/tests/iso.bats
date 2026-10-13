#!/usr/bin/env bats
# The ISOs core's images install from are in core's catalogue (isos/isos.yml) under
# <image>-<arch>, so `pmm iso pull` can fetch them ahead of a build and `pmm iso prune` keeps
# them. Until an image names its ISO by id the two files repeat each other; this holds them
# together. Reads the repo's files only.
# Run: bats packages/pmm/tests/

@test "core's catalogue has every image's ISO: the same urls, the same sha256" {
  local root="$BATS_TEST_DIRNAME/../../.." def image arch n=0
  local catalog="$root/isos/isos.yml"
  for def in "$root"/machines/images/*/image.yml; do
    image=$(basename "$(dirname "$def")")
    while IFS= read -r arch; do
      [[ -n "$arch" ]] || continue
      n=$((n + 1))
      echo "$image-$arch"
      [ "$(ID="$image-$arch" yq -r '.[] | select(.id == strenv(ID)) | [.url] | flatten | .[]' "$catalog")" = \
        "$(A="$arch" yq -r '[.iso[strenv(A)].url] | flatten | .[]' "$def")" ]
      [ "$(ID="$image-$arch" yq -r '.[] | select(.id == strenv(ID)) | .checksum' "$catalog")" = \
        "sha256:$(A="$arch" yq -r '.iso[strenv(A)].sha256' "$def")" ]
      [ "$(ID="$image-$arch" yq -r '.[] | select(.id == strenv(ID)) | .architecture' "$catalog")" = "$arch" ]
    done < <(yq -r '.iso // {} | keys | .[]' "$def")
  done
  [ "$n" -ge 4 ]
}
