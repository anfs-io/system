#!/usr/bin/env bash
# pmm library: image definitions across the sources; the image path and new commands, and what
# `pmm install` does with a source's images. Sourced by ~/.local/bin/pmm; defines functions only.

# An image is its id, `source/name`. The name alone is its identity on disk: the build
# directories and the ssh key.

# Finding definitions across the sources is anfs's (lib/anfs/catalog.sh). An image is a directory
# with an image.yml, in a source's machines/images/ or in $PMM_IMAGES_HOME, which comes first.
#
# There is one catalogue per process, and machines are the other kind (sources.sh): canon,
# all_ids and effective_ids answer for whichever was loaded last. The `image` commands run with
# this one loaded. What a machine needs to know about its image is asked in a subshell that
# loads it (image_def_dir, image_build and image_ensure_built in settings.sh), so the machines'
# catalogue is still there afterwards.
load_images()   { catalog_load machines/images image.yml "$PMM_LOCAL_SOURCE" "$PMM_IMAGES_HOME"; }
source_dir()    { catalog_source_dir "$1"; }
source_index()  { catalog_source_index "$1"; }
img_name()      { echo "${1#*/}"; }
img_src()       { echo "${1%%/*}"; }
img_dir()       { catalog_dir "$1"; }

# canon (a plain name resolves to the highest-priority source defining it, searching from
# priority index <min>: from: passes its own source's index, so a parent is in the same or a
# lower-priority source), or die naming the spec
img_canon_or_die() {
  canon "$1" || die "image '$1' not found (see: pmm image list)"
}

cmd_image_path() {
  local disk=${CLI_OPT[disk]:-false} arch="" id
  [[ -z "${CLI_OPT[arch]:-}" ]] || arch=$(arch_norm "${CLI_OPT[arch]}")
  id=$(img_canon_or_die "$1")
  if $disk; then
    arch="${arch:-$(host_arch)}"
    local d
    d=$(build_disk "$(img_bname "$id")" "$arch") || die "$id has no $arch build (pmm image build $id)"
    echo "$d"
  else
    img_dir "$id"
  fi
}

cmd_image_cd() {
  echo "pmm image cd requires the pmm shell function (source pmm.zsh)" >&2
  return 1
}

# `pmm image new <name> [--from <image>] [--copy <image>] [--source <alias>]`: a new definition,
# in $PMM_IMAGES_HOME unless --source names a source. --from: a child of that image (image.yml, an
# empty provision/, a README). --copy: that image's whole directory under the new name, which is
# how a root image is started (the answer file, the steps and the test are the image's own). It
# only creates, so it never asks about what is there: an existing directory is refused (73).
cmd_image_new() {
  local name="$1" from="${CLI_OPT[from]:-}" copy="${CLI_OPT[copy]:-}" src="${CLI_OPT[source]:-}"
  local dest base id how parent
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || cli_usage_err "'$name' is not an image name (letters, digits, . _ -)"
  [[ -z "$from" || -z "$copy" ]] || cli_usage_err "--from or --copy, not both"
  if [[ -z "$from$copy" ]]; then
    [[ -t 0 ]] || cli_usage_err "--from <image> (a child) or --copy <image> (a root) is required"
    read -r -p "Build on an image (from) or copy one (copy)? " how
    case "$how" in
      f|from) read -r -p "From which image? " from ;;
      c|copy) read -r -p "Copy which image? " copy ;;
    esac
    [[ -n "$from$copy" ]] || cli_usage_err "--from <image> (a child) or --copy <image> (a root) is required"
  fi
  if [[ -z "$src" || "$src" == "$PMM_LOCAL_SOURCE" ]]; then
    src="$PMM_LOCAL_SOURCE" dest="$PMM_IMAGES_HOME/$name"
  else
    gitsrc_collect
    [[ " ${GITSRC_NAMES[*]} " == *" $src "* ]] || die "no source '$src' (see: anfs src list)"
    dest="$(gitsrc_dir "$src")/machines/images/$name"
  fi
  [[ ! -e "$dest" ]] || anfs_fail 73 "$(tilde "$dest") exists"
  base=$(canon "${from:-$copy}") || die "image '${from:-$copy}' not found (see: pmm image list)"

  if [[ -n "$copy" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp -R "$(img_dir "$base")" "$dest"
  else
    mkdir -p "$dest/provision"
    : > "$dest/provision/.gitkeep"
    # from: as it was asked for: with its source, it is that image and no other of the name
    [[ "$from" == */* ]] || from=$(img_name "$base")
    printf '%s\n' "# $name: built on $(img_name "$base")" "description: $name" "from: $from" > "$dest/image.yml"
    cat > "$dest/README.md" <<EOF
# $name

Built on \`$(img_name "$base")\`: its build is this one's starting disk, so its user, its ssh key and
everything its own steps installed are already there.

- \`provision/*\` are the steps, run in name order (none yet). A \`.sh\` step is a script run
  as root in the guest; another extension is another provisioner's
- \`files/\` is copied to the guest for them (\`\$ANFS_IMAGE_FILES\`)
- \`test.sh\` is what \`pmm image test $name\` runs; without one it is $(img_name "$base")'s

\`pmm image show $name\` lists what a build reads; \`pmm image build --test $name\` builds it.
EOF
  fi
  id="$src/$name"
  load_images
  anfs_json_on || echo "Created $id: $(tilde "$dest")"
  [[ -z "$copy" ]] || anfs_json_on || echo "Its README.md and description: are $base's, to be rewritten"
  # a plain from: is the name as $src sees it, which may not be the image the name is here
  if [[ -n "$from" ]] && parent=$(img_parent "$id") && [[ "$parent" != \?* && "$parent" != "$base" ]]; then
    warn "$id is built on $parent, not $base: from: $from resolves in $src or a lower-priority source"
  fi
  validate_image_quiet "$id" || warn "$id does not validate yet (pmm image validate $id)"
  anfs_result id "$id" dir "$dest"
}

# The images half of `pmm install <source>/`: build every image the source defines (with
# PMM_INSTALL=validate, only validate them). True when the source has none. Run with the image
# catalogue loaded.
images_install() {
  local src="$1" id
  local -a images=()
  source_dir "$src" >/dev/null || return 0
  for id in $(all_ids); do
    [[ "$(img_src "$id")" == "$src" ]] && images+=("$id")
  done
  [[ ${#images[@]} -gt 0 ]] || return 0
  case "$PMM_INSTALL" in
    validate) cli_call "image validate" "${images[@]}" ;;
    *) cli_call "image build" "${images[@]}" ;;
  esac
}
