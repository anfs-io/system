#!/usr/bin/env bats
# lib/anfs/report.sh: anfs report. A report is built (title, sections, the diagnostics it gathers),
# filed where ANFS_REPORT_TO says (a file: appended with an id; github: duplicates searched, then
# gh issue create after a yes), checked (report check), and followed to its fix (close, status,
# wait). gh, podman and npx are stubs that log their arguments; the sources are local repos whose
# origin is only a URL (nothing is fetched).
# Run: bats packages/anfs/tests/report.bats

bats_require_minimum_version 1.5.0
unset ANFS_WORK ANFS_WORK_SAID  # a person's ANFS_WORK never reaches a test (lib/anfs/work.sh)

setup() {
  PKGS="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$PKGS/anfs/home/.local/lib/anfs"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/home"
  export HOME=$(cd -P "$T/home" && pwd -P)
  CFG="$HOME/.config"
  SRC="$HOME/.local/share/anfs/sources"
  mkdir -p "$HOME/.local/bin" "$HOME/.local/lib" "$CFG/anfs" "$SRC" "$T/bin"
  ln -s "$LIB" "$HOME/.local/lib/anfs"
  ln -s "$PKGS/anfs/home/.local/bin/anfs" "$HOME/.local/bin/anfs"
  ln -s "$PKGS/anfs/home/.config/anfs/anfs.env" "$CFG/anfs/anfs.env"
  printf '/nowhere/core core\n/nowhere/stack stack\n' > "$CFG/anfs/user.list"
  # two sources: local repos, one commit each, origins that name GitHub repos
  for s in core stack; do
    git init -q -b main "$SRC/$s"
    git -C "$SRC/$s" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$s: first"
  done
  git -C "$SRC/core" remote add origin git@github.com:acme/core.git
  git -C "$SRC/stack" remote add origin https://github.com/acme/stack
  # installed packages (ppm's trackers) and an agent package for the skill check
  mkdir -p "$HOME/.local/state/ppm/installed/core" "$HOME/.local/state/ppm/installed/stack"
  printf 'version: 1.2.3\nfiles: []\n' > "$HOME/.local/state/ppm/installed/core/pcm.yml"
  printf 'version: "0.4.0"\n' > "$HOME/.local/state/ppm/installed/stack/widget.yml"
  printf 'version: 2.0.0\n' > "$HOME/.local/state/ppm/installed/core/claude-code.yml"
  mkdir -p "$SRC/core/packages/claude-code" "$SRC/stack/packages/gizmo"
  printf 'meta:\n  agent: claude-code\n' > "$SRC/core/packages/claude-code/package.yml"
  touch "$SRC/stack/packages/gizmo/package.yml"
  for s in core stack; do
    git -C "$SRC/$s" add -A
    git -C "$SRC/$s" -c user.name=t -c user.email=t@t commit -q -m "$s: packages"
  done

  # gh: logs each call; answers from files the test writes
  cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/gh.log"
case "$1 $2" in
  "issue list")   [[ ! -f "$STUB_DIR/gh-dups" ]] || cat "$STUB_DIR/gh-dups" ;;
  "issue create")
    while [[ $# -gt 0 ]]; do [[ "$1" != --body-file ]] || cp "$2" "$STUB_DIR/gh-body"; shift; done
    echo "https://github.com/acme/core/issues/42" ;;
  "issue view")   [[ -f "$STUB_DIR/gh-view" ]] || { echo "no such issue" >&2; exit 1; }; cat "$STUB_DIR/gh-view" ;;
  "auth status")  [[ ! -f "$STUB_DIR/gh-auth-fail" ]] || { echo "You are not logged into any GitHub hosts." >&2; exit 1; } ;;
esac
exit 0
STUB
  printf '#!/usr/bin/env bash\necho "podman version 9.9.9"\n' > "$T/bin/podman"
  # npx: the skills CLI's list
  cat > "$T/bin/npx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/npx.log"
if [[ -f "$STUB_DIR/skills.json" ]]; then cat "$STUB_DIR/skills.json"; else echo '[]'; fi
STUB
  chmod +x "$T/bin/"*
  SYSPATH="$(dirname "$(command -v yq)"):$(dirname "$(command -v bash)"):/usr/bin:/bin"
  DAY=$(date +%Y%m%d)
}

# anfs in a clean environment: HOME, PATH, the stubs' dir, and NAME=value given first. No events
# (ANFS_EVENTS=off) unless a test gives ANFS_EVENTS=on
t() {
  local -a vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  run --separate-stderr env -i HOME="$HOME" PATH="$T/bin:$HOME/.local/bin:$SYSPATH" STUB_DIR="$T" \
    TMPDIR="$T" ANFS_LOG=off ANFS_EVENTS=off ${vars[@]+"${vars[@]}"} anfs "$@"
}

to_file() { printf 'ANFS_REPORT_TO=~/notes/bugs.md\n' > "$CFG/anfs/anfs.local.env"; }

# --- the interface --------------------------------------------------------------------------

