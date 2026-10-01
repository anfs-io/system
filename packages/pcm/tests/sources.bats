#!/usr/bin/env bats
# Sources and resolution: priority, qualified names, shadowing.
# Run: bats packages/pcm/tests/

load helper

setup() {
  pcm_setup
  add_source a
  add_source b
  define "$PCM_CONTAINERS_HOME" mine
  define "$T/src/a/containers" postgres
  define "$T/src/a/containers" only-a
  define "$T/src/b/containers" postgres
  load_sources
}

@test "sources: local first, then the lists in order" {
  [ "${SRC_NAMES[*]}" = "local a b" ]
  [ "${SRC_DIRS[1]}" = "$T/src/a/containers" ]
}

@test "canon: a plain name resolves to the highest-priority source" {
  [ "$(canon postgres)" = "a/postgres" ]
  [ "$(canon mine)" = "local/mine" ]
}

@test "canon: source/name picks that definition; bad specs fail" {
  [ "$(canon b/postgres)" = "b/postgres" ]
  run canon b/only-a;  [ "$status" -eq 1 ]
  run canon nope;      [ "$status" -eq 1 ]
  run canon a/b/c;     [ "$status" -eq 1 ]
  run canon "";        [ "$status" -eq 1 ]
}

@test "a local definition shadows every source" {
  define "$PCM_CONTAINERS_HOME" postgres
  [ "$(canon postgres)" = "local/postgres" ]
}

@test "all_ids lists shadowed definitions; effective_ids one per name" {
  run all_ids
  [ "${lines[*]}" = "local/mine a/only-a a/postgres b/postgres" ]
  run effective_ids
  [ "${lines[*]}" = "local/mine a/only-a a/postgres" ]
}

@test "svc helpers split an id" {
  [ "$(svc_name a/postgres)" = postgres ]
  [ "$(svc_src a/postgres)" = a ]
  [ "$(svc_dir b/postgres)" = "$T/src/b/containers/postgres" ]
}

@test "a list alias named local is ignored with a warning" {
  mkdir -p "$T/src/x/containers"
  echo "$T/src/x  local" >> "$ANFS_USER_LIST"
  run load_sources
  [[ "$output" == *"ignoring source alias 'local'"* ]]
}

@test "path resolves; unknown fails" {
  run cmd_path postgres
  [ "$output" = "$T/src/a/containers/postgres" ]
  run cmd_path nope
  [ "$status" -eq 1 ]
}

@test "list: NAME SOURCE STATUS, sorted by name then priority, shadowed marked" {
  run cmd_list
  [ "${lines[0]}" = "NAME      SOURCE  STATUS" ]
  [ "${lines[1]}" = "mine      local   " ]
  [ "${lines[2]}" = "only-a    a       " ]
  [ "${lines[3]}" = "postgres  a       " ]
  [ "${lines[4]}" = "postgres  b       shadowed" ]
}

@test "list: STATUS comes from the io.pcm.id label" {
  podman() {
    [[ "$1 $2" == "ps -a" ]] || return 0
    echo '[{"Id":"1","Names":["postgres_db_1"],"State":"running","Status":"Up","Labels":{"io.pcm.id":"b/postgres"}}]'
  }
  run cmd_list
  [ "${lines[3]}" = "postgres  a       " ]
  [ "${lines[4]}" = "postgres  b       running, shadowed" ]
}

@test "list --names: every id, and each effective name once" {
  run cmd_list --names
  [ "${lines[*]}" = "local/mine mine a/only-a only-a a/postgres postgres b/postgres" ]
}
