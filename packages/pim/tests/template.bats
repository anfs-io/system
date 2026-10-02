#!/usr/bin/env bats
# template.sh: ${VAR} substitution in answer files
load helper

setup() { setup_pim; }

@test "render: substitutes, keeps other \$ forms, and \$\${X} is a literal \${X}" {
  tpl_set USER pim
  tpl_set HASH '$6$salt$a&b/c\d"e'
  printf '%s\n' 'user ${USER} pw ${HASH}' 'url $releasever&arch=$basearch $(cmd) $$ $' 'lit $${USER} end' > "$T/t"
  run render "$T/t"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'user pim pw $6$salt$a&b/c\d"e' ]
  [ "${lines[1]}" = 'url $releasever&arch=$basearch $(cmd) $$ $' ]
  [ "${lines[2]}" = 'lit ${USER} end' ]
}

@test "render: an unknown variable fails naming the file and line" {
  printf 'a\nb ${NOPE}\n' > "$T/t"
  run render "$T/t"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$T/t:2: unknown variable \${NOPE}"* ]]
}

@test "render: a value is inserted as text, never evaluated" {
  tpl_set X '${Y} $(touch '"$T"'/pwned)'
  printf '${X}\n' > "$T/t"
  run render "$T/t"
  [ "$output" = '${Y} $(touch '"$T"'/pwned)' ]
  [ ! -e "$T/pwned" ]
}

@test "tpl_load: defaults, then vars:, then built-ins that vars: cannot override" {
  image "$PIM_IMAGES_HOME/d" "$(deb_yml 'vars: {HOSTNAME: box, TIMEZONE: Asia/Singapore, USER: evil}
user: {name: dev}')"
  load_sources
  echo "ssh-ed25519 AAAA k" > "$T/k.pub"
  tpl_load local/d arm64 "$T/k.pub"
  [ "$(tpl_get HOSTNAME)" = box ]
  [ "$(tpl_get TIMEZONE)" = Asia/Singapore ]
  [ "$(tpl_get LOCALE)" = en_US.UTF-8 ]
  [ "$(tpl_get USER)" = dev ]
  [ "$(tpl_get PASSWORD_HASH)" = '!' ]
  [ "$(tpl_get KS_PASSWORD)" = --lock ]
  [ "$(tpl_get SSH_PUBKEY)" = "ssh-ed25519 AAAA k" ]
}

@test "the default answer files render with the default variables" {
  image "$PIM_IMAGES_HOME/d" "$(deb_yml)"
  load_sources
  echo "ssh-ed25519 AAAA k" > "$T/k.pub"
  tpl_load local/d arm64 "$T/k.pub"
  render "$PIM_LIB_DIR/defaults/debian/preseed.cfg" > "$T/p"
  grep -q 'passwd/username string pim' "$T/p"
  render "$PIM_LIB_DIR/defaults/fedora/kickstart.ks" > "$T/k"
  grep -q 'sshkey --username=pim "ssh-ed25519 AAAA k"' "$T/k"
  grep -q 'repo=fedora-$releasever&arch=$basearch' "$T/k"
}
