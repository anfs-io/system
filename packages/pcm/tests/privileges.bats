#!/usr/bin/env bats
# What a definition may ask for beyond the default isolation, and what pcm generates for it:
# x-pcm.privileges (declared, with reasons), x-pcm.mounts (generated mount sets) and the image a
# snapshot pins. podman is stubbed (helper.bash), so nothing runs.
# Run: bats packages/pcm/tests/

load helper

setup() {
  pcm_setup
  add_source a
}

validate() {
  load_sources
  run validate_services "$@"
}

@test "privileges: an elevated key nobody declared is an error" {
  define "$T/src/a/containers" box 'services:
  box:
    image: docker.io/library/alpine:3
    privileged: true
    devices: [/dev/fuse]'
  validate a/box
  [ "$status" -ne 0 ]
  [[ "$output" == *"services.box uses privileged; declare it"* ]]
  [[ "$output" == *"services.box uses devices; declare it"* ]]
}

@test "privileges: declared with reasons, it is valid" {
  define "$T/src/a/containers" box 'x-pcm:
  privileges:
    privileged: "runs podman inside"
    devices: "/dev/fuse for overlay storage"
services:
  box:
    image: docker.io/library/alpine:3
    privileged: true
    devices: [/dev/fuse]'
  validate a/box
  [ "$status" -eq 0 ]
}

@test "privileges: host namespaces count, the default ones do not" {
  define "$T/src/a/containers" net 'services:
  app:
    image: docker.io/library/alpine:3
    network_mode: host'
  define "$T/src/a/containers" plain 'services:
  app:
    image: docker.io/library/alpine:3
    network_mode: bridge'
  validate a/net
  [ "$status" -ne 0 ]
  [[ "$output" == *"uses network_mode"* ]]
  validate a/plain
  [ "$status" -eq 0 ]
}

@test "privileges: an unknown key or a missing reason is an error; an unused one a warning" {
  define "$T/src/a/containers" box 'x-pcm:
  privileges:
    root: "because"
    cap_add: ""
    privileged: "not used"
services:
  box:
    image: docker.io/library/alpine:3
    cap_add: [NET_ADMIN]'
  validate a/box
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown privilege 'root'"* ]]
  [[ "$output" == *"x-pcm.privileges.cap_add: give the reason"* ]]
  [[ "$output" == *"warning: x-pcm.privileges.privileged is declared but no service uses it"* ]]
}

@test "mounts: an unknown set, a relative target or an unknown service is an error" {
  define "$T/src/a/containers" box 'x-pcm:
  mounts:
    - set: everything
      target: /src
    - set: anfs-sources
      target: src
    - set: anfs-sources
      target: /src
      service: nope
services:
  box:
    image: docker.io/library/alpine:3'
  validate a/box
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown set 'everything'"* ]]
  [[ "$output" == *"target must be an absolute path"* ]]
  [[ "$output" == *"no service 'nope'"* ]]
}

@test "mounts: anfs-sources mounts every source at <target>/<alias>, resolved, read-only" {
  add_source b
  define "$T/src/a/containers" box 'x-pcm:
  mounts:
    - set: anfs-sources
      target: /src
services:
  box:
    image: docker.io/library/alpine:3
  other:
    image: docker.io/library/alpine:3'
  load_sources
  compose_flags a/box
  run cat "$(override_file a/box)"
  local a b
  a=$(cd -P "$T/src/a" && pwd); b=$(cd -P "$T/src/b" && pwd)
  [[ "$output" == *"- \"$a:/src/a:ro\""* ]]
  [[ "$output" == *"- \"$b:/src/b:ro\""* ]]
  # No service named: every compose service gets them
  [ "$(grep -c "$a:/src/a:ro" "$(override_file a/box)")" -eq 2 ]
}

@test "mounts: readonly false and a single service" {
  define "$T/src/a/containers" box 'x-pcm:
  mounts:
    - set: anfs-sources
      target: /work/
      service: box
      readonly: false
services:
  box:
    image: docker.io/library/alpine:3
  other:
    image: docker.io/library/alpine:3'
  load_sources
  compose_flags a/box
  local a
  a=$(cd -P "$T/src/a" && pwd)
  [ "$(grep -c "\"$a:/work/a\"" "$(override_file a/box)")" -eq 1 ]
}

@test "snapshot: the active snapshot's image is pinned in the override" {
  define "$T/src/a/containers" db
  mkdir -p "$PCM_STATE_HOME/snapshots/db"
  echo "app localhost/pcm-snapshot/db-app:before" > "$PCM_STATE_HOME/snapshots/db/before"
  load_sources
  compose_flags a/db
  ! grep -q 'image:' "$(override_file a/db)"

  echo before > "$PCM_STATE_HOME/snapshots/db/active"
  compose_flags a/db
  grep -q 'image: "localhost/pcm-snapshot/db-app:before"' "$(override_file a/db)"
}
