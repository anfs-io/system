#!/usr/bin/env bats
# Vaults: pvm.yml as the marker, the registry that indexes them, and what happens when a vault
# moves, is renamed, or goes.
# Run: bats packages/pvm/tests/

load helper
setup() { pvm_setup; }

@test "init writes pvm.yml with a new id and the directory's name, and registers the vault" {
  mkdir notes
  run pvm init notes
  [ "$status" -eq 0 ]
  [[ "$output" == "initialized vault notes ("*") at ~/notes" ]]
  run yq -r .id notes/pvm.yml
  [[ "$output" =~ ^[a-z2-7]{10}$ ]]
  run yq -r .name notes/pvm.yml
  [ "$output" = notes ]
  run yq -r '.profile.required | join(",")' notes/pvm.yml
  [ "$output" = "type,id" ]
  run cat "$REGISTRY"
  [[ "$output" == *$'\t'"notes"$'\t'*$'\t'"$HOME/notes" ]]
}

@test "init defaults to the current directory, and --name names the vault" {
  mkdir work && cd work
  run pvm init --name "My Vault: 2"
  [ "$status" -eq 0 ]
  run yq -r .name pvm.yml
  [ "$output" = "My Vault: 2" ]
  run pvm ls
  [[ "$output" == "My Vault: 2"$'\t'* ]]
}

@test "init again keeps the id; a pvm.yml without an id gets one and keeps the rest" {
  vault notes
  run pvm init notes
  [ "$status" -eq 0 ]
  [[ "$output" == "unchanged vault notes ($VID)"* ]]
  mkdir other
  printf '# mine\nlinks:\n  - source: a\n    target: x/y\n' > other/pvm.yml
  run pvm init other
  [ "$status" -eq 0 ]
  run yq -r .id other/pvm.yml
  [[ "$output" =~ ^[a-z2-7]{10}$ ]]
  grep -q '^# mine$' other/pvm.yml
  run yq -r '.links[0].target' other/pvm.yml
  [ "$output" = "x/y" ]
}

@test "a vault does not hold another" {
  vault notes
  mkdir -p notes/sub/deep
  run pvm init notes/sub/deep
  [ "$status" -eq 73 ]
  [[ "$output" == *"inside the vault at ~/notes"* ]]
  [ ! -e notes/sub/deep/pvm.yml ]
}

@test "new creates the directory, and refuses one that exists" {
  run pvm new fresh/vault --name fresh
  [ "$status" -eq 0 ]
  [ -f fresh/vault/pvm.yml ]
  run pvm new fresh/vault
  [ "$status" -eq 73 ]
  run pvm new
  [ "$status" -eq 64 ]
}

@test "ls lists live vaults, --stale the ones that are gone or changed id" {
  vault a
  vault b
  run pvm ls
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "a"$'\t'*$'\t'"ok"$'\t'"~/a" ]]
  rm -rf b
  run pvm ls
  [ "${#lines[@]}" -eq 1 ]
  run pvm ls --stale
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "b"$'\t'*$'\t'"stale"$'\t'* ]]
  # A pvm.yml that changed id is another vault: the entry is stale
  yq -i '.id = "aaaaaaaaaa"' a/pvm.yml
  run pvm ls --stale
  [ "${#lines[@]}" -eq 2 ]
}

@test "ls --json has every entry with its state" {
  vault a
  vault b
  rm -rf b
  run pvm ls --json
  [ "$status" -eq 0 ]
  run yq -p json -r '.[] | .name + "=" + .status' <<< "$output"
  [ "${lines[0]}" = "a=ok" ]
  [ "${lines[1]}" = "b=stale" ]
}

@test "a moved vault is the same vault at a new path" {
  vault a
  local id="$VID" added
  added=$(cut -f3 "$REGISTRY")
  mv a elsewhere
  run pvm scan "$HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved a ($id) ~/elsewhere (was ~/a)"* ]]
  run cat "$REGISTRY"
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "$id"$'\t'"a"$'\t'"$added"$'\t'"$HOME/elsewhere" ]]
}

@test "using a vault registers it: after a move, or one that was never registered" {
  vault a
  mv a moved
  cd moved
  run pvm path
  [ "$output" = "$HOME/moved" ]
  run pvm ls
  [[ "$output" == *"~/moved" ]]
  [ "${#lines[@]}" -eq 1 ]
  # Copied in from another machine: a pvm.yml, no registry entry
  rm "$REGISTRY"
  run pvm docs
  [ "$status" -eq 0 ]
  run pvm ls
  [[ "$output" == *"~/moved" ]]
}

@test "a rename in pvm.yml reaches the registry" {
  vault a
  yq -i '.name = "alpha"' a/pvm.yml
  cd a
  pvm path >/dev/null
  run pvm ls
  [[ "$output" == "alpha"$'\t'* ]]
}

