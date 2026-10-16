#!/usr/bin/env bats
# Documents: listing them, finding one by id whatever its path, and checking them against the
# vault's profile.
# Run: bats packages/pvm/tests/

load helper
setup() {
  pvm_setup
  vault notes
  doc notes/prd/one.md aaaaaaaaaa PRD "The first"
  doc notes/prd/two.md bbbbbbbbbb PRD "The second"
  doc notes/adr/why.md cccccccccc ADR "Why: a decision"
}

@test "docs lists id, type, title, space and path for the vault you are in" {
  cd notes
  run pvm docs
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "cccccccccc"$'\t'"ADR"$'\t'"Why: a decision"$'\t'"-"$'\t'"~/notes/adr/why.md"$'\t'"notes" ]
  [[ "${lines[1]}" == "aaaaaaaaaa"$'\t'"PRD"$'\t'"The first"* ]]
}

@test "docs: PATH narrows it, --type filters, and outside a vault it is every vault" {
  vault other
  doc other/x.md dddddddddd Note
  run pvm docs notes/prd
  [ "${#lines[@]}" -eq 2 ]
  run pvm docs --type ADR
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == cccccccccc* ]]
  run pvm docs
  [ "${#lines[@]}" -eq 4 ]
  [[ "$output" == *"dddddddddd"*"other" ]]
  run pvm docs "$HOME"
  [ "$status" -eq 1 ]
}

@test "docs skips hidden directories, node_modules, index.md and log.md" {
  doc notes/.obsidian/plugin.md eeeeeeeeee Note
  doc notes/node_modules/pkg/readme.md ffffffffff Note
  doc notes/index.md gggggggggg Note
  doc notes/prd/log.md hhhhhhhhhh Note
  run pvm docs notes
  [ "${#lines[@]}" -eq 3 ]
}

@test "a document with frontmatter and no id is listed with an empty id; one with none is not" {
  file notes/draft.md "---\ntype: Note\ntitle: Draft\n---\ntext\n"
  file notes/plain.md "# Just markdown\n"
  run pvm docs notes --json
  [ "$status" -eq 0 ]
  run yq -p json -r '.[] | select(.title == "Draft") | .id' <<< "$output"
  [ "$output" = "null" ]
  run pvm docs notes
  [ "${#lines[@]}" -eq 4 ]
  [[ "$output" != *"plain.md"* ]]
}

@test "the space of a document is the level of the link that holds it, the deepest when they nest" {
  level acme/main/tech
  level acme/main
  cd notes
  pvm link add prd --to acme/main/tech >/dev/null
  pvm link add . --to acme/main >/dev/null
  run pvm docs
  [[ "${lines[0]}" == "cccccccccc"$'\t'"ADR"$'\t'*$'\t'"acme/main"$'\t'* ]]
  [[ "${lines[1]}" == "aaaaaaaaaa"$'\t'"PRD"$'\t'*$'\t'"acme/main/tech"$'\t'* ]]
  run pvm docs --space acme/main/tech
  [ "${#lines[@]}" -eq 2 ]
}

@test "quoted titles lose their quotes, and CRLF files read the same" {
  file notes/q.md "---\r\nid: \"iiiiiiiiii\"\r\ntype: 'Note'\r\ntitle: \"Quoted: yes\"\r\n---\r\nbody\r\n"
  run pvm docs notes --type Note
  [ "$output" = "iiiiiiiiii"$'\t'"Note"$'\t'"Quoted: yes"$'\t'"-"$'\t'"~/notes/q.md"$'\t'"notes" ]
}

@test "path and show find a document by id from anywhere, after it moved too" {
  run pvm path bbbbbbbbbb
  [ "$output" = "$HOME/notes/prd/two.md" ]
  mkdir notes/archive
  mv notes/prd/two.md "notes/archive/renamed two.md"
  run pvm path bbbbbbbbbb
  [ "$output" = "$HOME/notes/archive/renamed two.md" ]
  run pvm show bbbbbbbbbb
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "---" ]
  [[ "$output" == *"# Body of bbbbbbbbbb"* ]]
  run pvm show bbbbbbbbbb --body
  [[ "$output" != *"type: PRD"* ]]
  [[ "$output" == *"# Body of bbbbbbbbbb"* ]]
}

@test "show: an unknown id exits 1; an id in two documents exits 2 and names both" {
  run pvm show zzzzzzzzzz
  [ "$status" -eq 1 ]
  vault other
  doc other/copy.md aaaaaaaaaa PRD
  run pvm show aaaaaaaaaa
  [ "$status" -eq 2 ]
  [[ "$output" == *"notes/prd/one.md"* && "$output" == *"other/copy.md"* ]]
}

@test "an id only in a document's body is not that document's id" {
  file notes/mention.md "---\nid: jjjjjjjjjj\ntype: Note\n---\nsee\nid: aaaaaaaaaa\n"
  run pvm path aaaaaaaaaa
  [ "$output" = "$HOME/notes/prd/one.md" ]
}

