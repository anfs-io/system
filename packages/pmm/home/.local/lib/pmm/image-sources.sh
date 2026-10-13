#!/usr/bin/env bash
# pmm library: image definitions across the sources; the image path command, and what `pmm
# install` does with a source's images. Sourced by ~/.local/bin/pmm; defines functions only.

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
    d=$(build_disk "$(img_name "$id")" "$arch") || die "$id has no $arch build (pmm image build $id)"
    echo "$d"
  else
    img_dir "$id"
  fi
}

cmd_image_cd() {
  echo "pmm image cd requires the pmm shell function (source pmm.zsh)" >&2
  return 1
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
