#!/usr/bin/env bats
# Space ids and wsm events ls: `id:` in space.yml, written once (wsm new, wsm id --new), never
# changed; wsm ls says when one is missing, malformed or shared; `wsm events ls` reads the log of
# the space around . or of the spaces a spec names (lib/anfs/events.sh). wsm move keeps an id:
# move.bats.
# Run: bats packages/wsm/tests/ids.bats

load helper
setup() {
  wsm_setup
  mksource acme >/dev/null
  space_def acme <<<'id: acmeroot22'
  space_def acme main/tech <<<$'id: acmetech22\nrepositories: []'
  NOID=1 space_def acme main/bare <<<'repositories: []'
  SD="$BATS_TEST_TMPDIR/srcs/acme/spaces"
}

@test "wsm new writes an id, after the header comment; wsm id prints it" {
  run wsm new acme/fresh
  [ "$status" -eq 0 ]
  run wsm id acme/fresh
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[a-z2-7]{10}$ ]]
  [ "$(yq -r .id "$SD/fresh/space.yml")" = "$output" ]
  [[ "$(sed -n 1p "$SD/fresh/space.yml")" == "# acme/fresh:"* ]]
  [[ "$(sed -n 2p "$SD/fresh/space.yml")" == "id: $output "* ]]
}

@test "wsm id: an id spec, a prefix's SPACE ID rows, the space around .; a space with none is 1" {
  run wsm id acme/main/tech
  [ "$status" -eq 0 ] && [ "$output" = acmetech22 ]
  run wsm id acme/main/
  [ "$status" -eq 0 ]
  [ "$output" = $'acme/main/bare\t-\nacme/main/tech\tacmetech22' ]
  wsm install acme/main/tech >/dev/null
  cd "$HOME/spaces/acme/main/tech"
  run wsm id
  [ "$output" = acmetech22 ]
  cd "$SD/main/tech"
  run wsm id
  [ "$output" = acmetech22 ]
  run wsm id acme/main/bare
  [ "$status" -eq 1 ] && [[ "$output" == *"acme/main/bare has no id (wsm id --new acme/main/bare)"* ]]
  cd "$BATS_TEST_TMPDIR"
  run wsm id
  [ "$status" -eq 1 ] && [[ "$output" == *"not inside a space"* ]]
}

@test "wsm id --new writes only a missing id, never changes one, and twice is the same id" {
  before=$(cat "$SD/main/tech/space.yml")
  run wsm id --new acme/
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == $'acme\tkept\tacmeroot22' ]]
  [[ "${lines[1]}" =~ ^acme/main/bare$'\t'new$'\t'[a-z2-7]{10}$ ]]
  [[ "${lines[2]}" == $'acme/main/tech\tkept\tacmetech22' ]]
  [[ "$output" == *"commit it in"* ]]
  new=$(yq -r .id "$SD/main/bare/space.yml")
  [ "$(cat "$SD/main/tech/space.yml")" = "$before" ]
  [ "$(cat "$SD/main/bare/space.yml")" = "id: $new"$'\nrepositories: []' ]
  run wsm id --new acme/main/bare
  [ "$status" -eq 0 ] && [[ "$output" == *$'kept\t'"$new"* ]]
  [ "$(yq -r .id "$SD/main/bare/space.yml")" = "$new" ]
  run wsm id --new
  [ "$status" -eq 64 ]
}

@test "wsm id --new: a {} file becomes the id alone; a malformed id is left, and 1" {
  NOID=1 space_def acme empty <<<'{}'
  printf 'id: Not-An-Id\n' > "$SD/main/bare/space.yml"
  run wsm id --new acme/empty
  [ "$status" -eq 0 ]
  [[ "$(cat "$SD/empty/space.yml")" =~ ^id:\ [a-z2-7]{10}$ ]]
  run wsm id --new acme/main/bare
  [ "$status" -eq 1 ] && [[ "$output" == *"invalid id"* ]]
  [ "$(cat "$SD/main/bare/space.yml")" = "id: Not-An-Id" ]
}

@test "wsm ls: NOTE says no id, invalid id and duplicate id (STATUS unchanged); --json has id" {
  space_def acme dup <<<'id: acmetech22'
  wsm install acme/main/tech acme/main/bare >/dev/null
  run wsm ls
  [[ "$output" == *$'acme/main/bare\tok\t'*$'\tno id'* ]]
  [[ "$output" == *$'acme/main/tech\tok\t'*$'\tduplicate id (also acme/dup)'* ]]
  [[ "$output" == *$'acme/dup\t-\t-\tduplicate id (also acme/main/tech)'* ]]
  [[ "$output" == *$'acme\t-\t-\t-'* ]]
  [ "$(ls_field acme/main/tech id)" = acmetech22 ]
  [ "$(ls_field acme/main/bare id)" = null ]
}

# --- wsm events ls --------------------------------------------------------------------------

# An event through the library, filed in <dir>'s space
emit_at() {
  ANFS_EVENTS=on bash -c 'source "$HOME/.local/lib/anfs/paths.sh"; source "$ANFS_LIB_DIR/log.sh"; source "$ANFS_LIB_DIR/events.sh"; anfs_emit --at "$@"' _ "$@"
}

@test "wsm events ls: the space around ., an id spec, a prefix; a space with no id warns" {
  emit_at "$SD/main/tech" report.filed r-1
  emit_at "$SD" space.made acme
  emit_at "$BATS_TEST_TMPDIR" other.thing h
  cd "$SD/main/tech"
  run wsm events ls
  [ "$status" -eq 0 ] && [ "${#lines[@]}" -eq 1 ] && [[ "$output" == *$'report.filed\tr-1\tacme/main/tech\t'* ]]
  run wsm events ls acme
  [ "${#lines[@]}" -eq 1 ] && [[ "$output" == *space.made* ]]
  run wsm events ls acme/
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme/main/bare has no id, so no events (wsm id --new acme/main/bare)"* ]]
  [[ "$output" == *space.made* && "$output" == *report.filed* && "$output" != *other.thing* ]]
  run wsm events ls acme/main/bare
  [ "$status" -eq 1 ]
  run wsm events ls acme/nope
  [ "$status" -eq 1 ]
  cd "$SD/main/bare"
  run wsm events ls
  [ "$status" -eq 1 ] && [[ "$output" == *"has no id, so no events"* ]]
  run wsm __event_spaces acme/main/
  [ "$output" = $'wsm: acme/main/bare has no id, so no events (wsm id --new acme/main/bare)\nacmetech22' ]
}

@test "wsm events ls -f --once ends when the space's event is appended" {
  cd "$SD/main/tech"
  ( exec "$WSM" events ls -f --once --type report.closed --subject r-2 ) > "$BATS_TEST_TMPDIR/bg" 2>&1 3>&- &
  bgpid=$!
  sleep 1.5
  kill -0 "$bgpid"
  emit_at "$SD/main/tech" report.closed r-2 commit=abc
  for _ in $(seq 50); do kill -0 "$bgpid" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$bgpid" 2>/dev/null || { kill "$bgpid"; false; }
  wait "$bgpid"
  [[ "$(cat "$BATS_TEST_TMPDIR/bg")" == *$'report.closed\tr-2\tacme/main/tech'* ]]
}
