#!/usr/bin/env bash
# pmm library: what cli.sh asks for on a tab press (complete_<kind>): one candidate per line,
# quickly. They read file names only. Sourced by ~/.local/bin/pmm; functions only.

# Every machine: its name, and source/name; then the ones whose definition is gone
complete_machine() {
  local f name
  {
    for f in "$PMM_MACHINES_HOME"/*/machine.yml "$ANFS_SOURCES_HOME"/*/machines/*/machine.yml; do
      [[ -f "$f" ]] || continue
      f="${f%/machine.yml}"
      name="${f##*/}"
      printf '%s\n' "$name"
      [[ "$f" == "$PMM_MACHINES_HOME"/* ]] && continue
      f="${f%/machines/*}"
      printf '%s/%s\n' "${f##*/}" "$name"
    done
    for f in "$PMM_DATA_HOME"/machines/*/state.yml; do
      [[ -f "$f" ]] || continue
      f="${f%/state.yml}"
      printf '%s\n' "${f##*/}"
    done
  } | awk '!seen[$0]++'
}
# What install takes: a machine, or source/ for everything a source defines
complete_machine_spec() {
  local d
  complete_machine
  for d in "$ANFS_SOURCES_HOME"/*/machines; do
    [[ -d "$d" ]] || continue
    d="${d%/*}"
    printf '%s/\n' "${d##*/}"
  done | awk '!seen[$0]++'
}
# Every image: its name, and source/name
complete_image() {
  local f name
  for f in "$PMM_IMAGES_HOME"/*/image.yml "$ANFS_SOURCES_HOME"/*/machines/images/*/image.yml; do
    [[ -f "$f" ]] || continue
    f="${f%/image.yml}"
    name="${f##*/}"
    printf '%s\n' "$name"
    [[ "$f" == "$PMM_IMAGES_HOME"/* ]] && continue
    f="${f%/machines/images/*}"
    printf '%s/%s\n' "${f##*/}" "$name"
  done | awk '!seen[$0]++'
}
# The names at the top level of each profiles.yml
complete_profile() {
  local f line
  for f in "$PMM_MACHINES_HOME"/profiles.yml "$ANFS_SOURCES_HOME"/*/machines/profiles.yml; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      [[ "$line" =~ ^([A-Za-z0-9][A-Za-z0-9_.-]*): ]] && printf '%s\n' "${BASH_REMATCH[1]}"
    done < "$f"
  done | awk '!seen[$0]++'
}
complete_arch() { printf '%s\n' arm64 amd64; }
# Every network: its name, and source/name; then the installed ones whose definition is gone
complete_network() {
  local f name
  {
    for f in "$PMM_NETWORKS_HOME"/*/network.yml "$ANFS_SOURCES_HOME"/*/machines/networks/*/network.yml; do
      [[ -f "$f" ]] || continue
      f="${f%/network.yml}"
      name="${f##*/}"
      printf '%s\n' "$name"
      [[ "$f" == "$PMM_NETWORKS_HOME"/* ]] && continue
      f="${f%/machines/networks/*}"
      printf '%s/%s\n' "${f##*/}" "$name"
    done
    for f in "$PMM_DATA_HOME"/networks/*/state.yml; do
      [[ -f "$f" ]] || continue
      f="${f%/state.yml}"
      printf '%s\n' "${f##*/}"
    done
  } | awk '!seen[$0]++'
}
complete_network_spec() {
  local d
  complete_network
  for d in "$ANFS_SOURCES_HOME"/*/machines/networks; do
    [[ -d "$d" ]] || continue
    d="${d%/machines/networks}"
    printf '%s/\n' "${d##*/}"
  done
}
complete_kind() { printf '%s\n' nat isolated bridged; }
