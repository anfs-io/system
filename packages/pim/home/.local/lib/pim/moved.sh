#!/usr/bin/env bash
# pim library: the commands that went to pmm. Sourced by ~/.local/bin/pim; functions only.
#
# Running an image was pim's until machines became pmm's (any number per image, each with its own
# name). For one release the old names say where they went, and exit 64 like any wrong usage.
# They are not declared, so help and completion no longer show them. Delete this file after that.

_moved() {
  anfs_warn "'pim $1' is now 'pmm $1': machines are pmm's (pmm help)"
  exit 64
}

cmd_up()       { _moved up; }
cmd_down()     { _moved down; }
cmd_shell()    { _moved shell; }
cmd_ps()       { _moved ps; }
cmd_snapshot() { _moved snapshot; }
cmd_reset()    { _moved reset; }
