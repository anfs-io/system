#!/usr/bin/env bash
# pim library: ${VAR} templates (answer files). Sourced by ~/.local/bin/pim; functions only.
#
# ${NAME} (NAME is [A-Z_][A-Z0-9_]*) is replaced by the variable's value (tpl_set/tpl_load);
# $${NAME} is a literal ${NAME}; any other $ is left alone, so $releasever or $(cmd) in a
# kickstart's %post pass through. An unknown NAME is an error naming the file and line.
# Nothing is evaluated: values are inserted as text.

# Usage: render <file>   (prints the result; fails on an unknown variable)
render() {
  local file="$1" line out rest name tail n=0 val
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    out=""
    while [[ "$line" == *'$'* ]]; do
      out+="${line%%\$*}"
      rest="${line#*\$}"
      if [[ "$rest" == '${'* ]]; then
        out+='${'
        line="${rest#\$\{}"
      elif [[ "$rest" =~ ^\{([A-Z_][A-Z0-9_]*)\}(.*)$ ]]; then
        name="${BASH_REMATCH[1]}" tail="${BASH_REMATCH[2]}"
        val=$(tpl_get "$name") || { warn "$file:$n: unknown variable \${$name}"; return 1; }
        out+="$val"
        line="$tail"
      else
        out+='$'
        line="$rest"
      fi
    done
    printf '%s\n' "$out$line"
  done < "$file"
}

# The ${NAME}s a template uses, one per line (for validate)
template_vars() {
  grep -oE '(^|[^$])\$\{[A-Z_][A-Z0-9_]*\}' "$1" 2>/dev/null | sed -E 's/.*\$\{([A-Z_][A-Z0-9_]*)\}/\1/' | sort -u
}
