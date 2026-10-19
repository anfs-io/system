#!/usr/bin/env bats
# container.yml: validate, list and show; memory as the limit and the room `pcm up` checks for,
# with podman machine inspect, podman ps and free stubbed.
# Run: bats packages/pcm/tests/

load helper

setup() {
  pcm_setup
  add_source a
  export ANFS_TABLE=tsv
  CALLS="$T/podman.calls"
  : > "$CALLS"
  # The stub engine: the machine has MEM MiB; RUNNING is "pcm-id name" lines of running containers
  MEM=2048 RUNNING="" AVAIL=8000
}

manifest() { printf '%s\n' "$2" > "$T/src/a/containers/$1/container.yml"; }

validate() {
  load_sources
  run validate_services "$@"
}

podman() {
  echo "$*" >> "$CALLS"
  case "$1 ${2:-}" in
    "machine list") echo podman-machine-default ;;
    "machine inspect")
      case "$*" in
        *Memory*) echo "$MEM" ;;
        *State*) echo running ;;
      esac ;;
    "machine set") MEM="$4" ;;
    "machine stop"|"machine start") ;;
    "ps -a")
      local id name
      [[ -n "$RUNNING" ]] || return 0
      printf '[' ; local first=true
      while read -r id name; do
        $first || printf ','
        first=false
        printf '{"Id":"x","Names":["%s"],"State":"running","Labels":{"io.pcm.id":"%s"},"Status":"Up"}' "$name" "$id"
      done <<< "$RUNNING"
      printf ']\n' ;;
    "ps --format") [[ -z "$RUNNING" ]] || cut -d' ' -f2 <<< "$RUNNING" ;;
    *) return 1 ;;
  esac
}

free() {
  printf '               total        used        free      shared  buff/cache   available\n'
  printf 'Mem:           16000        8000        1000         100        7000        %s\n' "$AVAIL"
}

called() { grep -qxF -- "$1" "$CALLS"; }

# --- validate -----------------------------------------------------------------

@test "a container.yml with every key is valid" {
  define "$T/src/a/containers" web
  manifest web 'version: 0.1.0
description: A web server
upstream: docker.io/library/nginx:1
license: BSD-2-Clause
url: https://nginx.org
memory: 256m'
  validate a/web
  [ "$status" -eq 0 ]
  [[ "$output" != *warning* ]]
}

@test "no container.yml: valid, with a warning" {
  define "$T/src/a/containers" bare
  validate a/bare
  [ "$status" -eq 0 ]
  [[ "$output" == *"a/bare: warning: no container.yml"* ]]
}

@test "an unknown key, a missing version, a bad memory and a non-map are errors" {
  define "$T/src/a/containers" x
  manifest x 'description: no version
port: 80'
  validate a/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown key 'port'"* ]]
  [[ "$output" == *"version: is required"* ]]
  manifest x 'version: 0.1.0
memory: lots'
  validate a/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"memory 'lots' is not a size"* ]]
  manifest x '- a list'
  validate a/x
  [ "$status" -eq 1 ]
  [[ "$output" == *"container.yml is not a YAML map"* ]]
}

@test "a compose mem_limit other than memory: is an error; the same amount is fine" {
  define "$T/src/a/containers" lim 'services:
  app:
    image: docker.io/library/alpine:3
    mem_limit: 1g'
  manifest lim 'version: 0.1.0
memory: 512m'
  validate a/lim
  [ "$status" -eq 1 ]
  [[ "$output" == *"services.app.mem_limit 1g differs from container.yml memory 512m"* ]]
  manifest lim 'version: 0.1.0
memory: 1024m'
  validate a/lim
  [ "$status" -eq 0 ]
}

@test "mem_mib reads compose's sizes" {
  [ "$(mem_mib 512m)" = 512 ]
  [ "$(mem_mib 2g)" = 2048 ]
  [ "$(mem_mib 1.5G)" = 1536 ]
  [ "$(mem_mib 1048576)" = 1 ]
  [ "$(mem_mib 512mb)" = 512 ]
  ! mem_mib lots
}

# --- list and show ------------------------------------------------------------

@test "list: VERSION, - without a container.yml; --json has the manifest's fields" {
  define "$T/src/a/containers" web
  define "$T/src/a/containers" bare
  manifest web 'version: 0.1.2
description: A web server
memory: 256m'
  load_sources
  run cmd_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"a/bare	-	-"* ]]
  [[ "$output" == *"a/web	-	0.1.2"* ]]
  ANFS_TABLE=json run cmd_list
  [[ "$output" == *'"container":"a/web","status":null,"version":"0.1.2","description":"A web server","upstream":null,"license":null,"url":null,"memory":"256m"'* ]]
  [[ "$output" == *'"container":"a/bare","status":null,"version":null'* ]]
}

@test "show: the manifest's fields" {
  define "$T/src/a/containers" web
  manifest web 'version: 0.1.2
license: MIT
url: https://example.com'
  load_sources
  run cmd_show web
  [[ "$output" == *"version      0.1.2"* ]]
  [[ "$output" == *"license      MIT"* ]]
  [[ "$output" == *"url          https://example.com"* ]]
  [[ "$output" != *"description"* ]]
}

