# anfs
#
# core/anfs's hooks: the toolkit API's listener (lib/anfs/listener.sh). post_install writes and
# loads it: a launchd agent on macOS (TCP 127.0.0.1:47100, a token per grant), two systemd user
# sockets on Linux (rpc.sock read, rpc-write.sock write). post_remove unloads and deletes it; the
# tokens stay in $ANFS_STATE_HOME/rpc for a reinstall (anfs implode deletes them).
#
# The lib is sourced from this package, not from ~/.local/lib: post_remove runs after the unstow.

_anfs_pkg_listener() {
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/home/.local/lib/anfs/paths.sh"
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/home/.local/lib/anfs/listener.sh"
}

post_install() {
  _anfs_pkg_listener
  anfs_rpc_listener_install
  if [[ "$(_anfs_rpc_os)" == macos ]]; then
    user_message "The toolkit API listens on 127.0.0.1:$ANFS_RPC_PORT (launchd $ANFS_RPC_LABEL);" \
                 " a connection's first line is {\"token\":\"...\"}, from \$ANFS_STATE_HOME/rpc/token.read or token.write"
  else
    user_message "The toolkit API listens on \$XDG_RUNTIME_DIR/anfs/rpc.sock (read) and rpc-write.sock (write)"
  fi
}

post_remove() {
  _anfs_pkg_listener
  anfs_rpc_listener_remove
}
