#!/usr/bin/env bats
# image-sources.sh / image.sh: finding images across sources, and the from: chain
load helper

setup() { setup_images; }

@test "list and path: local shadows a source; source/name picks one" {
  add_source acme
  image "$T/srcs/acme/images/web" "$(deb_yml)"
  image "$T/srcs/acme/images/db" "$(deb_yml)"
  image "$PMM_IMAGES_HOME/web" "$(deb_yml)"
  load_images
  [ "$(canon web)" = local/web ]
  [ "$(canon acme/web)" = acme/web ]
  [ "$(canon db)" = acme/db ]
  run cmd_image_list
  [[ "$output" == *"web"$'\t'"local"$'\t'"-"$'\t'"unbuilt"* ]]
  [[ "$output" == *"web"$'\t'"acme"$'\t'"-"$'\t'"shadowed"* ]]
  ANFS_JSON=true run cmd_image_list
  run yq -p json -r '.[] | select(.state == "shadowed") | .name + "@" + .source' <<< "$output"
  [ "$output" = "web@acme" ]
  run cli_call "image path" acme/db
  [ "$output" = "$HOME/.local/share/anfs/sources/acme/images/db" ]
  run cli_call "image list" --names
  [ "$status" -eq 64 ]
  [[ "$output" == *"pmm: unknown option '--names'"* ]]
  [[ "$output" == *"pmm: usage: pmm image list"* ]]
}

@test "from: resolves in the same or a lower-priority source, never a higher one" {
  add_source hi
  add_source lo
  image "$T/srcs/lo/images/base" "$(deb_yml)"
  image "$T/srcs/lo/images/app" "from: top"
  image "$T/srcs/hi/images/top" "$(deb_yml)"
  image "$T/srcs/hi/images/svc" "from: base"
  load_images
  [ "$(img_chain hi/svc | paste -sd' ' -)" = "hi/svc lo/base" ]
  run img_chain lo/app
  [ "$status" -ne 0 ]
  [[ "$output" == *"from: top not found in its source or below"* ]]
}

@test "from: naming its own name is the next layer down; cycles are refused" {
  add_source hi
  add_source lo
  image "$T/srcs/lo/images/base" "$(deb_yml)"
  image "$T/srcs/hi/images/base" "from: base"
  image "$T/srcs/hi/images/a" "from: b"
  image "$T/srcs/hi/images/b" "from: a"
  load_images
  [ "$(img_root hi/base)" = lo/base ]
  [ "$(img_distro hi/base)" = debian ]
  run img_chain hi/a
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
}

@test "scripts: distro defaults for root images, an image script replaces one of the same name" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  mkdir -p "$PMM_IMAGES_HOME/d/scripts"
  echo 'echo mine' > "$PMM_IMAGES_HOME/d/scripts/10-base.sh"
  echo 'echo app' > "$PMM_IMAGES_HOME/d/scripts/50-app.sh"
  image "$PMM_IMAGES_HOME/c" "from: d"
  mkdir -p "$PMM_IMAGES_HOME/c/scripts"
  echo 'echo c' > "$PMM_IMAGES_HOME/c/scripts/01-c.sh"
  load_images
  [ "$(img_scripts local/d | paste -sd' ' -)" = "$PMM_IMAGES_HOME/d/scripts/10-base.sh $PMM_IMAGES_HOME/d/scripts/50-app.sh" ]
  [ "$(img_scripts local/c)" = "$PMM_IMAGES_HOME/c/scripts/01-c.sh" ]
  image "$PMM_IMAGES_HOME/e" "$(deb_yml)"
  load_images
  [ "$(img_scripts local/e)" = "$PMM_LIB_DIR/defaults/debian/scripts/10-base.sh" ]
}

@test "install source/: its images first; validate-only with PMM_INSTALL=validate, built otherwise" {
  add_source acme
  image "$T/srcs/acme/images/web" "$(deb_yml)"
  image "$T/srcs/acme/images/bad" "distro: plan9"
  machine "$T/srcs/acme/machines/m1" "image: web"
  load_machines     # install is a machine command: it loads the images' catalogue itself
  PMM_INSTALL=validate run cli_call install acme/
  [ "$status" -ne 0 ]
  [[ "$output" == *"acme/web ok"* ]]
  [[ "$output" == *"distro 'plan9' has no installer"* ]]
  [[ "$output" != *"acme/m1"* ]]     # the images did not validate: it stops there
  rm -rf "$T/srcs/acme/images/bad"
  cmd_image_build() { echo "build $*"; }
  PMM_INSTALL=validate run cli_call install acme/
  [ "$status" -eq 0 ]
  [[ "$output" == *"acme/web ok"*"acme/m1 ok"* ]]
  PMM_INSTALL=bogus run cli_call install acme/
  [ "$status" -ne 0 ]
  PMM_INSTALL=create run cli_call install acme/
  [[ "$output" == "build acme/web"* ]]
}

@test "completion: the image group's sub-commands, and images by file name" {
  add_source acme
  image "$T/srcs/acme/images/web" "$(deb_yml)"
  image "$PMM_IMAGES_HOME/mine" "$(deb_yml)"
  run "$PMM" __complete image ""
  [[ "$output" == *"build"$'\t'*"test"$'\t'*"export"$'\t'*"prune"$'\t'* ]]
  run "$PMM" __complete image build ""
  [ "$(sort <<< "$output" | paste -sd' ' -)" = "acme/web mine web" ]
  run "$PMM" __complete up --image ""
  [[ "$output" == *"mine"* ]]
}
