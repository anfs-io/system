#!/usr/bin/env bash
# ppm library: what cli.sh asks for on a tab press (complete_<kind>): one candidate per line,
# quickly. They read file names only. Sourced by ~/.local/bin/ppm; functions only.

# Every package the sources hold: its name, and repo/name
complete_package() {
  local d name
  for d in "$ANFS_SOURCES_HOME"/*/packages/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    name="${d##*/}"
    d="${d%/packages/*}"
    printf '%s\n%s/%s\n' "$name" "${d##*/}" "$name"
  done | awk '!seen[$0]++'
}
# What install takes: a package, or repo/ for all of a source's
complete_package_spec() {
  local d
  complete_package
  for d in "$ANFS_SOURCES_HOME"/*/packages; do
    [[ -d "$d" ]] || continue
    d="${d%/packages}"
    printf '%s/\n' "${d##*/}"
  done
}
# What is installed: repo/name, and the name
complete_installed() {
  local f
  for f in "$PPM_INSTALLED_DIR"/*/*.yml; do
    [[ -f "$f" ]] || continue
    f="${f#"$PPM_INSTALLED_DIR"/}"
    f="${f%.yml}"
    printf '%s\n%s\n' "$f" "${f##*/}"
  done | awk '!seen[$0]++'
}
complete_source() {
  local d
  for d in "$ANFS_SOURCES_HOME"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    printf '%s\n' "${d##*/}"
  done
}
complete_repo() { complete_source; }