@test "scan finds vaults, skips .git and node_modules, and warns about a pvm.yml with no id" {
  mkdir -p one two/.git/x three/node_modules/y four
  pvm init one >/dev/null
  rm "$REGISTRY"
  printf 'id: bbbbbbbbbb\n' > two/.git/x/pvm.yml
  printf 'id: cccccccccc\n' > three/node_modules/y/pvm.yml
  printf 'name: nothing\n' > four/pvm.yml
  run pvm scan
  [ "$status" -eq 0 ]
  [[ "$output" == *"added one"* ]]
  [[ "$output" == *"no id in ~/four/pvm.yml"* ]]
  [[ "$output" == *"1 vault(s) found, 1 change(s)"* ]]
  run pvm scan
  [[ "$output" == *"1 vault(s) found, 0 change(s)"* ]]
}

@test "path: the vault you are in, one by name, id or id prefix; stale exits 3" {
  vault a
  local id="$VID"
  mkdir -p a/deep/er
  cd a/deep/er
  run pvm path
  [ "$output" = "$HOME/a" ]
  cd "$HOME"
  run pvm path a
  [ "$output" = "$HOME/a" ]
  run pvm path "$id"
  [ "$output" = "$HOME/a" ]
  run pvm path "${id:0:4}"
  [ "$output" = "$HOME/a" ]
  run pvm path "${id:0:3}"
  [ "$status" -eq 1 ]
  run pvm path
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a vault"* ]]
  rm -rf a
  run pvm path a
  [ "$status" -eq 3 ]
  [[ "$output" == *"$HOME/a"* ]]
}

@test "an ambiguous name exits 2 and lists the candidates" {
  mkdir -p x/notes y/notes
  pvm init x/notes >/dev/null
  pvm init y/notes >/dev/null
  run pvm path notes
  [ "$status" -eq 2 ]
  [[ "$output" == *"~/x/notes"* && "$output" == *"~/y/notes"* ]]
}

@test "remove drops one entry and leaves the files; prune drops the stale ones" {
  vault a
  vault b
  vault c
  run pvm remove a
  [ "$status" -eq 0 ]
  [ -f a/pvm.yml ]
  run pvm ls
  [ "${#lines[@]}" -eq 2 ]
  run pvm remove a
  [ "$status" -eq 1 ]
  rm -rf b
  run pvm prune -n
  [[ "$output" == "would drop b"* ]]
  run pvm prune --dry-run
  [[ "$output" == "would drop b"* ]]
  run pvm ls --stale
  [ "${#lines[@]}" -eq 1 ]
  run pvm prune
  [[ "$output" == "dropped b"* ]]
  run cat "$REGISTRY"
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == *$'\t'"c"$'\t'* ]]
}

@test "concurrent inits all land in the registry" {
  local i
  for i in 1 2 3 4 5 6; do mkdir "v$i"; done
  for i in 1 2 3 4 5 6; do pvm init "v$i" >/dev/null & done
  wait
  run cat "$REGISTRY"
  [ "${#lines[@]}" -eq 6 ]
  [ ! -e "$XDG_STATE_HOME/pvm/vaults.lock" ]
}

@test "a stale lock is cleared; a held one fails with 75" {
  mkdir -p "$XDG_STATE_HOME/pvm/vaults.lock" a
  echo 1 > "$XDG_STATE_HOME/pvm/vaults.lock/created"
  run pvm init a
  [ "$status" -eq 0 ]
  [[ "$output" == *"clearing a stale lock"* ]]
  mkdir b "$XDG_STATE_HOME/pvm/vaults.lock"
  date +%s > "$XDG_STATE_HOME/pvm/vaults.lock/created"
  run pvm init b
  [ "$status" -eq 75 ]
}

@test "the options every tool takes, --version, and an unknown command" {
  run pvm --version
  [[ "$output" == pvm\ * ]]
  run pvm help
  [[ "$output" == *"link <add|remove|list|apply|validate>"* ]]
  [[ "$output" == *"list, ls [--stale]"* ]]
  [[ "$output" == *"remove, rm <vault>"* ]]
  [[ "$output" == *"-d, --debug"* ]]
  run pvm nope
  [ "$status" -eq 64 ]
  vault a
  mv a b
  cd b
  run pvm -d path
  [[ "$output" == *"pvm: debug: registry: moved a"* ]]
}

@test "a tab press: commands once with their aliases, a vault by name, options after a -" {
  vault a
  run pvm __complete ""
  [[ "$output" == *"list"$'\t'"The vaults this machine knows (alias: ls)"* ]]
  ! grep -qE '^(ls|rm)	' <<< "$output"
  run pvm __complete path ""
  [ "$output" = "a"$'\t'"~/a" ]
  run pvm __complete link ""
  [[ "$output" == *"remove"$'\t'*"(alias: rm)"* ]]
  run pvm __complete link add ""
  [ "$output" = ":dirs" ]
  run pvm __complete link add "-"
  [[ "$output" == *"--to"$'\t'* && "$output" == *"--as"$'\t'* ]]
  # A tab press does not register the vault you are in, or write anything
  rm "$REGISTRY"
  (cd a && pvm __complete "" >/dev/null)
  [ ! -e "$REGISTRY" ]
}