@test "anfs report alone is the group's help; options with no sub-command go to new" {
  t report
  [ "$status" -eq 0 ]
  [[ "$output" == *"report <new|diag|check|status|show|close|wait>"* ]]
  [[ "$output" == *"Options with no command go to report new."* ]]
  to_file
  t report --title "x breaks" --actual "it broke" -n
  [ "$status" -eq 0 ]
  [[ "$output" == *"would be r-$DAY-1, recorded in ~/.local/state/anfs/reports/host and shown in ~/notes/bugs.md"* ]]
}

@test "new: a title and something to say are required (64)" {
  t report new --actual x
  [ "$status" -eq 64 ]
  [[ "$stderr" == *"--title is required"* ]]
  t report new --title x
  [ "$status" -eq 64 ]
  [[ "$stderr" == *"say what happened"* ]]
}

@test "completion: report's sub-commands, and new's options after report -" {
  t __complete report ""
  [[ "$output" == *"new"* && "$output" == *"check"* && "$output" == *"wait"* ]]
  t __complete report -
  [[ "$output" == *"--title"* && "$output" == *"--body-file"* ]]
  t __complete report new --package ""
  [[ "$output" == *"core/pcm"* && "$output" == *"stack/widget"* ]]
}

# --- diag -----------------------------------------------------------------------------------

@test "diag: versions, platform, each source's commit and state, each package's version" {
  echo dirt > "$SRC/stack/dirty"
  t report diag
  [ "$status" -eq 0 ]
  [[ "$output" == "### Diagnostics"* ]]
  [[ "$output" == *"- anfs: "[0-9]* ]]
  [[ "$output" == *"- platform: "* ]]
  [[ "$output" == *"- bash: 5"* ]]
  [[ "$output" == *"- git: "[0-9]* ]]
  [[ "$output" == *"- podman: 9.9.9"* ]]
  [[ "$output" == *"| core | $(git -C "$SRC/core" rev-parse --short HEAD) | no upstream |"* ]]
  [[ "$output" == *"| stack | $(git -C "$SRC/stack" rev-parse --short HEAD) | dirty, no upstream |"* ]]
  [[ "$output" == *"| core/pcm | 1.2.3 |"* ]]
  [[ "$output" == *"| stack/widget | 0.4.0 |"* ]]
  [[ "$output" != *"Recent failures"* ]]
}

@test "diag: the log's recent failures, a failed run's command with its end; none when off" {
  mkdir -p "$HOME/.local/state/anfs"
  cat > "$HOME/.local/state/anfs/anfs.log" <<'EOF'
2026-10-22T08:00:00-0400 ppm[11] start: 11-1 install ok-thing
2026-10-22T08:00:01-0400 ppm[11] end: 11-1 0
2026-10-22T08:01:00-0400 pcm[12] start: 12-2 up broken
2026-10-22T08:01:01-0400 pcm[12] error: compose failed
2026-10-22T08:01:02-0400 pcm[12] end: 12-2 1
2026-10-22T08:02:00-0400 wsm[13] warn: just a warning
EOF
  t ANFS_LOG= report diag
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recent failures in the log"* ]]
  [[ "$output" == *"pcm[12] error: compose failed"* ]]
  [[ "$output" == *"pcm[12] start: 12-2 up broken"*"pcm[12] end: 12-2 1"* ]]
  [[ "$output" != *"ok-thing"* && "$output" != *"just a warning"* ]]
  t report diag
  [[ "$output" != *"Recent failures"* ]]
}

@test "diag --json is one object" {
  t --json report diag
  [ "$status" -eq 0 ]
  [[ "$output" == '{"diagnostics":"### Diagnostics\n\n- anfs: '* ]]
}

# --- new: a file ----------------------------------------------------------------------------

@test "new, a file: appended as a dated section with an id and Status: open; earlier text kept" {
  to_file
  mkdir -p "$HOME/notes"
  printf '# Bugs\n\nkeep me' > "$HOME/notes/bugs.md"   # no trailing newline
  t report new --package pcm --title "pcm up hangs" --expected "it starts" --actual "it hangs" --steps "pcm up x"
  [ "$status" -eq 0 ]
  [ "$output" = "r-$DAY-1: filed in ~/notes/bugs.md" ]
  t report --title "second" --actual "again"
  [ "$output" = "r-$DAY-2: filed in ~/notes/bugs.md" ]
  f="$HOME/notes/bugs.md"
  [ "$(head -3 "$f")" = "$(printf '# Bugs\n\nkeep me')" ]
  grep -qx "## r-$DAY-1 pcm up hangs" "$f"
  grep -qx "## r-$DAY-2 second" "$f"
  [ "$(grep -c '^Status: open$' "$f")" -eq 2 ]
  grep -qx 'Package: `core/pcm`' "$f"
  grep -qx '### What was expected' "$f"
  grep -qx '### Steps to reproduce' "$f"
  grep -qx '### Diagnostics' "$f"
  [ ! -f "$T/gh.log" ]
}

