# wsm.sh — wsm's portable shell integration.
# Sourced by both the bash and the zsh rc; anything zsh-only lives in .config/zsh/wsm.zsh.

command -v wsm >/dev/null 2>&1 || return 0

# Wrapper to handle `wsm cd`: a subshell cannot change the parent's directory, so the binary
# prints the path (`wsm path`) and the cd happens here.
#
# `wsm cd` with no argument jumps to the root of the workspace containing the current directory.
wsm() {
  if [ "${1:-}" = "cd" ]; then
    shift
    # Not named `status`: that is a read-only special variable in zsh, which sources this file
    local dir rc
    dir=$(command wsm path "$@")
    rc=$?
    # 3 means the entry matched but is stale: the path was still printed and the warning is
    # already on stderr, so honour it — otherwise you could never cd into a workspace to fix it.
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ]; then
      [ -n "$dir" ] && cd "$dir"
    else
      return "$rc"
    fi
  else
    command wsm "$@"
  fi
}
