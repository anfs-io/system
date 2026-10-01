# anfs.zsh — zsh-specific anfs integration (anfs/anfs). The anfs() wrapper is portable and lives
# in .config/sh/anfs.sh. zcomp comes from pde/zsh; anfs doesn't depend on that package.

command -v anfs >/dev/null 2>&1 || return

(( $+functions[zcomp] )) && zcomp anfs
