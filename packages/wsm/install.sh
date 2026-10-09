# wsm
#
# Installs wsm (~/.local/bin/wsm), which puts the workspaces anfs sources define (spaces/<ws>/<space>)
# in place. Nothing to configure: the default target is WSM_SPACES_HOME in anfs.conf.

post_install() {
  user_message "List the workspaces your sources define: wsm ls\n" \
               "Install one: wsm install <source>/<ws>, then jump around with: wsm cd <space>"
}

# What install put in the spaces besides its links (clones, your files) is never removed
post_remove() {
  user_message "Left in place: the spaces and their trackers under \$XDG_STATE_HOME/wsm.\n" \
               "Run 'wsm implode' before removing wsm to unlink them."
}
