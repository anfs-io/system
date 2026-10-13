#!/usr/bin/env bats
# provision.sh: a step is run by the provisioner its extension names; the contract (check,
# fingerprint, run), what run is given, the build key, and pmm's own two (sh, anfs)
load helper

setup() {
  setup_images
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  mkdir -p "$PMM_IMAGES_HOME/d/provision" "$ANFS_ISO_HOME"
  echo iso > "$ANFS_ISO_HOME/a.iso"
  sleep 1; echo "$SHA" > "$ANFS_ISO_HOME/a.iso.sha256"
  wait_ssh() { return 0; }
  # A fixture provisioner for .fix steps, in the person's own directory. $FIX holds what a test
  # tells it (missing: what check prints; extra: more paths for fingerprint; rc: run's exit) and
  # what it saw (env.<step>, work.<step>)
  export FIX="$T/fix"
  mkdir -p "$FIX" "$PMM_CONFIG_HOME/provisioners"
  cat > "$PMM_CONFIG_HOME/provisioners/fix" <<'FIX'
#!/usr/bin/env bash
case "$1" in
  check) [[ ! -f "$FIX/missing" ]] || { cat "$FIX/missing"; exit 1; } ;;
  fingerprint) echo "$2"; [[ ! -f "$FIX/extra" ]] || cat "$FIX/extra" ;;
  run)
    s=$(basename "$2")
    env | grep '^ANFS_IMAGE_' | LC_ALL=C sort > "$FIX/env.$s"
    env | grep -v '^ANFS_IMAGE_' > "$FIX/rest.$s"
    { pwd -P; [[ -d "$ANFS_IMAGE_WORK" ]] && echo work-is-there; } > "$FIX/work.$s"
    echo "fix ran $s"
    $ANFS_IMAGE_GUEST_EXEC id -u
    $ANFS_IMAGE_GUEST_PUSH "$2" /etc/pushed
    echo "on stderr" >&2
    exit "$(cat "$FIX/rc" 2>/dev/null || echo 0)" ;;
esac
FIX
  chmod +x "$PMM_CONFIG_HOME/provisioners/fix"
}

# An ssh that runs the remote command line here, as the shell at the other end would parse it,
# with sudo doing nothing and none of the host's ANFS_IMAGE_*: what the two guest scripts do to
# their arguments, for real
local_ssh() {
  mkdir -p "$T/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'for v in $(compgen -v ANFS_IMAGE_); do unset "$v"; done' \
    'sudo() { while [[ "$1" != -- ]]; do shift; done; shift; "$@"; }' 'eval "${*: -1}"' > "$T/bin/ssh"
  chmod +x "$T/bin/ssh"
  PATH="$T/bin:$PATH"
}

@test "a provisioner is found by the step's extension: the person's own first, then pmm's" {
  [ "$(prov_ext /x/provision/10-base.sh)" = sh ]
  [ "$(prov_ext /x/provision/50-site.tar.yml)" = yml ]
  run prov_ext /x/provision/README
  [ "$status" -ne 0 ]
  [ "$(prov_bin sh)" = "$PMM_LIB_DIR/provisioners/sh" ]
  [ "$(prov_bin anfs)" = "$PMM_LIB_DIR/provisioners/anfs" ]
  [ "$(prov_bin fix)" = "$PMM_CONFIG_HOME/provisioners/fix" ]
  run prov_bin yml
  [ "$status" -ne 0 ]
  printf '#!/bin/sh\n' > "$PMM_CONFIG_HOME/provisioners/sh"; chmod +x "$PMM_CONFIG_HOME/provisioners/sh"
  [ "$(prov_bin sh)" = "$PMM_CONFIG_HOME/provisioners/sh" ]
  # one that cannot be run is not one
  chmod -x "$PMM_CONFIG_HOME/provisioners/sh"
  [ "$(prov_bin sh)" = "$PMM_LIB_DIR/provisioners/sh" ]
}

