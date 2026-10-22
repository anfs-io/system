# wsm
#
# Installs wsm (~/.local/bin/wsm), which puts the spaces anfs sources define (spaces/**/space.yml)
# in place, under WSM_SPACES_HOME (anfs.conf; default ~/spaces). wsm keeps no record: what is
# installed is read off the links.

post_install() {
  ppm_register_callback wsm_ppm_changed
  user_message "List the spaces your sources define: wsm ls\n" \
               "Install them: wsm install <source>/, then jump around with: wsm cd <space>"
}

# What install put in the spaces besides its links (clones, your files) is never removed
post_remove() {
  user_message "Left in place: the spaces' links under \$WSM_SPACES_HOME.\n" \
               "Run 'wsm implode' before removing wsm to unlink them."
}

# ppm calls this after every install/remove run (ppm_register_callback), as psm's: a space's skills
# go to the agents ppm installed, so an agent coming installs them in every installed space, and
# one going (that no installed package still declares) is unlinked from them. wsm's own: psm need
# not know wsm, and wsm does not need psm.
# Usage: wsm_ppm_changed <install|remove> <repo/pkg>...
wsm_ppm_changed() {
  local event="$1" qualified any=false ids="" id kept
  shift
  # shellcheck source=/dev/null
  declare -F anfs_skill_package_agents >/dev/null || source "$HOME/.local/lib/anfs/skill.sh"
  case "$event" in
    install)
      for qualified in "$@"; do
        [[ -z "$(anfs_skill_package_agents "$qualified")" ]] || any=true
      done
      $any || return 0
      wsm skill install || ppm_fail "wsm skill install reported failures — fix and re-run it" || true
      ;;
    remove)
      for qualified in "$@"; do ids="$ids $(anfs_skill_package_agents "$qualified")"; done
      kept=",$(anfs_skill_agents),"
      local -a gone=()
      for id in $ids; do
        [[ "$kept" != *",$id,"* ]] && gone+=("$id")
      done
      [[ ${#gone[@]} -gt 0 ]] || return 0
      wsm __agents_rm "${gone[@]}" || ppm_fail "wsm could not unlink ${gone[*]} from the spaces' skills" || true
      ;;
  esac
}