# --- memory as the limit ------------------------------------------------------

@test "memory: is every compose service's mem_limit in the override" {
  define "$T/src/a/containers" two 'services:
  app:
    image: docker.io/library/alpine:3
    mem_limit: 2g
  worker:
    image: docker.io/library/alpine:3'
  manifest two 'version: 0.1.0
memory: 512m'
  load_sources
  PCM_ATTACHED_SERVICES=""
  compose_flags a/two
  [ "$(yq '.services.app.mem_limit' "$(override_file a/two)")" = 512m ]
  [ "$(yq '.services.worker.mem_limit' "$(override_file a/two)")" = 512m ]
}

# --- the memory check before up -----------------------------------------------

@test "macOS: room in the machine beside what runs: nothing is touched" {
  OSTYPE=darwin24
  define "$T/src/a/containers" db
  define "$T/src/a/containers" web
  manifest db 'version: 0.1.0
memory: 1g'
  manifest web 'version: 0.1.0
memory: 512m'
  RUNNING="a/db db-1"
  load_sources
  run check_memory a/web
  [ "$status" -eq 0 ]
  ! grep -q "machine stop\|machine set" "$CALLS"
}

@test "macOS: too little with nothing running: resized to the sum plus headroom, then started" {
  OSTYPE=darwin24 PCM_MACHINE_HEADROOM=1024
  define "$T/src/a/containers" big
  manifest big 'version: 0.1.0
memory: 3g'
  load_sources
  run check_memory a/big
  [ "$status" -eq 0 ]
  [[ "$output" == *"resizing it to 4G"* ]]
  called "machine stop"
  called "machine set --memory 4096"
  called "machine start"
}

@test "macOS: too little with something running: refused with the numbers, what stops, the command" {
  OSTYPE=darwin24 PCM_MACHINE_HEADROOM=1024
  define "$T/src/a/containers" db
  define "$T/src/a/containers" big
  manifest db 'version: 0.1.0
memory: 1g'
  manifest big 'version: 0.1.0
memory: 2g'
  RUNNING="a/db db-1"
  load_sources
  run check_memory a/big
  [ "$status" -eq 1 ]
  [[ "$output" == *"need 2G beside the 1G of what runs; the podman machine has 2G"* ]]
  [[ "$output" == *"a resize stops these containers: db-1"* ]]
  [[ "$output" == *"pcm machine resize 4G"* ]]
  ! grep -q "machine stop\|machine set" "$CALLS"
}

@test "a service already running is not counted twice" {
  OSTYPE=darwin24
  define "$T/src/a/containers" db
  manifest db 'version: 0.1.0
memory: 1536m'
  RUNNING="a/db db-1"
  load_sources
  run check_memory a/db
  [ "$status" -eq 0 ]
}

@test "no memory: declared, no check" {
  OSTYPE=darwin24 MEM=1
  define "$T/src/a/containers" plain
  load_sources
  run check_memory a/plain
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ] || ! grep -q "machine" "$CALLS"
}

@test "Linux: what starts must fit in the host's available memory" {
  OSTYPE=linux-gnu AVAIL=1000
  define "$T/src/a/containers" big
  manifest big 'version: 0.1.0
memory: 2g'
  load_sources
  run check_memory a/big
  [ "$status" -eq 1 ]
  [[ "$output" == *"need 2G, the host has 1000M available"* ]]
  AVAIL=4000
  run check_memory a/big
  [ "$status" -eq 0 ]
  ! grep -q "machine" "$CALLS"
}

@test "machine resize: a size given; the default is what runs plus headroom; Linux has none" {
  OSTYPE=darwin24 PCM_MACHINE_HEADROOM=1024
  define "$T/src/a/containers" db
  manifest db 'version: 0.1.0
memory: 1g'
  load_sources
  run cmd_machine_resize 6g
  [ "$status" -eq 0 ]
  called "machine set --memory 6144"
  RUNNING="a/db db-1"
  CLI_OPT[yes]=true
  : > "$CALLS"
  MEM=6144
  run cmd_machine_resize
  [ "$status" -eq 0 ]
  called "machine set --memory 2048"
  [[ "$output" == *"stopped with it: db-1"* ]]
  OSTYPE=linux-gnu
  run cmd_machine_resize 4g
  [ "$status" -eq 1 ]
  [[ "$output" == *"no podman machine on Linux"* ]]
}

@test "machine resize: running containers and no terminal, without -y: nothing done" {
  OSTYPE=darwin24
  define "$T/src/a/containers" db
  manifest db 'version: 0.1.0
memory: 1g'
  RUNNING="a/db db-1"
  load_sources
  CLI_OPT[yes]=false
  run cmd_machine_resize 4g </dev/null
  [ "$status" -eq 1 ]
  ! called "machine set --memory 4096"
}