@test "run: called in the image's directory with every variable of the contract; its output is the step's log" {
  d="$PMM_IMAGES_HOME/d"
  echo 'anything' > "$d/provision/20-x.fix"
  mkdir -p "$d/files"; echo f > "$d/files/f"
  load_images
  run cmd_image_build d
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"== 20-x.fix"*"== finalize"* ]]
  e="$FIX/env.20-x.fix"
  cat "$e"
  grep -qx 'ANFS_IMAGE_NAME=d' "$e"
  grep -qx 'ANFS_IMAGE_ARCH=arm64' "$e"
  grep -qx 'ANFS_IMAGE_BACKEND=qemu' "$e"
  grep -qx 'ANFS_IMAGE_DISTRO=debian' "$e"
  grep -qx 'ANFS_IMAGE_USER=pmm' "$e"
  grep -qx "ANFS_IMAGE_DIR=$d" "$e"
  grep -qx 'ANFS_IMAGE_FILES=/tmp/pmm-files' "$e"
  grep -qx 'ANFS_IMAGE_GUEST_TRANSPORT=ssh' "$e"
  grep -qx 'ANFS_IMAGE_GUEST_HOST=127.0.0.1' "$e"
  grep -qx 'ANFS_IMAGE_GUEST_PORT=42200' "$e"
  grep -qx 'ANFS_IMAGE_GUEST_USER=pmm' "$e"
  grep -qx "ANFS_IMAGE_GUEST_KEY=$PMM_DATA_HOME/keys/d/id_ed25519" "$e"
  grep -qx 'ANFS_IMAGE_SSH_PUBKEY=ssh-ed25519 AAAAstub pmm' "$e"
  grep -q '^ANFS_IMAGE_GUEST_EXEC=/.*[^ ]$' "$e" && ! grep -q '^ANFS_IMAGE_GUEST_EXEC=.* ' "$e"
  grep -q '^ANFS_IMAGE_GUEST_PUSH=/' "$e"
  grep -q '^ANFS_IMAGE_WORK=/' "$e"
  [ "$(wc -l < "$e")" -eq 16 ]
  # nothing of the old names, in what it was given or in what went to the guest
  ! grep -q 'PIM_' "$e" "$FIX/rest.20-x.fix" "$PMM_CALLS"
  # in the image's directory, with a work directory that is gone afterwards
  [ "$(cat "$FIX/work.20-x.fix")" = "$(cd "$d" && pwd -P)"$'\n'work-is-there ]
  [ ! -e "$(sed -n 's/^ANFS_IMAGE_WORK=//p' "$e")" ]
  # the guest, through the two command lines: as root, each argument quoted for the far shell
  grep -qx "ssh sudo -n -- 'id' '-u'" "$PMM_CALLS"
  grep -qxF "ssh sudo -n -- 'sh' '-c' 'mkdir -p \"\$(dirname \"\$1\")\" && cat > \"\$1\"' 'sh' '/etc/pushed'" "$PMM_CALLS"
  # files/ went in before the step, the same way
  grep -n "'/tmp/pmm-files'\|'id' '-u'" "$PMM_CALLS" | head -n1 | grep -q pmm-files
  # stdout and stderr are the log
  log="$PMM_STATE_HOME/logs/d-arm64/provision.log"
  grep -qx '== 20-x.fix' "$log"
  grep -qx '  | fix ran 20-x.fix' "$log"
  grep -qx '  | on stderr' "$log"
  # the build's scripts go with its workspace
  [ ! -e "$PMM_STATE_HOME/build/d-arm64" ]
}

