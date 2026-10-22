#!/usr/bin/env bats
# lib/anfs/work.sh and paths.sh's library directories: ANFS_WORK=<job> runs the job's copy of an
# installed tool, with the job's libraries, against the live install. The install here is a temp
# HOME laid out as ppm leaves one (tools and lib/pcm linked into the sources, lib/ppm file by
# file, lib/anfs one link into core whose lib/anfs is the code under test) and a job ~/work/j with
# a copy of core only.
# Run: bats packages/anfs/tests/work.bats

unset ANFS_WORK ANFS_WORK_SAID ANFS_WORK_HOME

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/../home/.local/lib/anfs" && pwd -P)"
  NEW="$BASH"
  mkdir -p "$BATS_TEST_TMPDIR/home"
  export HOME=$(cd -P "$BATS_TEST_TMPDIR/home" && pwd -P)
  export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
  unset ANFS_CONFIG_HOME ANFS_DATA_HOME ANFS_STATE_HOME ANFS_CACHE_HOME ANFS_BASH_CANDIDATES
  SRC="$HOME/.local/share/anfs/sources"
  JOB="$HOME/work/j"

  # core: lib/anfs (the code under test), two tools, lib/pcm, two lib/ppm files
  mkdir -p "$SRC/core/packages/anfs/home/.local/lib" "$SRC/core/packages/pcm/home/.local/lib/pcm" \
    "$SRC/core/packages/ppm/home/.local/lib/ppm" "$SRC/anfs-dev/packages/dev/home/.local/lib/ppm"
  ln -s "$LIB" "$SRC/core/packages/anfs/home/.local/lib/anfs"
  tool "$SRC/core/packages/pcm/home/.local/bin/pcm"
  tool "$SRC/core/packages/psm/home/.local/bin/psm"
  tool "$SRC/stack/packages/ventoy/home/.local/bin/ventoy"
  echo installed > "$SRC/core/packages/pcm/home/.local/lib/pcm/x.sh"
  echo installed > "$SRC/core/packages/ppm/home/.local/lib/ppm/core.sh"
  echo installed > "$SRC/core/packages/ppm/home/.local/lib/ppm/sources.sh"
  echo installed > "$SRC/anfs-dev/packages/dev/home/.local/lib/ppm/container.sh"

  # linked as ppm links them: relative, from ~/.local/bin and ~/.local/lib
  mkdir -p "$HOME/.local/bin" "$HOME/.local/lib/ppm"
  for t in core/pcm/pcm core/psm/psm stack/ventoy/ventoy; do
    ln -s "../../.local/share/anfs/sources/${t%%/*}/packages/$(cut -d/ -f2 <<< "$t")/home/.local/bin/${t##*/}" "$HOME/.local/bin/${t##*/}"
  done
  ln -s ../share/anfs/sources/core/packages/anfs/home/.local/lib/anfs "$HOME/.local/lib/anfs"
  ln -s ../../.local/share/anfs/sources/core/packages/pcm/home/.local/lib/pcm "$HOME/.local/lib/pcm"
  ln -s ../../../.local/share/anfs/sources/core/packages/ppm/home/.local/lib/ppm/core.sh "$HOME/.local/lib/ppm/core.sh"
  ln -s ../../../.local/share/anfs/sources/core/packages/ppm/home/.local/lib/ppm/sources.sh "$HOME/.local/lib/ppm/sources.sh"
  ln -s ../../../.local/share/anfs/sources/anfs-dev/packages/dev/home/.local/lib/ppm/container.sh "$HOME/.local/lib/ppm/container.sh"

  # the job: a copy of core (lib/anfs a real copy of the code under test), no stack, no anfs-dev
  mkdir -p "$JOB"
  echo 'branch: j' > "$JOB/.job.yml"
  cp -R "$SRC/core" "$JOB/core"
  rm "$JOB/core/packages/anfs/home/.local/lib/anfs"
  cp -R "$LIB" "$JOB/core/packages/anfs/home/.local/lib/anfs"
  echo job > "$JOB/core/packages/pcm/home/.local/lib/pcm/x.sh"
  echo job > "$JOB/core/packages/ppm/home/.local/lib/ppm/core.sh"
  echo job > "$JOB/core/packages/ppm/home/.local/lib/ppm/new.sh"
  rm "$JOB/core/packages/ppm/home/.local/lib/ppm/sources.sh"
}

