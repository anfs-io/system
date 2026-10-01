#!/usr/bin/env bats
# Validation rules that need neither podman nor varlock: definitions here use no variables.
# Run: bats packages/pcm/tests/

load helper

setup() {
  pcm_setup
  add_source a
}

# Validate service id $1 in the current shell; the errors are in $output via run
validate() {
  load_sources
  run validate_services "$@"
}

@test "a plain definition is valid" {
  define "$T/src/a/containers" plain
  validate a/plain
  [ "$status" -eq 0 ]
}

@test "variables without an .env.schema are an error" {
  define "$T/src/a/containers" vars 'services:
  app:
    image: ${IMAGE}'
  validate a/vars
  [ "$status" -eq 1 ]
  [[ "$output" == *"uses variables but there is no .env.schema"* ]]
}

@test "volumes: bind under PCM_VOLUMES_HOME/<name> is fine, anything else is an error" {
  define "$T/src/a/containers" vols "services:
  app:
    image: docker.io/library/alpine:3
    volumes:
      - $PCM_VOLUMES_HOME/vols/data:/data
      - ./conf:/conf:ro
      - named:/named
      - /anon
      - /etc:/host-etc
      - ./rw:/rw"
  validate a/vols
  [ "$status" -eq 1 ]
  [[ "$output" != *"/data"* ]]
  [[ "$output" != *"/conf"* ]]
  [[ "$output" == *"named volume 'named'"* ]]
  [[ "$output" == *"anonymous volume"* ]]
  [[ "$output" == *"'/etc' is outside"* ]]
  [[ "$output" == *"'./rw' is outside"* ]]
}

@test "volumes: the rule uses the name, not the source" {
  define "$T/src/a/containers" pg "services:
  db:
    image: docker.io/library/alpine:3
    volumes:
      - $PCM_VOLUMES_HOME/pg:/var/lib/data"
  validate a/pg
  [ "$status" -eq 0 ]
}

@test "depends_on: unknown dependency is an error" {
  define "$T/src/a/containers" app 'services:
  app:
    image: docker.io/library/alpine:3
x-pcm:
  depends_on: [ghost]'
  validate a/app
  [[ "$output" == *"unknown service 'ghost'"* ]]
}

@test "depends_on: the same name twice is an error" {
  add_source b
  define "$T/src/a/containers" db
  define "$T/src/b/containers" db
  define "$T/src/a/containers" app 'services:
  app:
    image: docker.io/library/alpine:3
x-pcm:
  depends_on:
    db: {}
    b/db: {}'
  validate a/app
  [[ "$output" == *"depends on 'db' twice"* ]]
}

@test "depends_on: a cycle is an error" {
  define "$T/src/a/containers" one 'services:
  app:
    image: docker.io/library/alpine:3
x-pcm:
  depends_on: [two]'
  define "$T/src/a/containers" two 'services:
  app:
    image: docker.io/library/alpine:3
x-pcm:
  depends_on: [one]'
  validate a/one
  [[ "$output" == *"dependency cycle"* ]]
}

@test "dependencies resolve by priority, and dependents are found" {
  add_source b
  define "$T/src/b/containers" db
  define "$PCM_CONTAINERS_HOME" db
  define "$T/src/a/containers" app 'services:
  app:
    image: docker.io/library/alpine:3
x-pcm:
  depends_on: [db]'
  load_sources
  [ "$(dep_ids a/app)" = "local/db" ]
  [ "$(service_dependents local/db)" = "a/app" ]
}

@test "dependents are found when the dependency is not the last one listed" {
  define "$T/src/a/containers" db
  define "$T/src/a/containers" cache
  define "$T/src/a/containers" app 'services:
  app:
    image: docker.io/library/alpine:3
x-pcm:
  depends_on: [db, cache]'
  load_sources
  [ "$(service_dependents a/db)" = "a/app" ]
  [ "$(service_dependents a/cache)" = "a/app" ]
}
