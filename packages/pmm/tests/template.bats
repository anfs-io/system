#!/usr/bin/env bats
# template.sh: ${VAR} substitution in answer files
load helper

setup() { setup_images; }

@test "render: substitutes, keeps other \$ forms, and \$\${X} is a literal \${X}" {
  tpl_set USER pmm
  tpl_set HASH '$6$salt$a&b/c\d"e'
  printf '%s\n' 'user ${USER} pw ${HASH}' 'url $releasever&arch=$basearch $(cmd) $$ $' 'lit $${USER} end' > "$T/t"
  run render "$T/t"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 'user pmm pw $6$salt$a&b/c\d"e' ]
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

@test "tpl_load: vars:, then what pmm sets, which vars: cannot override; nothing else has a default" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml 'vars: {HOSTNAME: box, TIMEZONE: Asia/Singapore, USER: evil, HTTP_PROXY: "", N: 3, EMPTY:}
user: {name: dev}')"
  image "$PMM_IMAGES_HOME/e" "$(deb_yml)"
  load_images
  echo "ssh-ed25519 AAAA k" > "$T/k.pub"
  tpl_load local/d arm64 "$T/k.pub"
  [ "$(tpl_get HOSTNAME)" = box ]
  [ "$(tpl_get TIMEZONE)" = Asia/Singapore ]
  [ "$(tpl_get N)" = 3 ]
  tpl_get HTTP_PROXY && [ -z "$(tpl_get HTTP_PROXY)" ]
  tpl_get EMPTY && [ -z "$(tpl_get EMPTY)" ]
  ! tpl_get LOCALE
  [ "$(tpl_get USER)" = dev ]
  [ "$(tpl_get PASSWORD_HASH)" = '!' ]
  [ "$(tpl_get KS_PASSWORD)" = --lock ]
  [ "$(tpl_get SSH_PUBKEY)" = "ssh-ed25519 AAAA k" ]
  [ "$(tpl_get IMAGE)" = d ] && [ "$(tpl_get ARCH)" = arm64 ]
  # a value with lines of its own is one variable, whatever its lines look like
  printf 'vars:\n  RECIPE: |\n    one\n    X=two\n' >> "$PMM_IMAGES_HOME/e/image.yml"
  tpl_load local/e arm64 "$T/k.pub"
  [ "$(tpl_get RECIPE)" = "one"$'\n'"X=two" ]
  ! tpl_get X
  # one image's variables are not the next one's; HOSTNAME is the image's name unless set
  tpl_load local/e arm64 "$T/k.pub"
  ! tpl_get TIMEZONE
  [ "$(tpl_get HOSTNAME)" = e ]
}

@test "the shipped answer files render with their own image's vars:, and with nothing from pmm's library" {
  core_source
  load_images
  echo "ssh-ed25519 AAAA k" > "$T/k.pub"
  tpl_load core/debian-13 arm64 "$T/k.pub"
  render "$(img_answer_file core/debian-13)" > "$T/p"
  grep -q 'passwd/username string pmm' "$T/p"
  grep -q 'mirror/http/hostname string deb.debian.org' "$T/p"
  grep -q 'mirror/http/proxy string $' "$T/p"
  grep -q 'tasksel/first multiselect standard, ssh-server' "$T/p"
  tpl_load core/fedora-44 arm64 "$T/k.pub"
  render "$(img_answer_file core/fedora-44)" > "$T/k"
  grep -q 'sshkey --username=pmm "ssh-ed25519 AAAA k"' "$T/k"
  grep -q 'repo=fedora-$releasever&arch=$basearch' "$T/k"
  grep -q -- '--hostname=fedora' "$T/k"
  # a variable its image.yml does not set is an error, not a default: Debian's file, Fedora's vars
  run render "$(img_answer_file core/debian-13)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown variable \${DOMAIN}"* ]]
}