# tool <path>: a fake tool with the preamble; prints its own path, its arguments and lib/anfs,
# then runs the installed tool $NEXT
tool() {
  mkdir -p "${1%/*}"
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# A job's copy of this tool runs instead when ANFS_WORK names one (lib/anfs/work.sh)
[ -z "${ANFS_WORK:-}" ] || [ ! -f "$HOME/.local/lib/anfs/work.sh" ] || . "$HOME/.local/lib/anfs/work.sh"
source "$HOME/.local/lib/anfs/bash.sh"
source "$HOME/.local/lib/anfs/paths.sh"
printf 'ran %s' "$0"; [ $# -eq 0 ] || printf ' <%s>' "$@"; printf ' lib=%s\n' "$ANFS_LIB_DIR"
[ -z "${NEXT:-}" ] || NEXT= "$HOME/.local/bin/$NEXT"
SH
  chmod +x "$1"
}

said() { grep -c '^anfs: running job j$' <<< "$output" || true; }

@test "ANFS_WORK unset: the installed copy runs, nothing said" {
  run "$HOME/.local/bin/pcm" a
  [ "$status" -eq 0 ]
  [ "$output" = "ran $HOME/.local/bin/pcm <a> lib=$HOME/.local/lib/anfs" ]
}

@test "ANFS_WORK=j: the job's copy runs with its arguments intact and the job's lib/anfs; said once" {
  ANFS_WORK=j run "$HOME/.local/bin/pcm" "two words" "" -x
  [ "$status" -eq 0 ]
  [ "$(said)" -eq 1 ]
  [ "${lines[0]}" = "anfs: running job j" ]
  [ "${lines[1]}" = "ran $JOB/core/packages/pcm/home/.local/bin/pcm <two words> <> <-x> lib=$JOB/core/packages/anfs/home/.local/lib/anfs" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "a tool whose source the job lacks runs as installed, with the job's lib/anfs; said once" {
  ANFS_WORK=j run "$HOME/.local/bin/ventoy"
  [ "$status" -eq 0 ]
  [ "$(said)" -eq 1 ]
  [ "${lines[1]}" = "ran $HOME/.local/bin/ventoy lib=$JOB/core/packages/anfs/home/.local/lib/anfs" ]
}

@test "the job without core: lib/anfs is the installed one" {
  rm -rf "$JOB/core"
  mkdir -p "$JOB/stack"
  cp -R "$SRC/stack/packages" "$JOB/stack/packages"
  ANFS_WORK=j run "$HOME/.local/bin/ventoy"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "ran $JOB/stack/packages/ventoy/home/.local/bin/ventoy lib=$HOME/.local/lib/anfs" ]
}

@test "the job's copy run by path does not hand over (no loop), and says nothing" {
  ANFS_WORK=j run "$JOB/core/packages/pcm/home/.local/bin/pcm" a
  [ "$status" -eq 0 ]
  [ "$(said)" -eq 0 ]
  [ "$output" = "ran $JOB/core/packages/pcm/home/.local/bin/pcm <a> lib=$JOB/core/packages/anfs/home/.local/lib/anfs" ]
  # a checkout run by path does not either
  ANFS_WORK=j run "$SRC/core/packages/pcm/home/.local/bin/pcm"
  [[ "$output" == "ran $SRC/core/packages/pcm/home/.local/bin/pcm "* ]]
}

@test "a job that does not exist, or a name that is a path: 64, and nothing runs" {
  ANFS_WORK=nosuch run "$HOME/.local/bin/pcm"
  [ "$status" -eq 64 ]
  [ "$output" = "anfs: no job nosuch in ~/work (anfs work list)" ]
  ANFS_WORK=../x run "$HOME/.local/bin/pcm"
  [ "$status" -eq 64 ]
  [ "$output" = "anfs: no job ../x in ~/work (anfs work list)" ]
  ANFS_WORK=.hidden run "$HOME/.local/bin/pcm"
  [ "$status" -eq 64 ]
  # ANFS_WORK_HOME moves the jobs (a leading ~/ is $HOME)
  mv "$HOME/work" "$HOME/jobs"
  local tilde='~'
  ANFS_WORK=j ANFS_WORK_HOME="$tilde/jobs" run "$HOME/.local/bin/pcm"
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == "ran $HOME/jobs/j/core/packages/pcm/home/.local/bin/pcm "* ]]
}

