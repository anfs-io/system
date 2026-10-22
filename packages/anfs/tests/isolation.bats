#!/usr/bin/env bats
# What a test may share with the host: nothing that belongs to the live install. Two jobs run their
# suites at once on one machine (anfs work, in the anfs-dev source), and a pmm really running
# machines there keeps their sockets in /tmp/pmm-<uid>, which a pmm implode deletes. So no suite
# may name that directory, point a *_HOME at a real home, write under the real ~, or kill by
# pattern.
#
# Checked: every suite's bats files, helpers, stubs and e2e scripts. Not checked: the round trips
# and their harness, whose ~ and /home are a test box's, and anfs-dev's suites (its own repo).
# What a grep cannot see, a suite that never sets PMM_SOCK_DIR, pmm refuses itself under bats
# (sock_dir_path in lib/pmm/core.sh).
# Run: bats packages/anfs/tests/

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # the live socket directory, by $(id -u), $UID, a $uid of the test's own, or a number
  SOCK_RE='/tmp/pmm-(\$\(id -u\)|\$\{?[A-Za-z_]*(UID|uid)\}?|[0-9]+)([^0-9A-Za-z_-]|$)'
}

# The files the rule covers, one per line
covered() {
  find "$REPO"/packages/*/tests -type f \( -name '*.bats' -o -name '*.bash' -o -name e2e -o -path '*/stubs/*' \) \
    ! -name isolation.bats | LC_ALL=C sort
}

# grep -nE <pattern> over the covered files; prints the matches
matches() {
  local f
  while IFS= read -r f; do
    grep -nHE -- "$1" "$f" || true
  done < <(covered)
}

@test "the patterns catch what they are for" {
  PROBE="$BATS_TEST_TMPDIR/probe.bash"
  # shellcheck disable=SC2016
  printf '%s\n' 'd=/tmp/pmm-$uid' 'd=/tmp/pmm-${uid}' 'd=/tmp/pmm-$UID' > "$PROBE"
  covered() { echo "$PROBE"; }
  run matches "$SOCK_RE"
  [ "${#lines[@]}" -eq 3 ]
}

@test "the rule covers every suite" {
  run covered
  [[ "$output" == *"/pmm/tests/helper.bash"* && "$output" == *"/pmm/tests/e2e"* && "$output" == *"/wsm/tests/"* ]]
}

@test "no test names the live socket directory, /tmp/pmm-<uid>" {
  run matches "$SOCK_RE"
  [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "no test kills by pattern" {
  run matches '(^|[^A-Za-z_])(pkill|killall)([^A-Za-z_]|$)'
  [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "no test points a *_HOME at a real home, or writes under the real ~" {
  run matches '_HOME="?(~|/Users/|/home/)'
  [ -z "$output" ] || { echo "$output"; return 1; }
  # a literal ~ is the real home whatever HOME the test set (expected output may show one: it is
  # how the tools display a path under the test HOME)
  run matches '(^|[[:space:];|&(])(rm|mkdir|cp|mv|ln|touch|chmod|rmdir)[[:space:]][^#]*[[:space:]]~/|(^|[^-])>>?[[:space:]]*~/'
  [ -z "$output" ] || { echo "$output"; return 1; }
  # nor spells out the home of whoever runs the suite
  local home
  home=$(cd "$HOME" && pwd -P)
  run bash -c 'while IFS= read -r f; do grep -nHF -- "$1/." "$f" || true; done' _ "$home" < <(covered)
  [ -z "$output" ] || { echo "$output"; return 1; }
}

@test "a suite that sets HOME unsets ANFS_WORK (lib/anfs/work.sh), or the helper it loads does" {
  local f bad="" unset_re='^[[:space:]]*unset([[:space:]]+[A-Za-z0-9_]+)*[[:space:]]+ANFS_WORK([[:space:]]|$)'
  while IFS= read -r f; do
    [[ "$f" == *.bats || "$f" == *.bash ]] || continue
    grep -v '^[[:space:]]*#' "$f" | grep -qE '(^|[^A-Za-z0-9_])HOME=' || continue
    grep -qE "$unset_re" "$f" && continue
    grep -qE '^[[:space:]]*load helper' "$f" && grep -qE "$unset_re" "${f%/*}/helper.bash" 2>/dev/null && continue
    bad+="$f"$'\n'
  done < <(covered)
  [ -z "$bad" ] || { printf '%s' "$bad"; return 1; }
}
