#!/usr/bin/env bats
# The toolkit as a stack (units/stacks/02-system): the core/system manifest, install.sh's last step
# and `anfs implode` as `anfs remove system`. The real anfs in a temp $HOME; ppm, psm, wsm and pcm
# are stubs that log their argv (pmm is not installed, as on a default install).
# Run: bats packages/anfs/tests/system.bats

bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  local tools="$BATS_TEST_TMPDIR/tools" t
  ANFS="$REPO/packages/anfs/home/.local/bin/anfs"
  export HOME="$BATS_TEST_TMPDIR/home"
  ST="$HOME/stub"
  SOURCES="$HOME/.local/share/anfs/sources"
  RECORDS="$HOME/.local/state/anfs/stacks"
  LOG="$ST/log"
  mkdir -p "$HOME/.local/lib" "$HOME/.local/bin" "$HOME/.config/anfs" "$ST" "$tools" "$SOURCES"
  ln -s "$REPO/packages/anfs/home/.local/lib/anfs" "$HOME/.local/lib/anfs"
  for t in bash yq; do ln -s "$(command -v "$t")" "$tools/$t"; done
  # implode unloads the toolkit API's listener: never the real launchctl or systemctl
  for t in launchctl systemctl; do printf '#!/bin/sh\necho "%s $*" >> "%s/svc.calls"\n' "$t" "$BATS_TEST_TMPDIR" > "$tools/$t"; chmod +x "$tools/$t"; done
  export PATH="$tools:/usr/bin:/bin:/usr/sbin:/sbin"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME ANFS_JSON
  unset PPM_STATE_HOME PCM_STATE_HOME PMM_STATE_HOME PSM_STATE_HOME WSM_STATE_HOME ANFS_STATE_HOME
  export ANFS_LOG=off ANFS_TABLE=tsv GIT_CONFIG_NOSYSTEM=1 ST LOG
  : > "$LOG"

  printf '# Your anfs sources\n' > "$HOME/.config/anfs/user.list"
  printf '%s  lgat\n%s  core\n' "$SOURCES/lgat" "$SOURCES/core" > "$HOME/.config/anfs/system.list"
  mkdir -p "$SOURCES/lgat/packages" "$SOURCES/core/packages" "$SOURCES/core/stacks/system"
  # the real manifest
  cp "$REPO/stacks/system/stack.yml" "$SOURCES/core/stacks/system/stack.yml"
  stack lgat app <<<'packages: [stack/ruby]
containers: [core/db]'
  stack lgat web <<<'packages: [stack/nginx]'

  for t in ppm psm wsm pcm; do stub "$t"; done
}

stack() {
  mkdir -p "$SOURCES/$1/stacks/$2"
  cat > "$SOURCES/$1/stacks/$2/stack.yml"
}

# A tool stub: logs "<tool> <argv>"; install and remove keep $ST/<tool>.have, list --json prints it
stub() {
  cat > "$HOME/.local/bin/$1" <<'SH'
#!/bin/bash
t="${0##*/}" have="$ST/${0##*/}.have"
touch "$have"
case "$*" in *--json*) ;; *) echo "$t $*" >> "$LOG" ;; esac
cmd="$1"; shift
case "$cmd" in
  install)
    for a in "$@"; do
      case "$a" in -*) continue ;; esac
      grep -qx "$a" "$have" || echo "$a" >> "$have"
    done ;;
  remove)
    for a in "$@"; do
      case "$a" in -*) continue ;; esac
      grep -vx "$a" "$have" > "$have.n" || true; mv "$have.n" "$have"
    done ;;
  list)
    sep="" ; printf '['
    while read -r n; do
      case "$t" in
        ppm) printf '%s{"package":"%s","status":"installed","version":"0.1.0"}' "$sep" "$n" ;;
        pcm) printf '%s{"container":"%s","status":"running"}' "$sep" "$n" ;;
        *)   printf '%s{"skill":"%s","status":"ok"}' "$sep" "$n" ;;
      esac
      sep=,
    done < "$have"
    echo ']' ;;
esac
exit 0
SH
  chmod +x "$HOME/.local/bin/$1"
}

# The line number of the first log line matching <pattern>
at() { grep -n -m1 -- "$1" "$LOG" | cut -d: -f1; }

@test "the system manifest validates: the toolkit, its dashboard and nothing else" {
  run "$ANFS" show core/system
  [ "$status" -eq 0 ]
  for p in anfs ppm pcm psm wsm podman node varlock; do [[ "$output" == *"core/$p"* ]]; done
  [[ "$output" == *core/ui* ]]
  [ "$(yq -r '.containers[0]["core/ui"].status' "$REPO/stacks/system/stack.yml")" = running ]
  [[ "$output" != *pmm* && "$output" != *qemu* ]]
}

@test "core/anfs depends on ppm and nothing else" {
  run yq -r '.depends | join(" ")' "$REPO/packages/anfs/package.yml"
  [ "$output" = ppm ]
}

