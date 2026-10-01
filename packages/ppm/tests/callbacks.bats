#!/usr/bin/env bats
# Post-run callbacks (ppm_register_callback) and the `meta:` package.yml key.
# ppm's core libs are sourced from this clone, with sources and state redirected into the temp dir.
# Run: bats packages/ppm/tests/

setup() {
  local lib="$BATS_TEST_DIRNAME/../home/.local/lib/ppm"

  ANFS_SOURCES_HOME="$BATS_TEST_TMPDIR/sources"
  PPM_INSTALLED_DIR="$BATS_TEST_TMPDIR/state/installed"
  mkdir -p "$PPM_INSTALLED_DIR"

  # shellcheck source=/dev/null
  source "$lib/core.sh"
  source "$lib/packages.sh"
  source "$lib/installer.sh"

  CALLS="$BATS_TEST_TMPDIR/calls"
}

messages() { cat "$PPM_MSG_FILE" 2>/dev/null; }

# An installed package whose install.sh defines <fn>, which logs its arguments to $CALLS
# Usage: subscriber <repo> <pkg> <fn>
subscriber() {
  local dir="$ANFS_SOURCES_HOME/$1/packages/$2"
  mkdir -p "$dir" "$PPM_INSTALLED_DIR/$1"
  echo "version: 0.1.0" > "$PPM_INSTALLED_DIR/$1/$2.yml"
  cat > "$dir/install.sh" <<EOF
$3() { echo "\$PPM_CURRENT_PACKAGE \$*" >> "$CALLS"; }
EOF
}

register() {
  PPM_CURRENT_PACKAGE="$1" ppm_register_callback "$2"
}

@test "register records repo/pkg: function, and re-registering replaces it" {
  register ai/psm first
  register ai/psm psm_changed
  register pde/other other_changed

  run yq -r '.["ai/psm"]' "$PPM_INSTALLED_DIR/callbacks.yml"
  [ "$output" = "psm_changed" ]
  run yq -r 'keys | length' "$PPM_INSTALLED_DIR/callbacks.yml"
  [ "$output" = "2" ]
}

@test "register outside a package hook fails" {
  PPM_CURRENT_PACKAGE="" run ppm_register_callback fn
  [ "$status" -eq 1 ]
  [ ! -f "$PPM_INSTALLED_DIR/callbacks.yml" ]
}

@test "unregister drops only that package" {
  register ai/psm a
  register pde/other b
  PPM_CURRENT_PACKAGE=ai/psm ppm_unregister_callback

  run yq -r 'keys | .[]' "$PPM_INSTALLED_DIR/callbacks.yml"
  [ "$output" = "pde/other" ]
}

@test "callbacks get the event and every package, as their own package" {
  subscriber ai psm psm_changed
  register ai/psm psm_changed

  _run_callbacks install ai/claude ai/node ai/psm

  run cat "$CALLS"
  [ "$output" = "ai/psm install ai/claude ai/node ai/psm" ]
}

@test "every subscriber is called once" {
  subscriber ai psm a
  subscriber pde other b
  register ai/psm a
  register pde/other b

  _run_callbacks remove ai/pi

  run cat "$CALLS"
  [ "${lines[0]}" = "ai/psm remove ai/pi" ]
  [ "${lines[1]}" = "pde/other remove ai/pi" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "nothing runs with -c or an empty list" {
  subscriber ai psm a
  register ai/psm a

  config=true _run_callbacks install ai/pi
  _run_callbacks remove

  [ ! -f "$CALLS" ]
}

@test "a subscriber that is not installed is skipped" {
  subscriber ai psm a
  register ai/psm a
  rm "$PPM_INSTALLED_DIR/ai/psm.yml"

  _run_callbacks install ai/pi

  [ ! -f "$CALLS" ]
}

@test "an undefined or failing callback is reported and the others still run" {
  subscriber ai psm a
  subscriber pde broken b
  subscriber pde other c
  echo 'b() { return 3; }' >> "$ANFS_SOURCES_HOME/pde/packages/broken/install.sh"
  register ai/psm missing_fn
  register pde/broken b
  register pde/other c

  _run_callbacks install ai/pi 2>/dev/null

  run cat "$CALLS"
  [ "$output" = "pde/other install ai/pi" ]
  run messages
  [[ "$output" == *"[ai/psm] ERROR: registered callback 'missing_fn' is not defined"* ]]
  [[ "$output" == *"[pde/broken] ERROR: callback 'b' failed"* ]]
}

@test "meta is a core key, not a declared resource" {
  local pkg="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$pkg"
  printf 'version: 0.1.0\nmeta:\n  agent: pi\nwsm: []\n' > "$pkg/package.yml"

  run meta_extra_keys "$pkg"
  [ "$output" = "wsm" ]
}