@test "new, a file: the directory is made; --json has id, to, file; a relative path is refused" {
  to_file
  t --json report new --title "t" --actual "a"
  [ "$status" -eq 0 ]
  [[ "$output" == "{\"id\":\"r-$DAY-1\",\"to\":\"file\",\"repo\":null,\"file\":\"$HOME/notes/bugs.md\",\"url\":null,"* ]]
  [[ "$output" == *'"filed":true,"duplicates":[],"report":"### What happened\n\na\n\n### Diagnostics'* ]]
  [ -f "$HOME/notes/bugs.md" ]
  t ANFS_REPORT_TO=notes/bugs.md report new --title "t" --actual "a"
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"ANFS_REPORT_TO is 'notes/bugs.md': github or an absolute path"* ]]
}

@test "new --body-file: a file, or - for stdin, placed first" {
  to_file
  printf 'free text\n' > "$T/body"
  t report new --title "b" --body-file "$T/body"
  [ "$status" -eq 0 ]
  grep -qx 'free text' "$HOME/notes/bugs.md"
  run --separate-stderr bash -c 'printf "from stdin\n" | env -i HOME="$HOME" PATH="$1" STUB_DIR="$2" ANFS_LOG=off anfs report new --title c --body-file -' _ "$T/bin:$HOME/.local/bin:$SYSPATH" "$T"
  [ "$status" -eq 0 ]
  grep -qx 'from stdin' "$HOME/notes/bugs.md"
}

@test "new -n: the report and where it would go; nothing appended, no gh call" {
  to_file
  t report new --title "d" --actual "a" -n
  [ "$status" -eq 0 ]
  [[ "$output" == "### What happened"* ]]
  [[ "$output" == *"would be r-$DAY-1, recorded in ~/.local/state/anfs/reports/host and shown in ~/notes/bugs.md" ]]
  [ ! -e "$HOME/notes/bugs.md" ]
  t report new --title "d" --actual "a" --dry-run
  [[ "$output" == *"would be r-$DAY-1, recorded in ~/.local/state/anfs/reports/host and shown in ~/notes/bugs.md" ]]
  t ANFS_REPORT_TO=github report new --title "d" --actual "a" -n
  [ "$status" -eq 0 ]
  [[ "$output" == *"would go to: github acme/core (an issue"* ]]
  [ ! -f "$T/gh.log" ]
}

# --- new: github ----------------------------------------------------------------------------

@test "new, github, no duplicate: searched on the owner's repo, created with the body; the id printed" {
  t report new --title "pcm up hangs" --actual "it hangs" -y
  [ "$status" -eq 0 ]
  [ "$output" = "acme/core#42: https://github.com/acme/core/issues/42" ]
  grep -q '^issue list --repo acme/core --state all --search pcm up hangs in:title' "$T/gh.log"
  grep -q '^issue create --repo acme/core --title pcm up hangs --body-file ' "$T/gh.log"
  grep -qx '### What happened' "$T/gh-body"
  grep -qx '### Diagnostics' "$T/gh-body"
}

@test "new, github, a duplicate: shown first; no terminal and no -y is 77 and nothing filed" {
  printf '7\tOPEN\tpcm up hangs on start\thttps://github.com/acme/core/issues/7\n' > "$T/gh-dups"
  t report new --title "pcm up hangs" --actual "it hangs" </dev/null
  [ "$status" -eq 77 ]
  [[ "$output" == *"possible duplicates on acme/core:"*"#7 OPEN pcm up hangs on start https://github.com/acme/core/issues/7"* ]]
  [[ "$stderr" == *"pass -y"* ]]
  ! grep -q '^issue create' "$T/gh.log"
  t report new --title "pcm up hangs" --actual "it hangs" -y
  [ "$status" -eq 0 ]
  grep -q '^issue create' "$T/gh.log"
}

@test "new, github --json: id, to, repo, url, duplicates as an array" {
  printf '7\tOPEN\tsame\thttps://github.com/acme/core/issues/7\n' > "$T/gh-dups"
  t --json report new --title "x" --actual "y" -y
  [ "$status" -eq 0 ]
  [[ "$output" == '{"id":"acme/core#42","to":"github","repo":"acme/core","file":null,"url":"https://github.com/acme/core/issues/42","title":"x","filed":true,"duplicates":[{"number":"7","state":"OPEN","title":"same","url":"https://github.com/acme/core/issues/7"}],"report":'* ]]
  [[ "$stderr" == *"possible duplicates"* ]]
}

@test "new --package: source/name and an installed name go to their source; an unknown one is 1" {
  t report new --package stack/anything --title "x" --actual "y" -n
  [[ "$output" == *"would go to: github acme/stack"* ]]
  t report new --package widget --title "x" --actual "y" -n
  [[ "$output" == *'Package: `stack/widget`'* && "$output" == *"acme/stack"* ]]
  t report new --package gizmo --title "x" --actual "y" -n
  [[ "$output" == *'Package: `stack/gizmo`'* ]]
  t report new --package nothing --title "x" --actual "y" -n
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"not installed and in no source"* ]]
}

