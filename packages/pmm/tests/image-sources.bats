#!/usr/bin/env bats
# image-sources.sh / image.sh: finding images across sources, and the from: chain
load helper

setup() { setup_images; }

@test "list and path: local shadows a source; source/name picks one" {
  add_source acme
  image "$T/srcs/acme/machines/images/web" "$(deb_yml)"
  image "$T/srcs/acme/machines/images/db" "$(deb_yml)"
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
  [ "$output" = "$HOME/.local/share/anfs/sources/acme/machines/images/db" ]
  run cli_call "image list" --names
  [ "$status" -eq 64 ]
  [[ "$output" == *"pmm: unknown option '--names'"* ]]
  [[ "$output" == *"pmm: usage: pmm image list"* ]]
}

@test "from: resolves in the same or a lower-priority source, never a higher one" {
  add_source hi
  add_source lo
  image "$T/srcs/lo/machines/images/base" "$(deb_yml)"
  image "$T/srcs/lo/machines/images/app" "from: top"
  image "$T/srcs/hi/machines/images/top" "$(deb_yml)"
  image "$T/srcs/hi/machines/images/svc" "from: base"
  load_images
  [ "$(img_chain hi/svc | paste -sd' ' -)" = "hi/svc lo/base" ]
  run img_chain lo/app
  [ "$status" -ne 0 ]
  [[ "$output" == *"from: top not found in its source or below"* ]]
}

@test "from: naming its own name is the next layer down; cycles are refused" {
  add_source hi
  add_source lo
  image "$T/srcs/lo/machines/images/base" "$(deb_yml)"
  image "$T/srcs/hi/machines/images/base" "from: base"
  image "$T/srcs/hi/machines/images/a" "from: b"
  image "$T/srcs/hi/machines/images/b" "from: a"
  load_images
  [ "$(img_root hi/base)" = lo/base ]
  [ "$(img_distro hi/base)" = debian ]
  run img_chain hi/a
  [ "$status" -ne 0 ]
  [[ "$output" == *"cycle"* ]]
}

@test "steps: every file in an image's own provision/, in name order; a child does not rerun its parent's" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  mkdir -p "$PMM_IMAGES_HOME/d/provision"
  echo 'echo app' > "$PMM_IMAGES_HOME/d/provision/50-app.sh"
  echo 'echo base' > "$PMM_IMAGES_HOME/d/provision/10-base.sh"
  echo 'sources: pushed' > "$PMM_IMAGES_HOME/d/provision/30-kit.anfs"
  # a directory is not a step, nor is what is in it
  mkdir -p "$PMM_IMAGES_HOME/d/provision/tree"; echo 'echo no' > "$PMM_IMAGES_HOME/d/provision/tree/00-no.sh"
  image "$PMM_IMAGES_HOME/c" "from: d"
  mkdir -p "$PMM_IMAGES_HOME/c/provision"
  echo 'echo c' > "$PMM_IMAGES_HOME/c/provision/01-c.sh"
  image "$PMM_IMAGES_HOME/e" "$(deb_yml)"
  load_images
  [ "$(img_steps local/d | paste -sd' ' -)" = "$PMM_IMAGES_HOME/d/provision/10-base.sh $PMM_IMAGES_HOME/d/provision/30-kit.anfs $PMM_IMAGES_HOME/d/provision/50-app.sh" ]
  [ "$(img_steps local/c)" = "$PMM_IMAGES_HOME/c/provision/01-c.sh" ]
  [ -z "$(img_steps local/e)" ]
}

@test "test.sh: the image's own, else the nearest up its chain; with none, image test says so and succeeds" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  image "$PMM_IMAGES_HOME/c" "from: d"
  image "$PMM_IMAGES_HOME/g" "from: c"
  load_images
  [ -z "$(img_test_script local/g)" ]
  wait_ssh() { return 0; }
  run cmd_image_build g
  echo "$output"
  [ "$status" -eq 0 ]
  run cli_call "image test" g
  [ "$status" -eq 0 ]
  [[ "$output" == *"local/g has no test.sh; nothing to test"* ]]
  echo 'true' > "$PMM_IMAGES_HOME/d/test.sh"
  [ "$(img_test_script local/g)" = "$PMM_IMAGES_HOME/d/test.sh" ]
  echo 'true' > "$PMM_IMAGES_HOME/c/test.sh"
  [ "$(img_test_script local/g)" = "$PMM_IMAGES_HOME/c/test.sh" ]
  [ "$(img_test_script local/d)" = "$PMM_IMAGES_HOME/d/test.sh" ]
}

