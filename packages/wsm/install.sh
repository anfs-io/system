# wsm
#
# Installs wsm (~/.local/bin/wsm), a registry of the workspaces under your home directory.
# Nothing to build and nothing to configure: the registry is created on first use.

post_install() {
  user_message "Seed the registry from the markers already on this machine: wsm scan\n" \
               "Then jump around with: wsm cd <name>"
}

# The registry is a cache, but the markers are not: removing them is the user's call, not ours.
post_remove() {
  user_message "Left in place: the registry under \$XDG_STATE_HOME/wsm and every .wsm/ marker.\n" \
               "Remove the registry with: rm -r \"\${XDG_STATE_HOME:-\$HOME/.local/state}/wsm\""
}