@test "install.sh: the last step is anfs install system, then the extra packages" {
  local fn="$BATS_TEST_TMPDIR/fn.sh"
  sed -n '/^install_packages() {/,/^}/p' "$REPO/install.sh" > "$fn"
  anfs() { echo "anfs $*" >> "$LOG"; }
  ppm() { echo "ppm $*" >> "$LOG"; }
  source "$fn"
  install_packages stack/ruby stack/git
  run cat "$LOG"
  [ "${lines[0]}" = "anfs install system -y" ]
  [ "${lines[1]}" = "ppm install stack/ruby" ]
  [ "${lines[2]}" = "ppm install stack/git" ]
  [ "${#lines[@]}" -eq 3 ]
  # and main ends with it: nothing installs after install_packages
  run bash -c "sed -n '/^main() {/,/^}/p' '$REPO/install.sh' | grep -E '^  [a-z_]+( |$)' | grep -v '^  echo\|^  local\|^  if\|^  fi' | tail -n 1"
  [[ "$output" == *install_packages* ]]
  ! grep -q 'ppm install core/anfs' "$REPO/install.sh"
}

@test "implode: the other stacks first (last installed first), then the tools, system, ppm" {
  run "$ANFS" install -y system </dev/null
  [ "$status" -eq 0 ]
  grep -qx "pcm install -y core/ui" "$LOG"   # the dashboard, then its status: running
  grep -qx "pcm up core/ui" "$LOG"
  "$ANFS" install -y lgat/app </dev/null
  "$ANFS" install -y lgat/web </dev/null
  yq -i '.installed_at = "2026-01-01T00:00:00Z"' "$RECORDS/core/system.yml"
  yq -i '.installed_at = "2026-01-02T00:00:00Z"' "$RECORDS/lgat/app.yml"
  yq -i '.installed_at = "2026-01-03T00:00:00Z"' "$RECORDS/lgat/web.yml"
  : > "$LOG"
  run "$ANFS" implode -y </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"anfs remove lgat/web lgat/app (the other installed stacks"* ]]
  [[ "$output" == *"anfs remove core/system (the toolkit's packages), then ppm implode"* ]]
  local web app wsm pcm sys ppm
  web=$(at "ppm remove -y stack/nginx")
  app=$(at "ppm remove -y stack/ruby")
  wsm=$(at "wsm implode -y")
  pcm=$(at "pcm implode -y")
  sys=$(at "ppm remove -y core/")
  ppm=$(at "ppm implode -y")
  [ -n "$web" ] && [ -n "$app" ] && [ -n "$sys" ] && [ -n "$ppm" ]
  (( web < app && app < wsm && wsm < pcm && pcm < sys && sys < ppm ))
  grep -q "pcm remove -y core/db" "$LOG"
  # remove system keeps ppm and anfs for ppm implode
  run grep "ppm remove -y core/" "$LOG"
  [[ "$output" == *core/pcm* && "$output" == *core/podman* ]]
  [[ "$output" != *core/ppm* && "$output" != *core/anfs* ]]
  # pmm is not installed: never called
  ! grep -q '^pmm' "$LOG"
  [ ! -d "$HOME/.local/state/anfs" ] && [ ! -d "$SOURCES" ]
}

@test "implode: the confirm text lists the stacks; no answer, nothing removed" {
  "$ANFS" install -y system </dev/null
  "$ANFS" install -y lgat/app </dev/null
  : > "$LOG"
  run "$ANFS" implode </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"anfs remove lgat/app"* && "$output" == *"anfs remove core/system"* ]]
  [ ! -s "$LOG" ]
  [ -f "$RECORDS/core/system.yml" ]
}

@test "implode with no records falls back to every installed tool's implode" {
  stub pmm
  run "$ANFS" implode -y </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"no system stack recorded"* ]]
  run cat "$LOG"
  [ "${lines[0]}" = "wsm implode -y" ]
  [ "${lines[1]}" = "psm implode -y" ]
  [ "${lines[2]}" = "pmm implode -y" ]
  [ "${lines[3]}" = "pcm implode -y" ]
  [ "${lines[4]}" = "ppm implode -y" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "anfs src install works without a system record" {
  run "$ANFS" src install -y lgat </dev/null
  [ "$status" -eq 0 ]
  grep -qx "ppm install -y lgat/" "$LOG"
  [ ! -d "$RECORDS" ]
}

@test "src install skips a tool that is not installed (pmm), saying how to get it" {
  mkdir -p "$SOURCES/lgat/machines" "$SOURCES/lgat/skills"
  run "$ANFS" src install -y lgat </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"pmm is not installed: skipping lgat/ machines (ppm install core/pmm)"* ]]
  grep -qx "psm install -y lgat/" "$LOG"
  ! grep -q '^pmm' "$LOG"
}
