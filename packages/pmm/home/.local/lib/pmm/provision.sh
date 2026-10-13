#!/usr/bin/env bash
# pmm library: provisioners — what runs a provision step. Sourced by ~/.local/bin/pmm; functions only.
#
# The provisioner of provision/<NN>-<name>.<ext> is <ext>: an executable,
# $PMM_CONFIG_HOME/provisioners/<ext> or pmm's own provisioners/<ext> (where another package
# stows one too), called with a verb:
#   check                prints what is missing on the host (a binary, a version) and fails;
#                        nothing printed is ready. Run by validate
#   fingerprint <step>   prints, one per line, the files the step's result depends on, the step
#                        first; a directory is the tree under it (a link there is its target's
#                        name, not what it points at). pmm hashes them into the build key.
#                        Failing, naming what is not there, or not naming the step first
#                        fails validate and the build. The provisioner itself is not in the
#                        key: one whose change is another build prints its own path too
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

# Run <step> against the guest (PROV_ENV with the guest's part: guest_ssh); its output prefixed,
# a line at a time (sed would hold it back in blocks from build -v)
# Usage: prov_run <step>
prov_run() {
  local l
  prov_call run "$1" 2>&1 | while IFS= read -r l || [[ -n "$l" ]]; do printf '  | %s\n' "$l"; done
  return "${PIPESTATUS[0]}"
}

# The build key's lines for what <step>'s fingerprint names (PROV_ENV and PROV_DIR are set): the
# sha256 of each file, and for a directory of each file under it with its path there (a link
# there is its target's name, not followed). The names it printed are not in the key, so a file
# it wrote for the purpose may be anywhere. Fails with the reason on stderr, the provisioner's
# own when its fingerprint failed: it names what is not there, or not the step first. This is
# all validate and the build know of a step, so both go through it.
# Usage: key_step <provisioner> <step>
key_step() {
  local bin="$1" s="$2" work out p f first=true rc=0
  work=$(mktemp -d "${TMPDIR:-/tmp}/pmm-step.XXXXXX")
  if out=$(cd "$PROV_DIR" && env "${PROV_ENV[@]}" ANFS_IMAGE_WORK="$work" "$bin" fingerprint "$s" < /dev/null); then
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      [[ "$p" == /* ]] || p="$PROV_DIR/$p"
      if $first && [[ ! "$p" -ef "$s" ]]; then
        break
      elif [[ -d "$p" ]]; then
        (cd "$p" && find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
          if [[ -L "$f" ]]; then echo "$f -> $(readlink "$f")"; else echo "$f $(_sha256 < "$f")"; fi
        done)
      elif [[ -f "$p" ]]; then
        _sha256 < "$p"
      else
        echo "its fingerprint names $p, which is not there" >&2; rc=2; break
      fi
      first=false
    done <<< "$out"
    if $first && [[ $rc -eq 0 ]]; then
      echo "its fingerprint does not name the step first (the .$(prov_ext "$s") provisioner's)" >&2; rc=2
    fi
  else
    rc=2
  fi
  rm -rf "$work"
  return $rc
}

# The build key's lines for <id>'s steps, in order: the step and its provisioner, then what its
# fingerprint names (key_step). The provisioner's own file is not in the key: one whose change is
# another build names itself. Fails, saying why, for a step nothing provides or whose
# fingerprint fails.
# Usage: key_steps <id> <arch>
key_steps() {
  local id="$1" arch="$2" s bin lines err
  prov_image_env "$id" "$arch"
  err=$(mktemp "${TMPDIR:-/tmp}/pmm-step.XXXXXX")
  while IFS= read -r s; do
    bin=$(prov_for "$s") || { rm -f "$err"; return 2; }
    echo "step $(basename "$s") $(prov_ext "$s")"
    if lines=$(key_step "$bin" "$s" 2>"$err"); then
      printf '%s\n' "$lines"
      [[ ! -s "$err" ]] || cat "$err" >&2
    else
      warn "provision/$(basename "$s"): $(paste -sd' ' - < "$err" | grep . || echo "the .$(prov_ext "$s") provisioner's fingerprint failed")"
      rm -f "$err"
      return 2
    fi
  done < <(img_steps "$id")
  rm -f "$err"
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
