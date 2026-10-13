#!/usr/bin/env bash
# pim library: what cli.sh asks for on a tab press (complete_<kind>): one candidate per line,
# quickly. They read file names only. Sourced by ~/.local/bin/pim; functions only.

# Every image: its name, and source/name
complete_image() {
  local f name
  for f in "$PIM_IMAGES_HOME"/*/image.yml "$ANFS_SOURCES_HOME"/*/images/*/image.yml; do
    [[ -f "$f" ]] || continue
    f="${f%/image.yml}"
    name="${f##*/}"
    printf '%s\n' "$name"
    [[ "$f" == "$PIM_IMAGES_HOME"/* ]] && continue
    f="${f%/images/*}"
    printf '%s/%s\n' "${f##*/}" "$name"
  done | awk '!seen[$0]++'
}
# What install takes: an image, or source/ for all of a source's
complete_image_spec() {
  local d
  complete_image
  for d in "$ANFS_SOURCES_HOME"/*/images; do
    [[ -d "$d" ]] || continue
    d="${d%/images}"
    printf '%s/\n' "${d##*/}"
  done
}
complete_arch() { printf '%s\n' arm64 amd64; }