@test "run: a non-zero exit fails the build, with the end of the step's output" {
  echo one > "$PMM_IMAGES_HOME/d/provision/20-x.fix"
  echo 'echo after' > "$PMM_IMAGES_HOME/d/provision/30-after.sh"
  load_images
  echo 7 > "$FIX/rc"
  run cmd_image_build d
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"== 20-x.fix FAILED (exit 7)"* ]]
  [[ "$output" == *"  | fix ran 20-x.fix"* ]]
  [[ "$output" == *"20-x.fix failed; the whole output is in"* ]]
  [[ "$output" != *"30-after.sh"* ]]
  [ -z "$(meta_get d arm64 .cache_key)" ]
  ! ls "$PMM_DATA_HOME"/images/d/arm64/*.qcow2* 2>/dev/null
}

@test "the two guest scripts: arguments arrive as they were given, stdin passes through, push copies a file and a tree" {
  local_ssh
  echo key > "$T/k"; echo pub > "$T/k.pub"
  guest_ssh_qemu "$T/g" "$T/k" 2222 pmm
  x="$T/g/exec" p="$T/g/push"
  [ "$("$x" printf '%s|' "a b" "it's" '$HOME' '"q"' 'x;y' '')" = "a b|it's|\$HOME|\"q\"|x;y||" ]
  [ "$(echo through | "$x" cat)" = through ]
  run "$x" sh -c 'exit 3'
  [ "$status" -eq 3 ]
  mkdir -p "$T/tree/sub dir"; echo one > "$T/tree/a"; echo two > "$T/tree/sub dir/b"
  "$p" "$T/tree" "$T/guest/a tree"
  [ "$(cat "$T/guest/a tree/a" "$T/guest/a tree/sub dir/b" | paste -sd' ' -)" = "one two" ]
  "$p" "$T/tree/a" "$T/guest/etc/file's"
  [ "$(cat "$T/guest/etc/file's")" = one ]
  run "$p" "$T/nosuch" /x
  [ "$status" -eq 64 ]
  # a path with a space cannot be a command line
  run guest_ssh_qemu "$T/a b" "$T/k" 2222 pmm
  [ "$status" -ne 0 ]
  [[ "$output" == *"has a space in it"* ]]
}

@test "fingerprint: a second file it names is in the key, and a tree; an unlisted file is not" {
  d="$PMM_IMAGES_HOME/d"
  echo step > "$d/provision/20-x.fix"
  mkdir -p "$d/roles/web" "$d/notes"
  echo dep > "$T/dep"; echo r > "$d/roles/web/main"; echo n > "$d/notes/n"
  # an absolute path, and one from the image's directory
  printf '%s\nroles\n' "$T/dep" > "$FIX/extra"
  load_images
  local -a keys=()
  k() { keys+=("$(build_key local/d arm64)"); }
  k
  echo changed > "$T/dep"; k
  echo changed > "$d/roles/web/main"; k
  echo new > "$d/roles/web/handlers"; k
  mv "$d/roles/web/handlers" "$d/roles/web/renamed"; k
  echo changed > "$d/provision/20-x.fix"; k
  printf '%s\n' "${keys[@]}"
  [ "$(printf '%s\n' "${keys[@]}" | sort -u | wc -l)" -eq 6 ]
  # what it does not name: a file beside them, the same content, another time
  echo changed > "$d/notes/n"; touch "$T/dep" "$d/roles/web/main"
  [ "$(build_key local/d arm64)" = "${keys[5]}" ]
  # the names it printed are not in the key: the same content somewhere else is the same build
  cp "$T/dep" "$T/dep2"; printf '%s\nroles\n' "$T/dep2" > "$FIX/extra"
  [ "$(build_key local/d arm64)" = "${keys[5]}" ]
  # a provisioner of the same name in pmm's place would be another step
  mv "$d/provision/20-x.fix" "$d/provision/20-y.fix"
  [ "$(build_key local/d arm64)" != "${keys[5]}" ]
}

@test "fingerprint: one that fails, or names a file that is not there, fails the key and the build" {
  d="$PMM_IMAGES_HOME/d"
  echo step > "$d/provision/20-x.fix"
  load_images
  echo "$T/nosuch" > "$FIX/extra"
  run build_key local/d arm64
  [ "$status" -eq 2 ]
  [[ "$output" == *"provision/20-x.fix: its fingerprint names $T/nosuch, which is not there"* ]]
  run cmd_image_validate d
  [ "$status" -eq 0 ]   # the provisioner itself said nothing against the step
  build_one() { build_key "$1" "$2" >/dev/null || die "$1: no build key"; }
  run build_one local/d arm64
  [ "$status" -ne 0 ]
  unset -f build_one; source "$PMM_LIB_DIR/build.sh"
  rm "$FIX/extra"
  printf '#!/bin/sh\n[ "$1" != fingerprint ] || { echo "bad step: no hosts" >&2; exit 1; }\n' > "$PMM_CONFIG_HOME/provisioners/fix"
  run build_key local/d arm64
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad step: no hosts"*"the .fix provisioner's fingerprint failed"* ]]
  run cmd_image_validate d
  [ "$status" -ne 0 ]
  [[ "$output" == *"provision/20-x.fix: bad step: no hosts"* ]]
  run cmd_image_build d
  echo "$output"
  [ "$status" -ne 0 ]
  ! grep -q qemu-system "$PMM_CALLS"
}

@test "validate: a step nothing provides fails, naming the extension; so does one with none, and what check prints" {
  d="$PMM_IMAGES_HOME/d"
  echo '- hosts: all' > "$d/provision/50-site.yml"
  echo x > "$d/provision/README"
  echo step > "$d/provision/20-x.fix"
  : > "$d/provision/30-empty.fix"
  mkdir -p "$d/provision/roles"; echo x > "$d/provision/roles/main.yml"
  echo 'ansible is not installed (ppm install stack/ansible)' > "$FIX/missing"
  load_images
  run cmd_image_validate d
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"provision/50-site.yml: nothing provides .yml steps: install the package that does"* ]]
  [[ "$output" == *"provision/README has no extension: a step's provisioner is its extension"* ]]
  [[ "$output" == *".fix steps: ansible is not installed (ppm install stack/ansible)"* ]]
  [[ "$output" == *"provision/30-empty.fix is empty"* ]]
  [[ "$output" != *"roles"* ]]
  [[ "$output" == *"3 error(s), 1 warning(s)"* ]]
  # and nothing is built from it
  run cmd_image_build d
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing provides .yml steps"* ]]
  ! grep -q qemu-system "$PMM_CALLS"
  # check says nothing: only what nothing provides is left
  rm "$FIX/missing" "$d/provision/README" "$d/provision/50-site.yml"
  run cmd_image_validate d
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 error(s), 1 warning(s)"* ]]
}

@test "steps of mixed provisioners run in name order; a .sh step sees ANFS_IMAGE_* and none of the host's" {
  d="$PMM_IMAGES_HOME/d"
  echo 'echo a' > "$d/provision/10-a.sh"
  echo b > "$d/provision/20-b.fix"
  echo 'echo c' > "$d/provision/30-c.sh"
  echo d > "$d/provision/40-d.fix"
  load_images
  run cmd_image_build d
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"== 10-a.sh"*"== 20-b.fix"*"== 30-c.sh"*"== 40-d.fix"*"== finalize"* ]]
  [ "$(grep -c "'bash' '-s'" "$PMM_CALLS")" -eq 3 ]   # the two scripts and finalize
  sh=$(grep "'bash' '-s'" "$PMM_CALLS" | head -n1)
  echo "$sh"
  [[ "$sh" == "ssh sudo -n -- 'env' "*"'ANFS_IMAGE_ARCH=arm64'"*"'ANFS_IMAGE_FILES='"*"'ANFS_IMAGE_NAME=d'"*"'ANFS_IMAGE_USER=pmm'"*" 'bash' '-s'" ]]
  [[ "$sh" == *"'ANFS_IMAGE_BACKEND=qemu'"*"'ANFS_IMAGE_DISTRO=debian'"* ]]
  [[ "$sh" == *"'ANFS_IMAGE_SSH_PUBKEY=ssh-ed25519 AAAAstub pmm'"* ]]
  [[ "$sh" != *GUEST* && "$sh" != *ANFS_IMAGE_DIR* && "$sh" != *ANFS_IMAGE_WORK* ]]
  # the order they reached the guest in
  [ "$(grep -n "'bash' '-s'\|'id' '-u'" "$PMM_CALLS" | sed "s/.*'id' '-u'.*/fix/; s/.*'bash' '-s'.*/sh/" | paste -sd' ' -)" = "sh fix sh fix sh" ]
}