@test "new, github: an origin that is not GitHub is 1, says to set ANFS_REPORT_TO; no gh call" {
  git -C "$SRC/core" remote set-url origin git@gitlab.com:acme/core.git
  t report new --title "x" --actual "y" -y
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"core's origin (git@gitlab.com:acme/core.git) is not on GitHub: set ANFS_REPORT_TO to a file"* ]]
  [ ! -f "$T/gh.log" ]
}

# --- close, status, wait --------------------------------------------------------------------

# A file report r-<day>-1, and a commit in core that is (or is not) on its HEAD
file_report() {
  to_file
  t report new --title "a bug" --actual "y"
  [ "$status" -eq 0 ]
}

@test "file: open, then close rewrites that section's Status line only; status follows the commit" {
  file_report
  t report --title "another" --actual "z"
  t report status "r-$DAY-1"
  [ "$status" -eq 1 ]
  [ "$output" = "r-$DAY-1: open (not fixed yet)" ]
  cp "$HOME/notes/bugs.md" "$T/before"
  # a fix on a branch: not in the checkout's HEAD
  git -C "$SRC/core" checkout -q -b fix
  git -C "$SRC/core" -c user.name=t -c user.email=t@t commit -q --allow-empty -m fix
  sha=$(git -C "$SRC/core" rev-parse HEAD)
  git -C "$SRC/core" checkout -q main
  t report close "r-$DAY-1" --commit "$sha"
  [ "$status" -eq 0 ]
  [ "$output" = "r-$DAY-1: fixed in core $sha (~/notes/bugs.md)" ]
  run diff "$T/before" "$HOME/notes/bugs.md"
  [ "$(printf '%s\n' "$output" | grep -c '^[<>]')" -eq 2 ]
  [[ "$output" == *"> Status: fixed in core $sha ($(date +%Y-%m-%d))"* ]]
  [ "$(grep -c '^Status: open$' "$HOME/notes/bugs.md")" -eq 1 ]
  t report status "r-$DAY-1"
  [ "$status" -eq 1 ]
  [[ "$output" == "r-$DAY-1: fixed (core $sha is not in this host's checkout yet"* ]]
  git -C "$SRC/core" merge -q --ff-only fix
  t report status "r-$DAY-1"
  [ "$status" -eq 0 ]
  [[ "$output" == "r-$DAY-1: available (core $sha is in this host's checkout)" ]]
  t --json report status "r-$DAY-1"
  [ "$output" = "{\"id\":\"r-$DAY-1\",\"status\":\"available\",\"source\":\"core\",\"commit\":\"$sha\",\"detail\":\"core $sha is in this host's checkout\"}" ]
}

@test "status and close: an unknown id is 2; close needs a commit's sha (64)" {
  file_report
  t report status "r-$DAY-9"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no report r-$DAY-9 in ~/.local/state/anfs/reports/host"* ]]
  t report status "nonsense"
  [ "$status" -eq 2 ]
  t report close "r-$DAY-9" --commit abcdef1
  [ "$status" -eq 2 ]
  t report close "r-$DAY-1"
  [ "$status" -eq 64 ]
  t report close "r-$DAY-1" --commit xyz
  [ "$status" -eq 64 ]
}

@test "github: close comments the commit and closes; the source is the one whose origin is the repo" {
  t report close "acme/stack#5" --commit abcdef1
  [ "$status" -eq 0 ]
  [ "$output" = "acme/stack#5: fixed in stack abcdef1, closed" ]
  grep -q '^issue comment 5 --repo acme/stack --body Fixed in stack abcdef1 (anfs report close' "$T/gh.log"
  grep -qx 'issue close 5 --repo acme/stack' "$T/gh.log"
  t report close "other/repo#5" --commit abcdef1
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"name it with --source"* ]]
}

@test "github status: open; closed with the fix commit, fixed or available; unknown is 2" {
  sha=$(git -C "$SRC/core" rev-parse HEAD)
  printf 'OPEN\n' > "$T/gh-view"
  t report status "acme/core#42"
  [ "$status" -eq 1 ]
  [[ "$output" == "acme/core#42: open"* ]]
  grep -q '^issue view 42 --repo acme/core --json state,comments' "$T/gh.log"
  printf 'CLOSED\nlooks good\nFixed in core 1234567 (anfs report close, 2026-10-22)\n' > "$T/gh-view"
  t report status "acme/core#42"
  [ "$status" -eq 1 ]
  [[ "$output" == "acme/core#42: fixed (core 1234567 is not in this host's checkout yet"* ]]
  printf 'CLOSED\nFixed in core %s (anfs report close, 2026-10-22)\n' "$sha" > "$T/gh-view"
  t report status "acme/core#42"
  [ "$status" -eq 0 ]
  [[ "$output" == "acme/core#42: available"* ]]
  rm "$T/gh-view"
  t report status "acme/core#43"
  [ "$status" -eq 2 ]
}

# --- the record, and the file as its view ---------------------------------------------------