@test "nested: the job's tool runs another installed one, which hands over too, unsaid" {
  ANFS_WORK=j NEXT=psm run "$HOME/.local/bin/pcm"
  [ "$status" -eq 0 ]
  [ "$(said)" -eq 1 ]
  [[ "${lines[1]}" == "ran $JOB/core/packages/pcm/"* ]]
  [[ "${lines[2]}" == "ran $JOB/core/packages/psm/"* ]]
  [ "${#lines[@]}" -eq 3 ]
  # a new run from the shell says it again; one for another job too
  ANFS_WORK=j ANFS_WORK_SAID=j run "$HOME/.local/bin/pcm"
  [ "$(said)" -eq 0 ]
  ANFS_WORK=j ANFS_WORK_SAID=other run "$HOME/.local/bin/pcm"
  [ "$(said)" -eq 1 ]
}

@test "the installed tool reached through a canonical HOME hands over too" {
  mkdir -p "$BATS_TEST_TMPDIR/alias"
  ln -s "$HOME" "$BATS_TEST_TMPDIR/alias/home"
  HOME="$BATS_TEST_TMPDIR/alias/home" ANFS_WORK=j run "$HOME/.local/bin/pcm"
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == "ran $BATS_TEST_TMPDIR/alias/home/work/j/core/packages/pcm/"* ]]
}

# paths.sh under ANFS_WORK, sourced as a tool does (by its installed path)
in_paths() {
  run "$NEW" -c 'set -euo pipefail; source "$HOME/.local/lib/anfs/paths.sh"; eval "$1"' _ "$1"
}

@test "paths.sh: ANFS_LIB_DIR and anfs_lib_dir are the job's under ANFS_WORK, the installed ones without" {
  in_paths 'echo "$ANFS_LIB_DIR"; anfs_lib_dir pcm; anfs_lib_dir tsm'
  [ "${lines[0]}" = "$HOME/.local/lib/anfs" ]
  [ "${lines[1]}" = "$HOME/.local/lib/pcm" ]
  [ "${lines[2]}" = "$HOME/.local/lib/tsm" ]
  ANFS_WORK=j in_paths 'echo "$ANFS_LIB_DIR"; anfs_lib_dir pcm; anfs_lib_dir tsm; echo "$ANFS_LIB_ROOT"'
  [ "${lines[0]}" = "$JOB/core/packages/anfs/home/.local/lib/anfs" ]
  [ "${lines[1]}" = "$JOB/core/packages/pcm/home/.local/lib/pcm" ]
  [ "${lines[2]}" = "$HOME/.local/lib/tsm" ]
  [ "${lines[3]}" = "$HOME/.local/lib" ]
  # a job without core: the installed ones
  mv "$JOB/core" "$JOB/other"
  ANFS_WORK=j in_paths 'echo "$ANFS_LIB_DIR"; anfs_lib_dir pcm'
  [ "${lines[0]}" = "$HOME/.local/lib/anfs" ]
  [ "${lines[1]}" = "$HOME/.local/lib/pcm" ]
}

@test "paths.sh: the job's paths.sh is the one that ran (its own variables)" {
  echo 'ANFS_FROM_JOB=yes' >> "$JOB/core/packages/anfs/home/.local/lib/anfs/paths.sh"
  ANFS_WORK=j in_paths 'echo "${ANFS_FROM_JOB:-no}"'
  [ "$output" = yes ]
  in_paths 'echo "${ANFS_FROM_JOB:-no}"'
  [ "$output" = no ]
}