@test "the sh provisioner: the script reaches bash in the guest as it is, with what it was told" {
  local_ssh
  echo key > "$T/k"; echo pub > "$T/k.pub"
  guest_ssh_qemu "$T/g" "$T/k" 2222 pmm
  printf '%s\n' 'echo "name=$ANFS_IMAGE_NAME files=$ANFS_IMAGE_FILES key=$ANFS_IMAGE_SSH_PUBKEY dir=${ANFS_IMAGE_DIR:-unset} exec=${ANFS_IMAGE_GUEST_EXEC:-unset}"' 'exit 4' > "$T/s.sh"
  run env ANFS_IMAGE_GUEST_EXEC="$T/g/exec" ANFS_IMAGE_NAME="a b" ANFS_IMAGE_FILES= ANFS_IMAGE_SSH_PUBKEY="ssh-ed25519 AAA it's" \
    ANFS_IMAGE_DIR=/host ANFS_IMAGE_WORK=/host/w "$PMM_LIB_DIR/provisioners/sh" run "$T/s.sh"
  echo "$output"
  [ "$status" -eq 4 ]
  [ "$output" = "name=a b files= key=ssh-ed25519 AAA it's dir=unset exec=unset" ]
  [ "$("$PMM_LIB_DIR/provisioners/sh" fingerprint "$T/s.sh")" = "$T/s.sh" ]
  run "$PMM_LIB_DIR/provisioners/sh" check
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run "$PMM_LIB_DIR/provisioners/sh" frobnicate
  [ "$status" -ne 0 ]
}

