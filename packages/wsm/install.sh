# wsm
#
# Installs wsm (~/.local/bin/wsm), which puts the spaces anfs sources define (spaces/**/space.yml)
# in place, under WSM_SPACES_HOME (anfs.conf; default ~/spaces). wsm keeps no record: what is
# installed is read off the links.

post_install() {
  user_message "List the spaces your sources define: wsm ls\n" \
               "Install them: wsm install <source>/, then jump around with: wsm cd <space>"
}

# What install put in the spaces besides its links (clones, your files) is never removed
post_remove() {
  user_message "Left in place: the spaces' links under \$WSM_SPACES_HOME.\n" \
               "Run 'wsm implode' before removing wsm to unlink them."
}
