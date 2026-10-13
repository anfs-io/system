#!/usr/bin/env bash
# pmm library: provisioners — what runs a provision step. Sourced by ~/.local/bin/pmm; functions only.
#
# The provisioner of provision/<NN>-<name>.<ext> is <ext>: an executable,
# $PMM_CONFIG_HOME/provisioners/<ext> or pmm's own provisioners/<ext> (where another package
# stows one too), called with a verb:
#   check                prints what is missing on the host (a binary, a version) and fails;
#                        nothing printed is ready. Run by validate
#   fingerprint <step>   prints, one per line, the files the step's result depends on, the step
#                        first; a directory is the tree under it. pmm hashes them into the build
#                        key. Failing fails validate and the build
#   run <step>           runs the step against the guest. Its output is the step's log; a
#                        non-zero exit fails the build
# pmm ships sh and anfs. Every verb runs in the image's directory with what is being built:
#   ANFS_IMAGE_NAME, _ARCH, _BACKEND, _DISTRO, _USER (the image's user), _DIR (the definition)
#   ANFS_IMAGE_WORK         an empty directory for the call's own files; deleted after it
# and run with the guest, as a way to run something in it rather than an ssh session, so the same
# provisioner works wherever the guest is:
#   ANFS_IMAGE_GUEST_EXEC   a command line that runs its arguments as root in the guest, stdin
#                           passed through (unquoted: $ANFS_IMAGE_GUEST_EXEC id -u)
#   ANFS_IMAGE_GUEST_PUSH   a command line that copies a local path to an absolute guest path, as
#                           root: a file, or a directory's contents into that directory
#   ANFS_IMAGE_GUEST_TRANSPORT   ssh, and with it ANFS_IMAGE_GUEST_HOST, _PORT, _USER and _KEY,
#                           for a provisioner that brings its own connection
#   ANFS_IMAGE_FILES        where files/ is in the guest; empty when the image has none
#   ANFS_IMAGE_SSH_PUBKEY   the image's public key
# The two command lines are scripts pmm writes for the build (guest_ssh, ssh.sh). They hide what
# differs between backends: a qemu guest's user has passwordless sudo, a tart guest's stock
# account needs its password (tart.sh), and a provisioner sees neither.
#
# pmm keeps the order of the steps, pushing files/, the log (_provision) and finalize.

# The provisioner a step file names: its extension. Fails for a file with none
prov_ext() {
  local b
  b=$(basename "$1")
  [[ "$b" == *.* && -n "${b##*.}" ]] && echo "${b##*.}"
}

# Path of provisioner $1
prov_bin() {
  local dir
  for dir in "$PMM_CONFIG_HOME/provisioners" "$PMM_LIB_DIR/provisioners"; do
    [[ -f "$dir/$1" && -x "$dir/$1" ]] && { echo "$dir/$1"; return 0; }
  done
  return 1
}

# The provisioner of <step>, as a path; says why not on stderr
prov_for() {
  local ext
  ext=$(prov_ext "$1") || { warn "provision/$(basename "$1") has no extension: a step's provisioner is its extension (10-base.sh)"; return 1; }
  prov_bin "$ext" || { warn "provision/$(basename "$1"): nothing provides .$ext steps: install the package that does"; return 1; }
}

# What is being built, as a provisioner is told: sets PROV_ENV (NAME=value...) and PROV_DIR, the
# image's directory
# Usage: prov_image_env <id> <arch>
prov_image_env() {
  local id="$1" arch="$2" distro user
  distro=$(img_distro "$id" 2>/dev/null) || distro=""
  user=$(img_user "$id" 2>/dev/null) || user=""
  PROV_DIR=$(img_dir "$id")
  PROV_ENV=("ANFS_IMAGE_NAME=$(img_name "$id")" "ANFS_IMAGE_ARCH=$arch" "ANFS_IMAGE_BACKEND=$(img_backend "$id")"
            "ANFS_IMAGE_DISTRO=$distro" "ANFS_IMAGE_USER=$user" "ANFS_IMAGE_DIR=$PROV_DIR")
}

# Call <step>'s provisioner with <verb>, as PROV_ENV says, in the image's directory. Its stdin is
# empty: a build reads its list of steps from its own
# Usage: prov_call <verb> <step>
prov_call() {
  local verb="$1" step="$2" bin work rc=0
  bin=$(prov_for "$step") || return 1
  work=$(mktemp -d "${TMPDIR:-/tmp}/pmm-step.XXXXXX")
  ( cd "$PROV_DIR" &&
    env "${PROV_ENV[@]}" ANFS_IMAGE_WORK="$work" "$bin" "$verb" "$step" < /dev/null ) || rc=$?
  rm -rf "$work"
  return $rc
}

# Run <step> against the guest (PROV_ENV with the guest's part: guest_ssh); its output prefixed
# Usage: prov_run <step>
prov_run() {
  prov_call run "$1" 2>&1 | sed 's/^/  | /'
  return "${PIPESTATUS[0]}"
}

# The build key's lines for <id>'s steps, in order: the step and its provisioner, then the sha256
# of each file its fingerprint names (a directory: of each file under it, with its path there).
# The names it printed are not in the key, so a file it wrote for the purpose may be anywhere.
# Fails, saying why, for a step nothing provides or whose fingerprint fails.
# Usage: key_steps <id> <arch>
key_steps() {
  local id="$1" arch="$2" dir s bin work out p f rc=0
  prov_image_env "$id" "$arch"
  dir="$PROV_DIR"
  while IFS= read -r s; do
    bin=$(prov_for "$s") || return 2
    echo "step $(basename "$s") $(prov_ext "$s")"
    work=$(mktemp -d "${TMPDIR:-/tmp}/pmm-step.XXXXXX")
    if out=$(cd "$dir" && env "${PROV_ENV[@]}" ANFS_IMAGE_WORK="$work" "$bin" fingerprint "$s" < /dev/null); then
      while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ "$p" == /* ]] || p="$dir/$p"
        if [[ -d "$p" ]]; then
          (cd "$p" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do echo "$f $(_sha256 < "$f")"; done)
        elif [[ -f "$p" ]]; then
          _sha256 < "$p"
        else
          warn "provision/$(basename "$s"): its fingerprint names $p, which is not there"; rc=2; break
        fi
      done <<< "$out"
    else
      warn "provision/$(basename "$s"): the .$(prov_ext "$s") provisioner's fingerprint failed"; rc=2
    fi
    rm -rf "$work"
    [[ $rc -eq 0 ]] || return $rc
  done < <(img_steps "$id")
  return 0
}

# Run <id>'s own steps in the guest, in name order, after copying its files/ there. PROV_ENV has
# what is being built and the guest (prov_image_env, guest_ssh).
# Usage: provision_steps <id> <log>
provision_steps() {
  local id="$1" log="$2" files="" s
  local -a steps=()
  if [[ -d "$(img_dir "$id")/files" ]]; then
    files=/tmp/pmm-files
    "$GUEST_DIR/push" "$(img_dir "$id")/files" "$files" || die "copying files/ into the guest failed"
  fi
  PROV_ENV+=("ANFS_IMAGE_FILES=$files")
  mapfile -t steps < <(img_steps "$id")
  for s in ${steps[@]+"${steps[@]}"}; do
    _provision "$log" "$(basename "$s")" prov_run "$s"
  done
}