# The event line report new or close wrote last (ANFS_EVENTS=on), from the space's log
last_event() { tail -n 1 "$HOME"/.local/state/anfs/events/"$1"/*.jsonl; }

@test "the record: in STATE per space; the file shows it; status and show read the record" {
  notes_space
  to_file
  t report new --title "rec" --actual "it broke"
  [ "$status" -eq 0 ]
  rec="$HOME/.local/state/anfs/reports/notesspc22/r-$DAY-1.md"
  [ "$(head -3 "$rec")" = "$(printf '## r-%s-1 rec\n\nStatus: open' "$DAY")" ]
  # the file's section is the record, byte for byte
  [ "$(cat "$HOME/notes/bugs.md")" = "$(cat "$rec")" ]
  t report show "r-$DAY-1"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$rec")" ]
  t --json report show "r-$DAY-1"
  [[ "$output" == "{\"id\":\"r-$DAY-1\",\"status\":\"open\",\"record\":\"$rec\",\"file\":\"$HOME/notes/bugs.md\",\"report\":\"## r-$DAY-1 rec"* ]]
  # the file is a view: its section gone, status still reads the record
  : > "$HOME/notes/bugs.md"
  t report status "r-$DAY-1"
  [ "$status" -eq 1 ]
  [[ "$output" == "r-$DAY-1: open"* ]]
  t report show "r-$DAY-9"
  [ "$status" -eq 2 ]
  t report show nonsense
  [ "$status" -eq 2 ]
  # GitHub: the issue
  printf 'issue text\n' > "$T/gh-view"
  t report show "acme/core#42"
  [ "$status" -eq 0 ]
  grep -qx 'issue view 42 --repo acme/core --comments' "$T/gh.log"
}

@test "ids are unique per space: two sink files in one space, and a heading already in the file" {
  notes_space
  t ANFS_REPORT_TO=~/notes/bugs.md report new --title one --actual a
  [ "$output" = "r-$DAY-1: filed in ~/notes/bugs.md" ]
  t ANFS_REPORT_TO=~/notes/other.md report new --title two --actual a
  [ "$output" = "r-$DAY-2: filed in ~/notes/other.md" ]
  # a section written before the records: its id is not taken again
  mkdir -p "$HOME/old"
  printf '## r-%s-4 an old one\n\nStatus: open\n' "$DAY" > "$HOME/old/BACKLOG.md"
  t ANFS_REPORT_TO=~/old/BACKLOG.md report new --title three --actual a
  [ "$output" = "r-$DAY-5: filed in ~/old/BACKLOG.md" ]
  [ -f "$HOME/.local/state/anfs/reports/host/r-$DAY-5.md" ]
  # which stays text only: status says so, close says to edit it by hand
  t ANFS_REPORT_TO=~/old/BACKLOG.md report status "r-$DAY-4"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"a report filed before the records is text only"* ]]
  t ANFS_REPORT_TO=~/old/BACKLOG.md report close "r-$DAY-4" --commit abcdef1
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"edit its Status line by hand"* ]]
}

@test "ten new at once: ten ids, ten records, ten sections" {
  to_file
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    env -i HOME="$HOME" PATH="$T/bin:$HOME/.local/bin:$SYSPATH" STUB_DIR="$T" TMPDIR="$T" ANFS_LOG=off ANFS_EVENTS=off \
      anfs report new --title "p$i" --actual a >"$T/out.$i" 2>&1 &
  done
  wait
  [ "$(cat "$T"/out.* | sed -n 's/: filed in.*//p' | sort -u | wc -l | tr -d ' ')" -eq 10 ]
  [ "$(ls "$HOME/.local/state/anfs/reports/host" | wc -l | tr -d ' ')" -eq 10 ]
  [ "$(grep -c '^## r-' "$HOME/notes/bugs.md")" -eq 10 ]
  [ "$(grep '^## r-' "$HOME/notes/bugs.md" | cut -d' ' -f2 | sort -u | wc -l | tr -d ' ')" -eq 10 ]
}