# A source that is a git repository with one commit
git_source() {
  add_source "$1"
  git -C "$T/srcs/$1" init -q
  echo one > "$T/srcs/$1/f"
  commit "$1" one
}
commit() { git -C "$T/srcs/$1" add -A && git -C "$T/srcs/$1" -c user.name=t -c user.email=t@t commit -q -m "$2"; }

@test "the anfs step, host mode: the key changes when a source gains a commit, or a change; pushed mode's does not" {
  git_source s1
  d="$PMM_IMAGES_HOME/d"
  echo 'sources: host' > "$d/provision/50-toolkit.anfs"
  load_images
  run cmd_image_validate d
  echo "$output"
  [ "$status" -eq 0 ]
  k1=$(build_key local/d arm64)
  [ "$(build_key local/d arm64)" = "$k1" ]
  echo two > "$T/srcs/s1/f"
  k2=$(build_key local/d arm64)
  [ "$k2" != "$k1" ]
  commit s1 two
  k3=$(build_key local/d arm64)
  [ "$k3" != "$k2" ] && [ "$k3" != "$k1" ]
  # another source is another build
  git_source s2
  [ "$(build_key local/d arm64)" != "$k3" ]
  # pushed: the guest clones them, so what the host has is not part of it
  echo 'sources: pushed' > "$d/provision/50-toolkit.anfs"
  k4=$(build_key local/d arm64)
  echo three > "$T/srcs/s1/f"; commit s1 three
  [ "$(build_key local/d arm64)" = "$k4" ]
  echo 'sources: sideways' > "$d/provision/50-toolkit.anfs"
  run cmd_image_validate d
  [ "$status" -ne 0 ]
  [[ "$output" == *"provision/50-toolkit.anfs: anfs: 50-toolkit.anfs: sources must be host or pushed, not 'sideways'"* ]]
}