@test "anfs_lib_files ppm: the job's copy, an installed file of a source the job lacks, a file only in the job" {
  in_paths 'anfs_lib_files ppm'
  [ "$output" = "$HOME/.local/lib/ppm/container.sh
$HOME/.local/lib/ppm/core.sh
$HOME/.local/lib/ppm/sources.sh" ]
  ANFS_WORK=j in_paths 'anfs_lib_files ppm'
  [ "$output" = "$HOME/.local/lib/ppm/container.sh
$JOB/core/packages/ppm/home/.local/lib/ppm/core.sh
$JOB/core/packages/ppm/home/.local/lib/ppm/new.sh
$HOME/.local/lib/ppm/sources.sh" ]
}

@test "work.sh and the preamble run under the older bash and hand over before bash.sh" {
  [[ -x /bin/bash ]] || skip "no /bin/bash"
  /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 5 ]' || skip "/bin/bash meets the floor"
  # bash.sh would stop this run (no newer bash to re-exec under) if it came first; the job's
  # copy starts under the bash on PATH
  ANFS_BASH_CANDIDATES=/nonexistent PATH="${NEW%/*}:/usr/bin:/bin" ANFS_WORK=j run /bin/bash "$HOME/.local/bin/pcm" a
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "anfs: running job j" ]
  [[ "${lines[1]}" == "ran $JOB/core/packages/pcm/home/.local/bin/pcm <a> "* ]]
  ANFS_BASH_CANDIDATES=/nonexistent ANFS_WORK=nosuch run /bin/bash "$HOME/.local/bin/pcm"
  [ "$status" -eq 64 ]
}

# --- every entry script ---------------------------------------------------------------------------

PREAMBLE='[ -z "${ANFS_WORK:-}" ] || [ ! -f "$HOME/.local/lib/anfs/work.sh" ] || . "$HOME/.local/lib/anfs/work.sh"'

# The preamble is the two lines right after the script's first `set -euo pipefail`
has_preamble() {
  local after
  after=$(grep -n -m1 '^set -euo pipefail$' "$1" | cut -d: -f1)
  [[ -n "$after" ]] || { echo "$1: no set -euo pipefail"; return 1; }
  [[ "$(sed -n "$((after + 1))p" "$1")" == "# A job's copy of this tool runs instead when ANFS_WORK names one (lib/anfs/work.sh)" &&
     "$(sed -n "$((after + 2))p" "$1")" == "$PREAMBLE" ]] || { echo "$1: no preamble after set -euo pipefail"; return 1; }
}

@test "every core entry script has the preamble, and names ~/.local/lib only to start" {
  local repo f line n=0
  repo="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  for f in "$repo"/packages/{anfs,ppm,pcm,pmm,psm,wsm}/home/.local/bin/* "$repo"/packages/*/home/.local/bin/anfs-*; do
    [[ -f "$f" ]] || continue
    n=$((n + 1))
    has_preamble "$f"
    ! grep -n 'ANFS_LIB=' "$f" || { echo "$f assigns ANFS_LIB"; return 1; }
    # the preamble, the check that lib/anfs is there, and the two entry points by literal path
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ "$line" == "$PREAMBLE" ]] && continue
      [[ "$line" == 'if [[ ! -f "$HOME/.local/lib/anfs/paths.sh" ]]; then' ]] && continue
      [[ "$line" =~ ^(if\ \[\[\ -f\ \"\$HOME/\.local/lib/anfs/bash\.sh\"\ \]\]\;\ then\ )?source\ \"\$HOME/\.local/lib/anfs/(bash|paths)\.sh\"(\;\ fi)?$ ]] && continue
      echo "$f: $line"; return 1
    done < <(grep -F '$HOME/.local/lib/' "$f")
  done
  (( n >= 6 ))
}

@test "stack's, anfs-dev's and user's pjm entry scripts have the preamble (each repo beside core, when there)" {
  local root f n=0
  root="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd)"
  for f in stack/packages/{op/home/.local/bin/opm,remotefs/home/.local/bin/remotefs,ssh/home/.local/bin/ssh-key} \
           stack/packages/{tailscale/home/.local/bin/tsm,pikvm/home/.local/bin/pikvm,ventoy/home/.local/bin/ventoy} \
           stack/packages/{obsidian/home/.local/bin/ovm,ruby/home/.local/bin/gem-local,git/home/.local/bin/git-account} \
           stack/packages/{rpi-imager/home/.local/bin/rpi-imager,firstmate/home/.local/bin/firstmate} \
           anfs-dev/packages/dev/home/.local/bin/{anfs-work,anfs-hooks} user/packages/pjm/home/.local/bin/pjm; do
    [[ -f "$root/$f" ]] || continue
    n=$((n + 1))
    has_preamble "$root/$f"
  done
  (( n > 0 )) || skip "no stack, anfs-dev or user beside core"
}
