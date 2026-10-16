# pvm
#
# Installs pvm (~/.local/bin/pvm): documentation vaults (Obsidian or plain markdown) whose
# directories are linked into wsm spaces, and whose documents are found by a stable id.
#
# pvm listens to wsm (lib/anfs/callbacks.sh): when wsm installs a level, pvm creates the links
# that point into it; when wsm removes one, pvm removes them. wsm knows nothing about pvm. The
# registration is kept by anfs, so it outlives a wsm implode and goes when pvm is removed.

post_install() {
  anfs_callback_register wsm "$PPM_CURRENT_PACKAGE" "pvm link apply --event"
  user_message "Make a directory of documents a vault: pvm init <dir>\n" \
               "Link part of it into a space: pvm link add <dir> --to <source>/<ws>/<space>"
}

post_remove() {
  anfs_callback_unregister wsm "$PPM_CURRENT_PACKAGE"
  user_message "Left in place: your vaults, their pvm.yml, and the links in your spaces.\n" \
               "The registry is in \$XDG_STATE_HOME/pvm."
}