@test "the anfs provisioner: runs on the host, and reaches the guest only through what it is given" {
  git_source s1
  # a guest that is not ssh: the two command lines log what they are asked, and answer for ~u
  printf '%s\n' '#!/bin/sh' 'echo "exec $*" >> "$FIX/guest"' 'case "$*" in "sh -c echo ~u") echo /home/u ;; su*) cat > "$FIX/script" ;; esac' > "$T/gexec"
  printf '%s\n' '#!/bin/sh' 'echo "push $*" >> "$FIX/guest"' > "$T/gpush"
  chmod +x "$T/gexec" "$T/gpush"
  mkdir -p "$T/work"
  anfs() { env ANFS_IMAGE_GUEST_EXEC="$T/gexec" ANFS_IMAGE_GUEST_PUSH="$T/gpush" ANFS_IMAGE_GUEST_TRANSPORT=buildah \
    ANFS_IMAGE_USER=u ANFS_IMAGE_WORK="$T/work" "$PMM_LIB_DIR/provisioners/anfs" "$@"; }
  printf 'sources: host\nrepo: git@x:me/dots.git\npackages: [stack/zsh, stack/git]\n' > "$T/50-kit.anfs"
  run anfs check
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run anfs fingerprint "$T/50-kit.anfs"
  [ "$status" -eq 0 ]
  [ "$output" = "$T/50-kit.anfs"$'\n'"$T/work/sources" ]
  [[ "$(cat "$T/work/sources")" =~ ^s1\ [0-9a-f]{40}\ [0-9a-f]{12}$ ]]
  run anfs run "$T/50-kit.anfs"
  echo "$output"; cat "$FIX/guest" "$FIX/script"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copying source s1"*"anfs install (host: stack/zsh stack/git)"* ]]
  src=$(cd "$T/srcs/s1" && pwd -P)
  [ "$(cat "$FIX/guest")" = "exec sh -c echo ~u
push $src /home/u/.local/share/anfs/sources/s1
exec chown -R u: /home/u/.local
exec su -l u -c bash -l -s" ]
  grep -qx "bash ~/.local/share/anfs/sources/core/install.sh --repo 'git@x:me/dots.git' stack/zsh stack/git" "$FIX/script"
  grep -qxF '$HOME/.local/share/anfs/sources/s1  s1' "$FIX/script"
  # pushed: nothing is copied; install.sh is fetched in the guest, from where the step says
  : > "$FIX/guest"
  printf 'installer: https://x/install.sh\n' > "$T/50-kit.anfs"
  [ "$(anfs fingerprint "$T/50-kit.anfs")" = "$T/50-kit.anfs" ]
  run anfs run "$T/50-kit.anfs"
  [ "$status" -eq 0 ]
  [ "$(cat "$FIX/guest")" = "exec su -l u -c bash -l -s" ]
  grep -qx "curl -fsSL 'https://x/install.sh' | bash -s --" "$FIX/script"
  # a guest without the user
  printf '%s\n' '#!/bin/sh' 'echo "~u"' > "$T/gexec"
  printf 'sources: host\n' > "$T/50-kit.anfs"
  run anfs run "$T/50-kit.anfs"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the guest has no user 'u'"* ]]
}

@test "tart: the steps are root through an askpass helper pmm installs first and removes after the last" {
  mkdir -p "$HOME/.tart"
  m="$PMM_IMAGES_HOME/m"
  mkdir -p "$m/provision" "$m/files"
  printf 'backend: tart\ndistro: macos\narch: [arm64]\nbase: base-vm\nuser: {name: owner, bootstrap: {name: admin, password: s3cret}}\n' > "$m/image.yml"
  echo 'echo p' > "$m/provision/10-p.sh"; echo x > "$m/provision/20-x.fix"; echo f > "$m/files/f"
  echo stopped > "$TART_STUB/base-vm"
  _tart_shutdown() { kill "$2" 2>/dev/null || true; command sleep 0.2; }
  sleep() { [[ "$1" == 20 ]] || command sleep "$@"; }   # the wait for the reboot
  load_images
  run cmd_image_build m
  echo "$output"; cat "$PMM_CALLS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"== 10-p.sh"*"== 20-x.fix"*"Rebooting"* ]]
  key=$(meta_get m arm64 .cache_key)
  [ -f "$TART_STUB/pmm-image-m-$key" ]
  # the helper goes in, every step is root through it, and it comes out before the reboot
  [ "$(grep -n 'pmm-askpass\|shutdown -r' "$PMM_CALLS" | sed -E "s/^[0-9]+:ssh //; s/^umask.*/install/; s/^SUDO_ASKPASS=\/tmp\/pmm-askpass sudo -A -- .*tar -C.*/files/; s/^SUDO_ASKPASS=\/tmp\/pmm-askpass sudo -A -- .*'bash' '-s'$/sh/; s/^SUDO_ASKPASS=\/tmp\/pmm-askpass sudo -A -- 'id' '-u'$/fix/; s/^SUDO_ASKPASS=\/tmp\/pmm-askpass sudo -A -- 'sh' '-c'.*pushed'$/fix-push/; s/^SUDO_ASKPASS=\/tmp\/pmm-askpass sudo -A -- 'rm' '-rf' '\/tmp\/pmm-files'$/files-out/; s/^rm -f \/tmp\/pmm-askpass$/remove/; s/.*shutdown -r.*/reboot/" | paste -sd' ' -)" = "install files sh fix fix-push files-out remove reboot" ]
  # the provisioner is told how to be root, never the password
  e="$FIX/env.20-x.fix"
  ! grep -q s3cret "$e" "$FIX/rest.20-x.fix"
  ! grep -rq s3cret "$PMM_STATE_HOME"
  grep -qx 'ANFS_IMAGE_BACKEND=tart' "$e"
  grep -qx 'ANFS_IMAGE_USER=owner' "$e"
  grep -qx 'ANFS_IMAGE_GUEST_USER=admin' "$e"
  grep -qx 'ANFS_IMAGE_GUEST_HOST=192.168.64.9' "$e"
  grep -qx 'ANFS_IMAGE_FILES=/tmp/pmm-files' "$e"
  grep -qx 'ANFS_IMAGE_SSH_PUBKEY=ssh-ed25519 AAAAstub pmm' "$e"
  [ ! -e "$PMM_STATE_HOME/build/m-arm64" ]
}

@test "nothing in the repository names a PIM_ variable" {
  run grep -rn 'PIM_' "$BATS_TEST_DIRNAME/../../.." --exclude-dir=.git --exclude=provision.bats
  echo "$output"
  [ "$status" -ne 0 ]
}