@test "show: the answer file, vars, each ISO, each step and the test with paths; a child lists both images' steps" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml 'vars: {TIMEZONE: UTC, TASKSEL: "standard, ssh-server"}')"
  mkdir -p "$PMM_IMAGES_HOME/d/provision" "$ANFS_ISO_HOME"
  echo 'echo base' > "$PMM_IMAGES_HOME/d/provision/10-base.sh"
  echo 'true' > "$PMM_IMAGES_HOME/d/test.sh"
  : > "$ANFS_ISO_HOME/a.iso"
  image "$PMM_IMAGES_HOME/c" "from: d"
  mkdir -p "$PMM_IMAGES_HOME/c/provision"
  echo 'echo c' > "$PMM_IMAGES_HOME/c/provision/20-c.sh"
  echo 'sources: host' > "$PMM_IMAGES_HOME/c/provision/30-kit.anfs"
  echo 'x' > "$PMM_IMAGES_HOME/c/provision/40-site.yml"
  load_images
  run cli_call "image show" d
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"  answer      ~/.config/pmm/machines/images/d/preseed.cfg"* ]]
  [[ "$output" == *"  vars        TIMEZONE=UTC"$'\n'"              TASKSEL=standard, ssh-server"* ]]
  [[ "$output" == *"  iso arm64   t-arm64  (~/.cache/anfs/isos/a.iso, present)"* ]]
  [[ "$output" == *"  iso amd64   t-amd64  (~/.cache/anfs/isos/b.iso, missing)"* ]]
  [[ "$output" == *"  provision   10-base.sh       ~/.config/pmm/machines/images/d/provision/10-base.sh"$'\n'"              finalize         (pmm) "*"/defaults/finalize.sh"* ]]
  [[ "$output" == *"  test        ~/.config/pmm/machines/images/d/test.sh"* ]]
  [[ "$output" == *"  logs        ~/.local/state/pmm/logs/d-arm64/"* ]]
  # the child: its root's answer file and test, its parent's steps, then its own, finalize; a
  # step nothing provides is said
  run cli_call "image show" c
  echo "$output"
  [[ "$output" == *"  from        local/d"* ]]
  [[ "$output" == *"  answer      ~/.config/pmm/machines/images/d/preseed.cfg"* ]]
  # the paths line up after the longest label
  [[ "$output" == *"10-base.sh       ~/.config/pmm/machines/images/d/provision/10-base.sh"*"20-c.sh          ~/.config/pmm/machines/images/c/provision/20-c.sh"*"30-kit.anfs      ~/.config/pmm/machines/images/c/provision/30-kit.anfs"$'\n'*"40-site.yml      ~/.config/pmm/machines/images/c/provision/40-site.yml  (nothing provides .yml steps)"*"finalize         (pmm)"* ]]
  [[ "$output" == *"  test        ~/.config/pmm/machines/images/d/test.sh"* ]]
  # --json: the same, as one object
  ANFS_JSON=true run cli_call "image show" c
  echo "$output"
  j="$output"
  q() { yq -p json -r "$1" <<< "$j"; }
  [ "$(q .id)" = local/c ]
  [ "$(q '.from | join(",")')" = local/d ]
  [ "$(q .answer)" = "$PMM_IMAGES_HOME/d/preseed.cfg" ]
  [ "$(q .vars.TASKSEL)" = "standard, ssh-server" ]
  [ "$(q '.iso.arm64 | .id + " " + .state')" = "t-arm64 present" ]
  [ "$(q '[.provision[] | .step + ":" + .provisioner] | join("|")')" = "10-base.sh:sh|20-c.sh:sh|30-kit.anfs:anfs|40-site.yml:yml|finalize:sh" ]
  [ "$(q '.provision[0] | .image + " " + .file')" = "local/d $PMM_IMAGES_HOME/d/provision/10-base.sh" ]
  [ "$(q '.provision[4].image')" = null ]
  [ "$(q .test)" = "$PMM_IMAGES_HOME/d/test.sh" ]
  [ "$(q '.builds | length')" = 0 ]
  # an image with no test says so; a tart image has a base and no answer file
  image "$PMM_IMAGES_HOME/m" "backend: tart
