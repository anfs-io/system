#!/usr/bin/env bats
# sources.sh / image.sh: finding images across sources, and the from: chain
load helper

setup() { setup_pim; }

@test "list and path: local shadows a source; source/name picks one" {
  add_source acme
  image "$T/srcs/acme/images/web" "$(deb_yml)"
  image "$T/srcs/acme/images/db" "$(deb_yml)"
  image "$PIM_IMAGES_HOME/web" "$(deb_yml)"
  load_sources
  [ "$(canon web)" = local/web ]
  [ "$(canon acme/web)" = acme/web ]
  [ "$(canon db)" = acme/db ]
  run cmd_list
  [[ "$output" == *"web   local"* ]]
  [[ "$output" == *"shadowed"* ]]
  run cmd_path acme/db
  [ "$output" = "$HOME/.local/share/anfs/sources/acme/images/db" ]
  run cmd_list --names
  [[ "$output" == *"acme/db"* && "$output" == *$'\nweb'* ]]
}

@test "from: resolves in the same or a lower-priority source, never a higher one" {
  add_source hi
  add_source lo
  image "$T/srcs/lo/images/base" "$(deb_yml)"
  image "$T/srcs/lo/images/app" "from: top"
  image "$T/srcs/hi/images/top" "$(deb_yml)"
  image "$T/srcs/hi/images/svc" "from: base"
  load_sources
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
  load_sources
  [ "$(img_root hi/base)" = lo/base ]
  [ "$(img_distro hi/base)" = debian ]
  run img_chain hi/a
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
}

@test "scripts: distro defaults for root images, an image script replaces one of the same name" {
  image "$PIM_IMAGES_HOME/d" "$(deb_yml)"
  mkdir -p "$PIM_IMAGES_HOME/d/scripts"
  echo 'echo mine' > "$PIM_IMAGES_HOME/d/scripts/10-base.sh"
  echo 'echo app' > "$PIM_IMAGES_HOME/d/scripts/50-app.sh"
  image "$PIM_IMAGES_HOME/c" "from: d"
  mkdir -p "$PIM_IMAGES_HOME/c/scripts"
  echo 'echo c' > "$PIM_IMAGES_HOME/c/scripts/01-c.sh"
  load_sources
  [ "$(img_scripts local/d | paste -sd' ' -)" = "$PIM_IMAGES_HOME/d/scripts/10-base.sh $PIM_IMAGES_HOME/d/scripts/50-app.sh" ]
  [ "$(img_scripts local/c)" = "$PIM_IMAGES_HOME/c/scripts/01-c.sh" ]
  image "$PIM_IMAGES_HOME/e" "$(deb_yml)"
  load_sources
  [ "$(img_scripts local/e)" = "$PIM_LIB_DIR/defaults/debian/scripts/10-base.sh" ]
}

@test "install source/: every image of the source, validate-only with PIM_INSTALL=validate" {
  add_source acme
  image "$T/srcs/acme/images/web" "$(deb_yml)"
  image "$T/srcs/acme/images/bad" "distro: plan9"
  load_sources
  PIM_INSTALL=validate run cmd_install acme/
  [ "$status" -ne 0 ]
  [[ "$output" == *"acme/web ok"* ]]
  [[ "$output" == *"distro 'plan9' has no installer"* ]]
}
