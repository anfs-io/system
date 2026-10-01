# Shared setup for pcm's bats tests: pcm's libs sourced from this checkout, every PCM_* dir in
# the test temp dir, and podman stubbed out (tests never touch a real engine).

PCM_PKG="$BATS_TEST_DIRNAME/.."
ANFS_LIB="${ANFS_LIB:-$PCM_PKG/../anfs/home/.local/lib/anfs}"

pcm_setup() {
  T="$BATS_TEST_TMPDIR"
  export PCM_CONFIG_HOME="$T/config" PCM_CONTAINERS_HOME="$T/config/containers"
  export PCM_DATA_HOME="$T/data" PCM_VOLUMES_HOME="$T/data/volumes"
  export ANFS_CONFIG_HOME="$T/anfs/config" ANFS_DATA_HOME="$T/anfs/data" ANFS_CACHE_HOME="$T/anfs/cache"
  export PCM_CACHE_HOME="$T/cache" PCM_ENV_HOME="$T/config/env" PCM_STATE_HOME="$T/state"
  mkdir -p "$PCM_CONTAINERS_HOME"

  # shellcheck source=/dev/null
  source "$ANFS_LIB/paths.sh"
  # shellcheck source=/dev/null
  source "$ANFS_LIB/sources.sh"
  anfs_gitsrc_env
  # Local sources are read where they are, so tests need no `anfs src update` to link them
  GITSRC_LINK_LOCAL=true
  PCM_LOCAL_SOURCE=local
  RUNNER=(podman compose)

  local f
  for f in "$PCM_PKG"/home/.local/lib/pcm/*.sh; do
    # shellcheck source=/dev/null
    source "$f"
  done

  PRE=() PROVISIONED=() NAMED="" ORDER=() CLOSURE=() VALIDATE_ERRORS=0
}

# No container engine in tests: nothing runs, no image is pulled
podman() {
  case "$1" in
    ps) return 0 ;;
    *)  return 1 ;;
  esac
}

# A local-path source <alias> at $T/src/<alias>, listed in anfs's user.list (in call order)
add_source() {
  mkdir -p "$T/src/$1/containers" "$ANFS_CONFIG_HOME"
  echo "$T/src/$1  $1" >> "$ANFS_USER_LIST"
}

# A definition: define <dir> <name> [compose.yml content]
define() {
  local dir="$1/$2"
  mkdir -p "$dir"
  if [[ $# -ge 3 ]]; then
    printf '%s\n' "$3" > "$dir/compose.yml"
  else
    printf 'services:\n  app:\n    image: docker.io/library/alpine:3\n' > "$dir/compose.yml"
  fi
}