distro: macos
base: ghcr.io/x/macos:latest"
  load_images
  run cli_call "image show" m
  [[ "$output" == *"  base        ghcr.io/x/macos:latest"* ]]
  [[ "$output" != *"answer"* ]]
  [[ "$output" != *"finalize"* ]]     # a tart build ends with a reboot, not pmm's finalize step
  [[ "$output" == *"  test        (none: image test has nothing to run)"* ]]
}

@test "show: a vars: value with lines of its own is one variable, shown on one line" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  printf 'vars:\n  RECIPE: |\n    one\n    X=two\n  BS: a\\nb\n' >> "$PMM_IMAGES_HOME/d/image.yml"
  load_images
  run cli_call "image show" d
  echo "$output"
  [[ "$output" == *"  vars        RECIPE=one\nX=two"$'\n'"              BS=a\nb"* ]]
  [[ "$output" != *"  X=two"* ]]
  ANFS_JSON=true run cli_call "image show" d
  [ "$(yq -p json -r '.vars | keys | join(",")' <<< "$output")" = "RECIPE,BS" ]
  [ "$(yq -p json -r .vars.RECIPE <<< "$output")" = "one"$'\n'"X=two" ]
  [ "$(yq -p json -r .vars.BS <<< "$output")" = 'a\nb' ]
}

@test "new --from: a child with an empty provision/ and a README, in the local source; it validates" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  load_images
  run cli_call "image new" web --from d
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Created local/web: ~/.config/pmm/machines/images/web"* ]]
  [ "$(yq -r .from "$PMM_IMAGES_HOME/web/image.yml")" = d ]
  [ -d "$PMM_IMAGES_HOME/web/provision" ] && [ -z "$(ls "$PMM_IMAGES_HOME/web/provision")" ]
  [ -f "$PMM_IMAGES_HOME/web/README.md" ]
  [ ! -e "$PMM_IMAGES_HOME/web/preseed.cfg" ]
  run cmd_image_validate web
  [ "$status" -eq 0 ]
  [[ "$output" == *"local/web ok"* ]]
  [ "$(img_chain local/web | paste -sd' ' -)" = "local/web local/d" ]
  # an existing name is refused, whatever is asked for
  run cli_call "image new" web --from d
  [ "$status" -eq 73 ]
  [[ "$output" == *"exists"* ]]
  run cli_call "image new" d --copy d
  [ "$status" -eq 73 ]
  # what it is built on has to be there
  run cli_call "image new" x --from nosuch
  [ "$status" -eq 1 ]
  [ ! -e "$PMM_IMAGES_HOME/x" ]
  # --json: one object and nothing else
  ANFS_JSON=true run cli_call "image new" web2 --from d
  [ "$status" -eq 0 ]
  [ "$(yq -p json -r '.id + " " + .dir' <<< "$output")" = "local/web2 $PMM_IMAGES_HOME/web2" ]
}

@test "new --from: with its source it is that image; a plain name that is another image from there is said" {
  add_source user
  add_source core
  image "$T/srcs/user/machines/images/deb" "from: deb"
  image "$T/srcs/core/machines/images/deb" "$(deb_yml)"
  load_images
  # the name is user/deb; core/deb was asked for
  run cli_call "image new" web --from core/deb
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(yq -r .from "$PMM_IMAGES_HOME/web/image.yml")" = core/deb ]
  [ "$(img_chain local/web | paste -sd' ' -)" = "local/web core/deb" ]
  [[ "$output" != *"is built on"* ]]
  run cli_call "image new" web3 --from deb
  [ "$(img_chain local/web3 | paste -sd' ' -)" = "local/web3 user/deb core/deb" ]
  [[ "$output" != *"is built on"* ]]
  # from core, deb is core/deb: the image it will be built on is not the one the name is here
  run cli_call "image new" low --from deb --source core
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"core/low is built on core/deb, not user/deb"* ]]
  # a higher source's image cannot be built on: written as asked, and it does not validate
  run cli_call "image new" low2 --from user/deb --source core
  [ "$status" -eq 0 ]
  [ "$(yq -r .from "$T/srcs/core/machines/images/low2/image.yml")" = user/deb ]
  [[ "$output" == *"core/low2 does not validate yet"* ]]
}