@test "__sink: renders a report.filed once however often it runs; report.closed rewrites the line" {
  notes_space
  to_file
  # anfsd is up (a live pid) and events are on: new leaves the file to the sink
  mkdir -p "$HOME/.local/state/anfsd"
  sleep 300 </dev/null >/dev/null 2>&1 & local pid=$!
  echo "$pid" > "$HOME/.local/state/anfsd/anfsd.pid"
  t ANFS_EVENTS=on report new --title "sunk" --actual a
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/notes/bugs.md" ]
  ev=$(last_event notesspc22)
  [[ "$ev" == *'"type":"io.anfs.report.filed"'* ]]
  for i in 1 2 3; do
    run bash -c 'printf "%s\n" "$1" | env -i HOME="$HOME" PATH="$2" ANFS_LOG=off ANFS_EVENTS=off anfs report __sink' _ "$ev" "$HOME/.local/bin:$SYSPATH"
    [ "$status" -eq 0 ]
  done
  [ "$(grep -c "^## r-$DAY-1 sunk" "$HOME/notes/bugs.md")" -eq 1 ]
  sha=$(git -C "$SRC/core" rev-parse HEAD)
  t ANFS_EVENTS=on report close "r-$DAY-1" --commit "$sha"
  grep -qx 'Status: open' "$HOME/notes/bugs.md"
  ev=$(last_event notesspc22)
  for i in 1 2; do
    run bash -c 'printf "%s\n" "$1" | env -i HOME="$HOME" PATH="$2" ANFS_LOG=off anfs report __sink' _ "$ev" "$HOME/.local/bin:$SYSPATH"
    [ "$status" -eq 0 ]
  done
  [ "$(grep -c '^Status: ' "$HOME/notes/bugs.md")" -eq 1 ]
  grep -qx "Status: fixed in core $sha ($(date +%Y-%m-%d))" "$HOME/notes/bugs.md"
  # anfsd gone: new renders itself again
  kill "$pid"; wait "$pid" 2>/dev/null || true
  t ANFS_EVENTS=on report new --title "self" --actual a
  grep -qx "## r-$DAY-2 self" "$HOME/notes/bugs.md"
  # what is not the sink's: another type, another space's record, GitHub ids, not an event
  for ev in '{"specversion":"1.0","id":"01a169de-e9bb-7000-8000-000000000001","source":"/anfs/host","type":"io.anfs.source.updated","subject":"core","actor":"x","anfsv":1,"data":{}}' \
            '{"specversion":"1.0","id":"01a169de-e9bb-7000-8000-000000000002","source":"/anfs/spaces/zzzzz23456","type":"io.anfs.report.filed","subject":"r-20261023-1","actor":"x","anfsv":1,"data":{"to":"file"}}' \
            '{"specversion":"1.0","id":"01a169de-e9bb-7000-8000-000000000003","source":"/anfs/host","type":"io.anfs.report.filed","subject":"acme/core#1","actor":"x","anfsv":1,"data":{"to":"github"}}'; do
    run bash -c 'printf "%s\n" "$1" | env -i HOME="$HOME" PATH="$2" ANFS_LOG=off anfs report __sink' _ "$ev" "$HOME/.local/bin:$SYSPATH"
    [ "$status" -eq 0 ]
  done
  run bash -c 'echo nonsense | env -i HOME="$HOME" PATH="$1" ANFS_LOG=off anfs report __sink' _ "$HOME/.local/bin:$SYSPATH"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^## r-' "$HOME/notes/bugs.md")" -eq 2 ]
}

@test "__sink: waits for the lock beside the file, and takes over one a dead process left" {
  to_file
  t report new --title "l" --actual a
  : > "$HOME/notes/bugs.md"
  mkdir "$HOME/notes/.bugs.md.lock"
  echo 999999 > "$HOME/notes/.bugs.md.lock/pid"
  ev='{"specversion":"1.0","id":"01a169de-e9bb-7000-8000-000000000001","source":"/anfs/host","type":"io.anfs.report.filed","subject":"r-'"$DAY"'-1","actor":"x","anfsv":1,"data":{"to":"file"}}'
  run bash -c 'printf "%s\n" "$1" | env -i HOME="$HOME" PATH="$2" ANFS_LOG=off anfs report __sink' _ "$ev" "$HOME/.local/bin:$SYSPATH"
  [ "$status" -eq 0 ]
  grep -qx "## r-$DAY-1 l" "$HOME/notes/bugs.md"
  [ ! -e "$HOME/notes/.bugs.md.lock" ]
}

# An event from another process (ANFS_EVENTS on): anfs_emit <args...>
emit() {
  env -i HOME="$HOME" PATH="$SYSPATH" ANFS_LOG=off ANFS_ACTOR=shell:test \
    bash -c 'source "$1/paths.sh"; source "$1/log.sh"; source "$1/events.sh"; shift; anfs_emit "$@"' _ "$LIB" "$@"
}

# The report file in a space with an id, so its events have a scope of their own
notes_space() { mkdir -p "$HOME/notes"; printf 'id: notesspc22\n' > "$HOME/notes/space.yml"; }

# A fix on a branch of core, not in the checkout's HEAD: its sha in FIX
fix_branch() {
  git -C "$SRC/core" checkout -q -b fix
  git -C "$SRC/core" -c user.name=t -c user.email=t@t commit -q --allow-empty -m fix
  FIX=$(git -C "$SRC/core" rev-parse HEAD)
  git -C "$SRC/core" checkout -q main
}

@test "wait: 0 at once when available; 1 at the timeout; 2 for an unknown id; --interval is gone" {
  file_report
  t report wait "r-$DAY-1" --timeout 0
  [ "$status" -eq 1 ]
  [[ "$output" == "r-$DAY-1: open"* ]]
  [[ "$stderr" == *"timed out after 0s"* ]]
  sha=$(git -C "$SRC/core" rev-parse HEAD)
  t report close "r-$DAY-1" --commit "$sha"
  t report wait "r-$DAY-1" --timeout 5
  [ "$status" -eq 0 ]
  [[ "$output" == "r-$DAY-1: available"* ]]
  t report wait "r-$DAY-7" --timeout 5
  [ "$status" -eq 2 ]
  t report wait "nonsense" --timeout 5
  [ "$status" -eq 2 ]
  t report wait "r-$DAY-1" --interval 1
  [ "$status" -eq 64 ]
}

@test "wait: returns when another process closes the report with a commit already here" {
  notes_space
  file_report
  sha=$(git -C "$SRC/core" rev-parse HEAD)
  ( sleep 2; t ANFS_EVENTS=on report close "r-$DAY-1" --commit "$sha" ) &
  local t0=$EPOCHSECONDS
  t report wait "r-$DAY-1" --timeout 30
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == "r-$DAY-1: available"* ]]
  (( EPOCHSECONDS - t0 < 10 ))
}

