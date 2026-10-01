# varlock.bash — the portable part is .config/sh/varlock.sh

# The generated script needs bash-completion (_get_comp_words_by_ref) and declares readonly
# variables, so it is loaded once per shell: re-sourcing it on _ppm_shell_reload would error.
# eval rather than . <(...), which bash 3.2 cannot source.
if command -v varlock >/dev/null 2>&1 && declare -F _get_comp_words_by_ref >/dev/null &&
   ! complete -p varlock >/dev/null 2>&1; then
  eval "$(varlock complete bash)"
fi
