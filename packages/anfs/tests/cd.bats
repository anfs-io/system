#!/usr/bin/env bats
# Every tool's `cd` shell function goes through _anfs_cd (sh/anfs.sh). Sources the portable sh
# files, with stub tools first on a temp PATH, in bash and (when present) zsh, and checks for each
# tool: exit 0 cds, exit 3 (stale, path still printed) cds, any other exit is returned without
# moving, and no argument goes to the tool's default.
# Run: bats packages/anfs/tests/cd.bats

setup() {
  PKGS="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/home/.local/bin" "$T/target" "$T/stale" "$T/cfg/pcm/containers" \
           "$T/cfg/pmm/machines/images" "$T/data/anfs/sources" "$T/psmcfg" "$T/wsroot"
  # A stub prints a path for `[sub] path ARG`: ok -> target (exit 0), stale -> stale (exit 3),
  # anything else -> exit 4, nothing printed. No ARG: the tool's own no-argument answer.
  for tool in ppm pcm pmm psm wsm anfs; do
    cat > "$T/bin/$tool" <<STUB
#!/bin/sh
[ "\$1" = path ] || { [ "\$2" = path ] && shift; } || { echo "$tool: \$*"; exit 0; }
shift
case "\${1:-}" in
  "") [ "$tool" = psm ] && { echo "$T/psmcfg"; exit 0; }; [ "$tool" = wsm ] && { echo "$T/wsroot"; exit 0; }; exit 2 ;;
  ok) echo "$T/target" ;;
  stale) echo "$T/stale"; echo "$tool: stale" >&2; exit 3 ;;
  *) echo "$tool: no \$1" >&2; exit 4 ;;
esac
STUB
    chmod +x "$T/bin/$tool"
  done
  # anfs <name> cd needs ~/.local/bin/anfs-<name>
  ln -s "$T/bin/anfs" "$T/home/.local/bin/anfs-work"
  # anfs.sh last: the wrappers look _anfs_cd up at call time
  SCRIPT="$T/probe"
  cat > "$SCRIPT" <<PROBE
PATH="$T/bin:/usr/bin:/bin"; HOME="$T/home"; XDG_CONFIG_HOME="$T/cfg"; XDG_DATA_HOME="$T/data"
unset PCM_CONTAINERS_HOME PMM_CONFIG_HOME CDPATH
for f in "$PKGS"/ppm/home/.config/sh/ppm.sh "$PKGS"/pcm/home/.config/sh/pcm.sh \
         "$PKGS"/pmm/home/.config/sh/pmm.sh "$PKGS"/psm/home/.config/sh/psm.sh \
         "$PKGS"/wsm/home/.config/sh/wsm.sh "$PKGS"/anfs/home/.config/sh/anfs.sh; do
  . "\$f"
done
try() { cd "$T/home"; "\$@"; rc=\$?; echo "\$rc \$(pwd)"; }
try ppm cd ok;   try ppm cd stale;   try ppm cd nope;   try ppm cd
try pcm cd ok;   try pcm cd stale;   try pcm cd nope;   try pcm cd
try pmm cd ok;   try pmm cd stale;   try pmm cd nope;   try pmm cd
try pmm image cd ok; try pmm image cd stale; try pmm image cd nope; try pmm image cd
try wsm cd ok;   try wsm cd stale;   try wsm cd nope;   try wsm cd
try anfs work cd ok; try anfs work cd stale; try anfs work cd nope
try psm cd
try anfs package cd ok; try anfs space cd
PROBE
}

expected() {
  local h="$T/home" tool
  for tool in ppm pcm pmm "pmm image" wsm; do
    echo "0 $T/target"; echo "0 $T/stale"; echo "4 $h"
    case "$tool" in
      ppm) echo "0 $T/data/anfs/sources" ;;
      pcm) echo "0 $T/cfg/pcm/containers" ;;
      pmm) echo "0 $T/cfg/pmm/machines" ;;
      "pmm image") echo "0 $T/cfg/pmm/machines/images" ;;
      wsm) echo "0 $T/wsroot" ;;
    esac
  done
  echo "0 $T/target"; echo "0 $T/stale"; echo "4 $h"
  echo "0 $T/psmcfg"
  echo "0 $T/target"; echo "0 $T/wsroot"
}

@test "bash: every tool's cd goes through _anfs_cd" {
  run bash --norc --noprofile "$SCRIPT"
  [ "$status" -eq 0 ]
  diff <(expected) <(printf '%s\n' "$output" | grep -Ev ': (stale|no nope)$')
}

@test "zsh: the same" {
  command -v zsh >/dev/null || skip "no zsh"
  run zsh -f "$SCRIPT"
  [ "$status" -eq 0 ]
  diff <(expected) <(printf '%s\n' "$output" | grep -Ev ': (stale|no nope)$')
}
