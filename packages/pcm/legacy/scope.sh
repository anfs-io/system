#!/usr/bin/env bash
# Service backend — scope resolution (user vs system)

PSM_SCOPE_OVERRIDE=""
PSM_SKIP_VALIDATION="${PSM_SKIP_VALIDATION:-}"
PSM_START_AFTER_INSTALL=false

# Backend-specific flag parser
# Called by main script's flag loop for unrecognized flags
parse_backend_flag() {
  case "$1" in
    --user)             PSM_SCOPE_OVERRIDE="user"; return 0 ;;
    --system)           PSM_SCOPE_OVERRIDE="system"; return 0 ;;
    --skip-validation)  PSM_SKIP_VALIDATION=1; return 0 ;;
    --up)               PSM_START_AFTER_INSTALL=true; return 0 ;;
    *)                  return 1 ;;
  esac
}

# Resolve scope after config is loaded
_resolve_scope() {
  local config_scope=""
  if [[ -f "$PPM_CONFIG_HOME/psm.conf" ]]; then
    config_scope=$(grep -E '^scope=' "$PPM_CONFIG_HOME/psm.conf" 2>/dev/null | cut -d= -f2)
  fi

  PSM_SCOPE="${PSM_SCOPE_OVERRIDE:-${config_scope:-user}}"

  local xdg_state_home="${XDG_STATE_HOME:-$HOME/.local/state}"

  case "$PSM_SCOPE" in
    user)
      PSM_SERVICES_HOME="${xdg_state_home}/psm"
      ;;
    system)
      PSM_SERVICES_HOME="/opt/psm"
      ;;
    *)
      echo "psm: Invalid scope: ${PSM_SCOPE} (must be 'user' or 'system')" >&2
      exit 1
      ;;
  esac
}

# Auto-resolve on source
_resolve_scope