@test "wait: closed, then the fix pulled: returns on the source.updated" {
  file_report
  fix_branch
  t report close "r-$DAY-1" --commit "$FIX"
  ( sleep 2; git -C "$SRC/core" merge -q --ff-only fix; emit --host source.updated core from=a "to=$FIX" ) &
  t report wait "r-$DAY-1" --timeout 30
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == "r-$DAY-1: available"* ]]
}

@test "wait: the fix merged with no event is not seen: it times out with 1 (nothing polls git)" {
  file_report
  fix_branch
  t report close "r-$DAY-1" --commit "$FIX"
  ( sleep 1; git -C "$SRC/core" merge -q --ff-only fix ) &
  t report wait "r-$DAY-1" --timeout 3
  wait
  [ "$status" -eq 1 ]
  [[ "$output" == "r-$DAY-1: fixed"* ]]
  [[ "$stderr" == *"timed out after 3s"* ]]
}

@test "wait: git merge-base once per event, none per second; other events read nothing" {
  notes_space
  file_report
  fix_branch
  t report close "r-$DAY-1" --commit "$FIX"
  local real
  real=$(command -v git)
  printf '#!/bin/sh
[ "$1 $2 $3" != "-C %s merge-base" ] || echo x >> "%s/merge-base.log"
exec %s "$@"
' \
    "$SRC/core" "$T" "$real" > "$T/bin/git"
  chmod +x "$T/bin/git"
  ( sleep 1; emit --at "$HOME/notes" report.closed "r-$DAY-9" commit=abc source=core; emit --host report.filed x ) &
  t report wait "r-$DAY-1" --timeout 4
  wait
  [ "$status" -eq 1 ]
  # the first read only, over 4 s and two events not about it
  [ "$(wc -l < "$T/merge-base.log" | tr -d ' ')" = 1 ]
  ( sleep 1; emit --host source.updated stack from=a to=b ) &
  t report wait "r-$DAY-1" --timeout 3
  wait
  [ "$(wc -l < "$T/merge-base.log" | tr -d ' ')" = 3 ]
}

# --- check ----------------------------------------------------------------------------------

skill_installed() {
  printf '[{"name":"anfs-bug-report","agents":[%s],"source":"core","path":"%s/.agents/skills/anfs-bug-report"}]\n' "$1" "$HOME" > "$T/skills.json"
}

@test "check, github, all ok: gh, its auth, both origins, the skill; exit 0" {
  skill_installed '"Claude Code"'
  t report check
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'report-to\tok\tgithub (default, ~/.config/anfs/anfs.env)')" ]
  [ "${lines[1]}" = "$(printf 'gh\tok\t%s/bin/gh' "$T")" ]
  [ "${lines[2]}" = "$(printf 'gh-auth\tok\tlogged in')" ]
  [ "${lines[3]}" = "$(printf 'origin core\tok\tacme/core')" ]
  [ "${lines[4]}" = "$(printf 'origin stack\tok\tacme/stack')" ]
  [ "${lines[5]}" = "$(printf 'skill\tok\tanfs-bug-report: installed for Claude Code')" ]
  grep -qx 'auth status' "$T/gh.log"
  grep -q 'list -g --json' "$T/npx.log"
}

@test "check, github: gh auth failing, a non-GitHub origin, the skill missing: each a fail, exit 1" {
  touch "$T/gh-auth-fail"
  git -C "$SRC/stack" remote set-url origin /srv/stack.git
  t report check
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh-auth"$'\t'"fail"$'\t'"gh auth status: You are not logged into any GitHub hosts. (gh auth login)"* ]]
  [[ "$output" == *"origin core"$'\t'"ok"* ]]
  [[ "$output" == *"origin stack"$'\t'"fail"$'\t'"stack's origin (/srv/stack.git) is not on GitHub"* ]]
  [[ "$output" == *"skill"$'\t'"fail"$'\t'"anfs-bug-report: not installed (psm install core/anfs-bug-report)"* ]]
}

