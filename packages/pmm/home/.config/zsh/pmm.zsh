# pmm.zsh — pmm's zsh-only integration: its completion. The `pmm cd` and `pmm image cd` wrapper is
# portable and lives in ~/.config/sh/pmm.sh.

(( $+functions[zcomp] )) && zcomp pmm