@test "show --json: id, vault, path, space, the frontmatter as data, the body as text" {
  level acme/main
  (cd notes && pvm link add prd --to acme/main >/dev/null)
  file notes/prd/one.md "---\nid: aaaaaaaaaa\ntype: PRD\ntags: [a, b]\n---\nLine \"one\"\n\ttabbed\n"
  run pvm show aaaaaaaaaa --json
  [ "$status" -eq 0 ]
  local json="$output"
  run yq -p json -r '[.id, .vault, .vault_id, .path, .space, .frontmatter.tags[1]] | join("|")' <<< "$json"
  [ "$output" = "aaaaaaaaaa|notes|$VID|$HOME/notes/prd/one.md|acme/main|b" ]
  run yq -p json -r '.body' <<< "$json"
  [ "${lines[0]}" = 'Line "one"' ]
  [ "${lines[1]}" = $'\ttabbed' ]
  run pvm show cccccccccc --json
  run yq -p json -r '.space' <<< "$output"
  [ "$output" = "null" ]
}

# --- validate -----------------------------------------------------------------------------

@test "validate: a clean vault has no findings" {
  cd notes
  run pvm validate
  [ "$status" -eq 0 ]
  [ "$output" = "3 document(s), 0 finding(s)" ]
}

@test "validate reports no frontmatter, an open block, bad YAML, and missing required keys" {
  file notes/plain.md "# No frontmatter\n"
  file notes/open.md "---\nid: kkkkkkkkkk\ntype: Note\n\nnever closed\n"
  file notes/bad.md "---\nid: llllllllll\ntype: [unclosed\n---\n"
  file notes/empty.md "---\n---\nbody\n"
  file notes/notype.md "---\nid: mmmmmmmmmm\ntype:\n---\n"
  cd notes
  run pvm validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"plain.md: no frontmatter"* ]]
  [[ "$output" == *"open.md: the frontmatter is not closed"* ]]
  [[ "$output" == *"bad.md: the frontmatter does not parse as YAML"* ]]
  [[ "$output" == *"empty.md: missing required key: type"* ]]
  [[ "$output" == *"empty.md: missing required key: id"* ]]
  [[ "$output" == *"notype.md: missing required key: type"* ]]
  [[ "$output" == *"8 document(s), 6 finding(s)"* ]]
}

@test "validate --strict exits 1 on any finding, 0 on none" {
  cd notes
  run pvm validate --strict
  [ "$status" -eq 0 ]
  file notes/plain.md "text\n"
  run pvm validate --strict
  [ "$status" -eq 1 ]
}

@test "validate checks the profile: its required keys and its allowed types" {
  yq -i '.profile.required = ["type", "id", "status"] | .profile.types = ["PRD", "Note"]' notes/pvm.yml
  file notes/full.md "---\nid: nnnnnnnnnn\ntype: Note\nstatus: draft\n---\n"
  cd notes
  run pvm validate
  [[ "$output" == *"adr/why.md: type 'ADR' is not one of: PRD Note"* ]]
  [[ "$output" == *"prd/one.md: missing required key: status"* ]]
  [[ "$output" != *"full.md"* ]]
}

@test "validate reports an id used twice, on both, even when one is outside PATH" {
  doc notes/adr/copy.md aaaaaaaaaa ADR
  cd notes
  run pvm validate
  [[ "$output" == *"adr/copy.md: duplicate id aaaaaaaaaa (also prd/one.md)"* || "$output" == *"prd/one.md: duplicate id aaaaaaaaaa (also adr/copy.md)"* ]]
  [[ "$output" == *"2 finding(s)"* ]]
  run pvm validate adr
  [[ "$output" == *"adr/copy.md: duplicate id aaaaaaaaaa"* ]]
  [[ "$output" == *"2 document(s), 1 finding(s)"* ]]
}

@test "validate --fix mints a missing id and changes nothing else" {
  file notes/new.md "---\ntype: Note\ntitle: New\n---\n\nBody stays.\n"
  file notes/blank.md "---\nid:\ntype: Note\n---\nBody.\n"
  file notes/plain.md "no frontmatter\n"
  cd notes
  run pvm validate --fix
  [ "$status" -eq 0 ]
  [[ "$output" == *"new.md: minted id "* ]]
  [[ "$output" == *"2 id(s) minted"* ]]
  [[ "$output" == *"plain.md: no frontmatter"* ]]
  [[ "$output" != *"missing required key"* ]]
  # A new id goes last in the frontmatter; the lines that were there are as they were
  run cat new.md
  [ "${lines[0]}" = "---" ]
  [ "${lines[1]}" = "type: Note" ]
  [ "${lines[2]}" = "title: New" ]
  [[ "${lines[3]}" =~ ^id:\ [a-z2-7]{10}$ ]]
  [ "${lines[4]}" = "---" ]
  [ "${lines[5]}" = "Body stays." ]
  run cat blank.md
  [[ "${lines[1]}" =~ ^id:\ [a-z2-7]{10}$ ]]
  [ "${lines[2]}" = "type: Note" ]
  [ "$(cat plain.md)" = "no frontmatter" ]
  # Minted once: the id is never changed after
  local id
  id=$(sed -n 4p new.md)
  pvm validate --fix >/dev/null
  [ "$(sed -n 4p new.md)" = "$id" ]
}

@test "validate takes one file, and --json lists the findings" {
  file notes/plain.md "text\n"
  run pvm validate notes/plain.md
  [ "$output" = "plain.md: no frontmatter"$'\n'"1 document(s), 1 finding(s)" ]
  run pvm validate notes --json
  [ "$status" -eq 0 ]
  run yq -p json -r '.[0] | .path + ": " + .finding' <<< "$output"
  [ "$output" = "plain.md: no frontmatter" ]
  rm notes/plain.md
  run pvm validate notes --json
  [ "$output" = "[]" ]
}