@test "new --copy: a root, the whole directory under the new name; --source puts it in a source" {
  add_source acme
  image "$PMM_IMAGES_HOME/d" "$(deb_yml 'vars: {TIMEZONE: UTC}')"
  mkdir -p "$PMM_IMAGES_HOME/d/provision" "$PMM_IMAGES_HOME/d/files"
  echo 'echo base' > "$PMM_IMAGES_HOME/d/provision/10-base.sh"
  echo 'true' > "$PMM_IMAGES_HOME/d/test.sh"; echo f > "$PMM_IMAGES_HOME/d/files/f"
  load_images
  run cli_call "image new" d2 --copy d --source acme
  echo "$output"
  [ "$status" -eq 0 ]
  n="$T/srcs/acme/machines/images/d2"
  [ ! -e "$PMM_IMAGES_HOME/d2" ]
  diff -r "$PMM_IMAGES_HOME/d" "$n"
  [ "$(canon d2)" = acme/d2 ]
  [ -z "$(img_get acme/d2 .from)" ]
  [[ "$output" == *"Its README.md and description: are local/d's"* ]]
  run cmd_image_validate d2
  [ "$status" -eq 0 ]
  # the override of a shipped image: its own name, from a higher source
  run cli_call "image new" d2 --from d2
  [ "$status" -eq 0 ]
  [ "$(canon d2)" = local/d2 ]
  [ "$(img_chain local/d2 | paste -sd' ' -)" = "local/d2 acme/d2" ]
  run cli_call "image new" y --from d --source nosuch
  [ "$status" -eq 1 ]
  [[ "$output" == *"no source 'nosuch'"* ]]
}

@test "new: neither --from nor --copy and no terminal is a usage error; so are both, and a bad name" {
  image "$PMM_IMAGES_HOME/d" "$(deb_yml)"
  load_images
  run cli_call "image new" web </dev/null
  echo "$output"
  [ "$status" -eq 64 ]
  [[ "$output" == *"--from <image> (a child) or --copy <image> (a root) is required"* ]]
  [[ "$output" == *"pmm: usage: pmm image new"* ]]
  run cli_call "image new" web --from d --copy d
  [ "$status" -eq 64 ]
  run cli_call "image new" a/b --from d
  [ "$status" -eq 64 ]
  [ ! -e "$PMM_IMAGES_HOME/web" ]
}

@test "install source/: its images first; validate-only with PMM_INSTALL=validate, built otherwise" {
  add_source acme
  image "$T/srcs/acme/machines/images/web" "$(deb_yml)"
  image "$T/srcs/acme/machines/images/bad" "distro: plan9"
  machine "$T/srcs/acme/machines/m1" "image: web"
  load_machines     # install is a machine command: it loads the images' catalogue itself
  PMM_INSTALL=validate run cli_call install acme/
  [ "$status" -ne 0 ]
  [[ "$output" == *"acme/web ok"* ]]
  [[ "$output" == *"distro 'plan9' has no installer"* ]]
  [[ "$output" != *"acme/m1"* ]]     # the images did not validate: it stops there
  rm -rf "$T/srcs/acme/machines/images/bad"
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
  image "$T/srcs/acme/machines/images/web" "$(deb_yml)"
  image "$PMM_IMAGES_HOME/mine" "$(deb_yml)"
  run "$PMM" __complete image ""
  [[ "$output" == *"new"$'\t'*"build"$'\t'*"test"$'\t'*"export"$'\t'*"prune"$'\t'* ]]
  run "$PMM" __complete image new web --from ""
  [ "$(sort <<< "$output" | paste -sd' ' -)" = "acme/web mine web" ]
  run "$PMM" __complete image new web --source ""
  [ "$output" = acme ]
  run "$PMM" __complete image build ""
  [ "$(sort <<< "$output" | paste -sd' ' -)" = "acme/web mine web" ]
  # what `pmm run` takes
  run "$PMM" __complete run ""
  [ "$(sort <<< "$output" | paste -sd' ' -)" = "acme/web mine web" ]
}

@test "completion: image names in under 100 ms" {
  [[ -n "${EPOCHREALTIME:-}" ]] || skip "no microsecond clock in this bash"
  add_source acme
  image "$T/srcs/acme/machines/images/web" "$(deb_yml)"
  image "$PMM_IMAGES_HOME/mine" "$(deb_yml)"
  local start end best=999999 i
  # The best of three, as registry.bats measures the library: the first run pays for a cold file cache
  for i in 1 2 3; do
    start="${EPOCHREALTIME/[.,]/}"
    "$PMM" __complete image build "" >/dev/null
    end="${EPOCHREALTIME/[.,]/}"
    (( end - start >= best )) || best=$(( end - start ))
  done
  echo "best of three: $(( best / 1000 )) ms"
  (( best / 1000 < 100 ))
}
