#!/usr/bin/env bats
# lib/anfs/bash.sh: the bash floor. An entry point started under an older bash re-execs under one
# that meets the floor, or stops with exit 69. Also checks that the bootstrap set (what runs on a
# vanilla Mac before Homebrew's bash exists) still parses under that older bash.
# Run: bats packages/anfs/tests/
#
# The re-exec cases need a bash below the floor, which is macOS's /bin/bash; elsewhere they skip.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIB="$BATS_TEST_DIRNAME/../home/.local/lib/anfs"
  OLD=/bin/bash
  NEW="$BASH"
  SCRIPT="$BATS_TEST_TMPDIR/probe"
  cat > "$SCRIPT" <<PROBE
#!/bin/bash
source "$LIB/bash.sh"
declare -A floor=([met]=yes)
printf 'bash=%s marker=%s args=' "\${BASH_VERSINFO[0]}.\${BASH_VERSINFO[1]}" "\${ANFS_BASH_REEXEC:-unset}"
printf '<%s>' "\$@"
echo
PROBE
  chmod +x "$SCRIPT"
}

# Skip unless $OLD is a bash below the floor
need_old_bash() {
  [[ -x "$OLD" ]] || skip "no $OLD"
  "$OLD" -c '[ "${BASH_VERSINFO[0]}" -lt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }' ||
    skip "$OLD meets the floor"
}

@test "floor met: the script runs where it started, and the marker is cleared for children" {
  ANFS_BASH_REEXEC=/stale run "$NEW" "$SCRIPT" a
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker=unset args=<a>"* ]]
}

@test "older bash: re-execs under one that meets the floor, arguments intact" {
  need_old_bash
  ANFS_BASH_CANDIDATES="/nonexistent/bash:$NEW" run "$OLD" "$SCRIPT" one "two words" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker=unset args=<one><two words><>"* ]]
  [[ "$output" != bash=3.* ]]
}

@test "older bash: a candidate below the floor is passed over" {
  need_old_bash
  ANFS_BASH_CANDIDATES="$OLD:$NEW" run "$OLD" "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != bash=3.* ]]
}

@test "older bash, nothing newer: exit 69 and how to get one" {
  need_old_bash
  ANFS_BASH_CANDIDATES="$OLD" run "$OLD" "$SCRIPT"
  [ "$status" -eq 69 ]
  [[ "$output" == *"probe: needs bash 5.2 or newer"* ]]
  [[ "$output" == *"install"* ]]
}

@test "older bash after a re-exec: stops instead of looping" {
  need_old_bash
  ANFS_BASH_REEXEC="$NEW" ANFS_BASH_CANDIDATES="$NEW" run "$OLD" "$SCRIPT"
  [ "$status" -eq 69 ]
  [[ "$output" == *"still runs bash"* ]]
}

@test "a tool started under the older bash runs" {
  need_old_bash
  mkdir -p "$BATS_TEST_TMPDIR/home/.local/lib"
  ln -s "$LIB" "$BATS_TEST_TMPDIR/home/.local/lib/anfs"
  HOME="$BATS_TEST_TMPDIR/home" ANFS_BASH_CANDIDATES="$NEW" run "$OLD" "$REPO/packages/wsm/home/.local/bin/wsm" --version
  [ "$status" -eq 0 ]
  [[ "$output" == wsm\ * ]]
}

@test "every entry point sources the floor before anything else of lib/anfs" {
  local f first n=0
  # core's own: the tools, anything a package of core runs as anfs <name> (anfs-*), pcm's edge
  # providers, pmm's provisioners. The dev package's (the hook, anfs-work, anfs-hooks) are checked
  # the same way in the anfs-dev source's tests.
  for f in "$REPO"/packages/{anfs,ppm,pcm,pmm,psm,wsm,pvm}/home/.local/bin/* \
           "$REPO"/packages/*/home/.local/bin/anfs-* \
           "$REPO"/packages/pcm/home/.local/lib/pcm/edges/{local,cloudflare-tunnel} \
           "$REPO"/packages/pmm/home/.local/lib/pmm/provisioners/*; do
    [[ -e "$f" ]] || continue
    n=$((n + 1))
    first=$(grep -n 'lib/anfs/\|\$ANFS_LIB/' "$f" | grep 'source ' | head -1)
    [[ "$first" == *bash.sh* ]] || { echo "$f: first lib/anfs source is: $first"; return 1; }
  done
  # the seven tools at least
  (( n >= 7 ))
}

@test "the bootstrap set parses under the older bash" {
  need_old_bash
  local f
  for f in install.sh packages/anfs/home/.local/lib/anfs/bash.sh \
           packages/ppm/home/.local/lib/ppm/{core,platform,file,installer}.sh; do
    "$OLD" -n "$REPO/$f" || { echo "$f does not parse under $("$OLD" -c 'echo $BASH_VERSION')"; return 1; }
  done
}

@test "the bootstrap set is what install.sh sources" {
  # If install.sh starts sourcing another library, it joins the set (and the test above)
  run grep -E '^PPM_BOOTSTRAP_LIBS=' "$REPO/install.sh"
  [ "$output" = 'PPM_BOOTSTRAP_LIBS="core.sh platform.sh file.sh installer.sh"' ]
}
