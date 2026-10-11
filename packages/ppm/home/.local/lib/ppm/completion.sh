#!/usr/bin/env bash
# Shell completion: the completion command

# Output shell completion for zsh or bash. The command list is generated from the registry
# (cli_cmd in bin/ppm and in extensions), so it lists exactly what exists.
cmd_completion() {
  local shell="${1:-zsh}"

  case "$shell" in
    zsh)
      cat <<'EOF'
#compdef ppm

_ppm() {
    local -a subcommands
    local state

    subcommands=(
EOF
      cli_zsh_commands
      echo "    'cd:Change to a package directory'"
      cat <<'EOF'
    )

    _arguments -C \
        '1: :->command' \
        '*: :->args'

    case $state in
        command)
            _describe 'command' subcommands
            ;;
        args)
            case ${words[2]} in
                install|remove|show|path|cd)
                    _ppm_packages_available
                    ;;
                file)
                    if [[ ${#words[@]} -eq 3 ]]; then
                        local -a file_cmds
                        file_cmds=('add:Move unowned files into repo/package and stow them' 'claim:Copy files into your repo and stow them' 'reset:Restore the original package links' 'protect:Detach files from ppm' 'unprotect:Let ppm manage files again')
                        _describe 'subcommand' file_cmds
                    elif [[ ${words[3]} == add && ${#words[@]} -eq 4 ]]; then
                        _ppm_packages_available
                    elif [[ ${words[3]} == reset ]]; then
                        local -a claimed
                        local claims="${XDG_STATE_HOME:-$HOME/.local/state}/ppm/installed/claims.yml"
                        [[ -f "$claims" ]] && claimed=(${(f)"$(yq -r 'keys[]' "$claims" 2>/dev/null)"})
                        compadd -P "$HOME/" -a claimed
                    else
                        _files
                    fi
                    ;;
                completion)
                    local -a shells
                    shells=('zsh' 'bash')
                    _describe 'shell' shells
                    ;;
            esac
            ;;
    esac
}

_ppm_packages_available() {
    local -a packages
    local sources_home="${XDG_DATA_HOME:-$HOME/.local/share}/anfs/sources"

    if [[ -d "$sources_home" ]]; then
        for repo_dir in "$sources_home"/*/packages; do
            [[ -d "$repo_dir" ]] || continue
            local repo_name="${repo_dir%/packages}"
            repo_name="${repo_name##*/}"
            for pkg_dir in "$repo_dir"/*/; do
                [[ -d "$pkg_dir" ]] || continue
                local pkg_name="${pkg_dir%/}"
                pkg_name="${pkg_name##*/}"
                packages+=("${repo_name}/${pkg_name}")
            done
        done
        local -a metas=("$sources_home"/*/packages/*/package.yml(N))
        (( ${#metas} )) && packages+=(${(u)${(f)"$(yq -N -r '.categories[]? | "@" + .' "${metas[@]}" 2>/dev/null)"}})
    fi

    _describe 'package' packages
}

compdef _ppm ppm
EOF
      ;;
    bash)
      echo "# Bash completion not yet implemented"
      ;;
    *)
      echo "Error: Unknown shell '$shell'. Supported: zsh, bash" >&2
      return 1
      ;;
  esac
}
