#!/usr/bin/env bash
# pcm library: what cli.sh asks for on a tab press (complete_<kind>): one candidate per line,
# quickly. They read file names only. Sourced by ~/.local/bin/pcm; functions only.

# Every service: its name, and source/name
complete_service() {
  local d name
  for d in "$PCM_CONTAINERS_HOME"/*/ "$ANFS_SOURCES_HOME"/*/containers/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    name="${d##*/}"
    printf '%s\n' "$name"
    [[ "$d" == "$PCM_CONTAINERS_HOME"/* ]] && continue
    d="${d%/containers/*}"
    printf '%s/%s\n' "${d##*/}" "$name"
  done | awk '!seen[$0]++'
}
# What install takes: a service, or source/ for all of a source's
complete_service_spec() {
  local d
  complete_service
  for d in "$ANFS_SOURCES_HOME"/*/containers; do
    [[ -d "$d" ]] || continue
    d="${d%/containers}"
    printf '%s/\n' "${d##*/}"
  done
}
