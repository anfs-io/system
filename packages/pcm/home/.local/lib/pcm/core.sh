#!/usr/bin/env bash
# pcm library: small helpers shared by every pcm lib
# Sourced by ~/.local/bin/pcm; defines functions only.

under() {
  [[ "$1" == "$2" || "$1" == "$2/"* ]]
}

# True if $1 equals any of the remaining args
in_list() {
  local item="$1" x
  shift
  for x in "$@"; do
    [[ "$item" == "$x" ]] && return 0
  done
  return 1
}