@test "check, github: no gh on PATH" {
  skill_installed '"Claude Code"'
  # the system's directories, without any gh
  mkdir -p "$T/nogh"
  for d in ${SYSPATH//:/ }; do
    for f in "$d"/*; do
      [[ "${f##*/}" != gh && ! -e "$T/nogh/${f##*/}" ]] || continue
      ln -s "$f" "$T/nogh/${f##*/}"
    done
  done
  rm "$T/bin/gh"
  run --separate-stderr env -i HOME="$HOME" PATH="$T/bin:$HOME/.local/bin:$T/nogh" STUB_DIR="$T" ANFS_LOG=off anfs report check
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh"$'\t'"fail"$'\t'"not on PATH (brew install gh)"* ]]
  [[ "$output" == *"skill"$'\t'"ok"* ]]
}

@test "check, a file: writable or to be created is ok; one that cannot be written is a fail" {
  skill_installed '"Claude Code"'
  to_file
  t report check
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'report-to\tok\t~/notes/bugs.md (local, ~/.config/anfs/anfs.local.env)')" ]
  [ "${lines[1]}" = "$(printf 'file\tok\t~/notes/bugs.md: will be created')" ]
  [[ "$output" != *"gh"* ]]
  mkdir -p "$HOME/notes"; touch "$HOME/notes/bugs.md"
  t report check
  [ "${lines[1]}" = "$(printf 'file\tok\t~/notes/bugs.md: writable')" ]
  chmod a-w "$HOME/notes/bugs.md"
  t report check
  chmod u+w "$HOME/notes/bugs.md"
  [ "$status" -eq 1 ]
  [ "${lines[1]}" = "$(printf 'file\tfail\t~/notes/bugs.md: not a writable file')" ]
}

@test "check: the skill on some agents only is a fail (partial); --json is the rows" {
  printf 'version: 1.0.0\n' > "$HOME/.local/state/ppm/installed/core/pi.yml"
  mkdir -p "$SRC/core/packages/pi"
  printf 'meta:\n  agent: pi\n' > "$SRC/core/packages/pi/package.yml"
  skill_installed '"Claude Code"'
  # the universal agent counts only with the shared copy; the stub's path is elsewhere
  sed -i.bak 's#/.agents/skills/#/elsewhere/#' "$T/skills.json"
  t report check
  [ "$status" -eq 1 ]
  [[ "$output" == *"skill"$'\t'"fail"$'\t'"anfs-bug-report: installed for Claude Code, not every agent (psm sync core)"* ]]
  t --json report check
  [ "$status" -eq 1 ]
  [[ "$output" == '[{"check":"report-to","status":"ok","detail":"github (default, ~/.config/anfs/anfs.env)"}'* ]]
  [[ "$output" == *'{"check":"skill","status":"fail",'* ]]
}


# --- events (lib/anfs/events.sh) -----------------------------------------------------------

# The one event a scope's log has (its last line), as JSON
last_event() { tail -n 1 "$HOME/.local/state/anfs/events/$1/"*.jsonl; }

@test "events: a file report emits report.filed into the file's space, close report.closed; -n emits nothing" {
  to_file
  mkdir -p "$HOME/notes"
  printf 'id: notesspc22\n' > "$HOME/notes/space.yml"
  t ANFS_EVENTS=on report --title "-n first" --actual x -n
  [ "$status" -eq 0 ]
  [ ! -d "$HOME/.local/state/anfs/events" ]
  t ANFS_EVENTS=on report --package core/pcm --title 'it "broke"' --actual x
  [ "$status" -eq 0 ] && [ -z "$stderr" ]
  run yq -p json -o json -I0 '[.type, .subject, .source, .data.package, .data.title, .data.to]' <<< "$(last_event notesspc22)"
  [ "$output" = "[\"io.anfs.report.filed\",\"r-$DAY-1\",\"/anfs/spaces/notesspc22\",\"core/pcm\",\"it \\\"broke\\\"\",\"file\"]" ]
  t ANFS_EVENTS=on report close "r-$DAY-1" --commit abcdef1
  [ "$status" -eq 0 ]
  run yq -p json -o json -I0 '[.type, .subject, .data.commit, .data.source]' <<< "$(last_event notesspc22)"
  [ "$output" = "[\"io.anfs.report.closed\",\"r-$DAY-1\",\"abcdef1\",\"core\"]" ]
  [ "$(cat "$HOME/.local/state/anfs/events/notesspc22/"*.jsonl | wc -l | tr -d ' ')" = 2 ]
}

@test "events: GitHub reports go to the host scope, with the repo; ANFS_EVENTS=off writes nothing" {
  t report new --title "off" --actual x -y
  [ ! -d "$HOME/.local/state/anfs/events" ]
  t ANFS_EVENTS=on report new --title "pcm up hangs" --actual "it hangs" -y
  [ "$status" -eq 0 ]
  run yq -p json -o json -I0 '[.type, .subject, .source, .data.to, .data.repo, has("data") and (.data | has("package"))]' <<< "$(last_event host)"
  [ "$output" = '["io.anfs.report.filed","acme/core#42","/anfs/host","github","acme/core",false]' ]
  t ANFS_EVENTS=on report close "acme/stack#5" --commit abcdef1
  run yq -p json -r '.type + " " + .subject + " " + .data.source' <<< "$(last_event host)"
  [ "$output" = "io.anfs.report.closed acme/stack#5 stack" ]
}
