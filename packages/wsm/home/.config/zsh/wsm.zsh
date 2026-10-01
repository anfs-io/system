# wsm.zsh — the zsh-only half of wsm's shell integration.
#
# The `wsm cd` wrapper is portable and lives in ~/.config/sh/wsm.sh. Only the completion is here.
# zcomp comes from pde/zsh's aliases.zsh, which the same rc sources first, so no guard is needed.
# `zsrc -c wsm` regenerates the cached completion.

zcomp wsm
