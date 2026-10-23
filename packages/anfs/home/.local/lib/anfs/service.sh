#!/usr/bin/env bash
# anfs: long-running services of the user's: a launchd agent (macOS, gui/<uid>) or a systemd user
# unit (Linux), written (absolute paths and the install's PATH, which launchd cannot expand), not
# stowed: the pattern of the toolkit API's listener (listener.sh, which is socket-activated and
# stays as it is). core/nats and core/anfsd's hooks write, load and remove theirs through it, and
# `anfs bus` starts, stops and asks them.
#
# A service is an associative array the caller fills, and passes by name:
#   [label]     launchd label: io.anfs.nats (~/Library/LaunchAgents/<label>.plist)
#   [unit]      systemd user unit: anfs-nats.service (~/.config/systemd/user/<unit>)
#   [desc]      what it is
#   [by]        who writes it (core/nats), for the header comment
#   [log]       macOS: the file stdout and stderr go to (Linux: the journal)
#   [after]     Linux: a unit it needs, Requires= and After= (anfsd: anfs-nats.service)
#   [killmode]  Linux: KillMode= (anfsd: process, so a stop leaves its runs alone)
# and the program's argv after it. Restart: launchd KeepAlive and ThrottleInterval 10; systemd
# Restart=on-failure, RestartSec=5.
#
# Loading never fails an install: no GUI session or no systemd user manager is a warning (launchd
# loads the agent at the next login). Unloading is done only when this HOME's unit file exists
# (the launchd label is per user, not per HOME: a test's HOME must not unload the real one).
# launchctl and systemctl are called through _anfs_svc_launchctl/_systemctl, and the platform is
# ANFS_SERVICE_OS (macos, linux) when set, so tests stub them.
#
# Functions only, the bash floor. Needs paths.sh.

# macos or linux
anfs_service_os() { case "${ANFS_SERVICE_OS:-$OSTYPE}" in darwin*|macos) echo macos ;; *) echo linux ;; esac; }
_anfs_svc_launchctl() { launchctl "$@"; }
_anfs_svc_systemctl() { systemctl --user "$@"; }
ANFS_SVC_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
ANFS_SVC_AGENT_DIR="$HOME/Library/LaunchAgents"

_anfs_svc_xml() { local s="${1//&/&amp;}"; s="${s//</&lt;}"; printf '%s' "${s//>/&gt;}"; }

# The unit file of <spec> on this platform, into REPLY
anfs_service_file() {
  local -n _sf="$1"
  if [[ "$(anfs_service_os)" == macos ]]; then REPLY="$ANFS_SVC_AGENT_DIR/${_sf[label]}.plist"
  else REPLY="$ANFS_SVC_UNIT_DIR/${_sf[unit]}"
  fi
}

# The environment a service starts with: PATH as installed, HOME, and the XDG homes that are set
_anfs_svc_env() {
  local v
  printf '%s\t%s\n' PATH "$PATH" HOME "$HOME"
  for v in XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; do
    [[ -z "${!v:-}" ]] || printf '%s\t%s\n' "$v" "${!v}"
  done
}

_anfs_svc_plist() {
  local -n _sp="$1"
  shift
  local a k v
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Written by ${_sp[by]} (lib/anfs/service.sh): ${_sp[desc]}. Removed by ppm remove ${_sp[by]}; never edit -->
<plist version="1.0">
<dict>
  <key>Label</key><string>${_sp[label]}</string>
  <key>ProgramArguments</key>
  <array>
XML
  for a in "$@"; do printf '    <string>%s</string>\n' "$(_anfs_svc_xml "$a")"; done
  printf '  </array>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
  while IFS=$'\t' read -r k v; do
    printf '    <key>%s</key><string>%s</string>\n' "$k" "$(_anfs_svc_xml "$v")"
  done < <(_anfs_svc_env)
  cat <<XML
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$(_anfs_svc_xml "${_sp[log]}")</string>
  <key>StandardErrorPath</key><string>$(_anfs_svc_xml "${_sp[log]}")</string>
</dict>
</plist>
XML
}

# A word for ExecStart=: quoted when it has a space or a quote
_anfs_svc_word() {
  if [[ "$1" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then printf '%s' "$1"
  else local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"
  fi
}

_anfs_svc_unit() {
  local -n _su="$1"
  shift
  local a k v exec=""
  for a in "$@"; do exec+="${exec:+ }$(_anfs_svc_word "$a")"; done
  printf '# Written by %s (lib/anfs/service.sh). Removed by ppm remove %s; never edit\n[Unit]\nDescription=%s\n' \
    "${_su[by]}" "${_su[by]}" "${_su[desc]}"
  if [[ -n "${_su[after]:-}" ]]; then printf 'Requires=%s\nAfter=%s\n' "${_su[after]}" "${_su[after]}"; fi
  printf '\n[Service]\nExecStart=%s\n' "$exec"
  while IFS=$'\t' read -r k v; do printf 'Environment="%s=%s"\n' "$k" "$v"; done < <(_anfs_svc_env)
  printf 'Restart=on-failure\nRestartSec=5\n'
  [[ -z "${_su[killmode]:-}" ]] || printf 'KillMode=%s\n' "${_su[killmode]}"
  printf '\n[Install]\nWantedBy=default.target\n'
}

# Write <spec>'s unit file for <argv...> (replacing what is there)
anfs_service_write() {
  local spec="$1"
  shift
  anfs_service_file "$spec"
  mkdir -p -- "${REPLY%/*}"
  if [[ "$(anfs_service_os)" == macos ]]; then _anfs_svc_plist "$spec" "$@" > "$REPLY"
  else _anfs_svc_unit "$spec" "$@" > "$REPLY"
  fi
}

# Whether launchd has <spec> loaded
_anfs_svc_loaded() {
  local -n _sl="$1"
  _anfs_svc_launchctl print "gui/$(id -u)/${_sl[label]}" >/dev/null 2>&1
}

# Load (and so start) <spec>; one already running is restarted (a new binary or config). Never
# fails: a warning.
anfs_service_load() {
  local -n _sv="$1"
  anfs_service_file "$1"
  [[ -f "$REPLY" ]] || { echo "anfs: no unit file for ${_sv[desc]} ($(anfs_display "$REPLY"))" >&2; return 0; }
  if [[ "$(anfs_service_os)" == macos ]]; then
    # a loaded agent keeps the plist it was loaded with: out, then in again (bootout returns
    # before launchd is done, so a bootstrap right after may be refused once or twice)
    ! _anfs_svc_loaded "$1" || _anfs_svc_launchctl bootout "gui/$(id -u)/${_sv[label]}" >/dev/null 2>&1 || true
    local try
    for try in 1 2 3; do
      _anfs_svc_launchctl bootstrap "gui/$(id -u)" "$REPLY" 2>/dev/null && return 0
      [[ "$try" == 3 ]] || sleep 1
    done
    echo "anfs: could not load ${_sv[label]} (no GUI session?); it loads at the next login" >&2
    return 0
  else
    command -v systemctl >/dev/null 2>&1 &&
      _anfs_svc_systemctl daemon-reload 2>/dev/null &&
      _anfs_svc_systemctl enable "${_sv[unit]}" 2>/dev/null &&
      _anfs_svc_systemctl restart "${_sv[unit]}" 2>/dev/null ||
      { echo "anfs: could not enable ${_sv[unit]} (no systemd user manager?); later: systemctl --user enable --now ${_sv[unit]}" >&2; return 0; }
  fi
}

# Stop <spec> (it starts again at the next login or boot): launchd bootout, systemd stop. Only
# when this HOME's unit file exists.
anfs_service_stop() {
  local -n _st="$1"
  anfs_service_file "$1"
  [[ -f "$REPLY" ]] || return 0
  if [[ "$(anfs_service_os)" == macos ]]; then
    _anfs_svc_launchctl bootout "gui/$(id -u)/${_st[label]}" >/dev/null 2>&1 || true
  else
    _anfs_svc_systemctl stop "${_st[unit]}" >/dev/null 2>&1 || true
  fi
}

# Unload and delete <spec>'s unit file
anfs_service_remove() {
  local -n _sr="$1"
  anfs_service_file "$1"
  local f="$REPLY"
  [[ -f "$f" ]] || return 0
  if [[ "$(anfs_service_os)" == macos ]]; then
    _anfs_svc_launchctl bootout "gui/$(id -u)/${_sr[label]}" >/dev/null 2>&1 || true
    rm -f -- "$f"
  else
    _anfs_svc_systemctl disable --now "${_sr[unit]}" >/dev/null 2>&1 || true
    rm -f -- "$f"
    _anfs_svc_systemctl daemon-reload >/dev/null 2>&1 || true
    rmdir "$ANFS_SVC_UNIT_DIR" "${ANFS_SVC_UNIT_DIR%/*}" 2>/dev/null || true
  fi
  return 0
}

# Send a signal to <spec>'s process: anfs_service_signal <spec> HUP
anfs_service_signal() {
  local -n _sg="$1"
  if [[ "$(anfs_service_os)" == macos ]]; then
    _anfs_svc_launchctl kill "$2" "gui/$(id -u)/${_sg[label]}" >/dev/null 2>&1
  else
    _anfs_svc_systemctl kill -s "$2" "${_sg[unit]}" >/dev/null 2>&1
  fi
}

# <spec>'s state into REPLY: "running <pid>", "loaded" (not running), "not loaded", or
# "not installed" (no unit file in this HOME)
anfs_service_state() {
  local -n _ss="$1"
  local out pid="" state=""
  anfs_service_file "$1"
  [[ -f "$REPLY" ]] || { REPLY="not installed"; return 0; }
  if [[ "$(anfs_service_os)" == macos ]]; then
    out=$(_anfs_svc_launchctl print "gui/$(id -u)/${_ss[label]}" 2>/dev/null) || { REPLY="not loaded"; return 0; }
    [[ "$out" =~ [[:space:]]pid\ =\ ([0-9]+) ]] && pid="${BASH_REMATCH[1]}"
  else
    out=$(_anfs_svc_systemctl show -p ActiveState -p MainPID "${_ss[unit]}" 2>/dev/null) || { REPLY="not loaded"; return 0; }
    [[ "$out" =~ ActiveState=([a-z-]+) ]] && state="${BASH_REMATCH[1]}"
    [[ "$out" =~ MainPID=([0-9]+) ]] && pid="${BASH_REMATCH[1]}"
    [[ "$pid" != 0 ]] || pid=""
    [[ "$state" == active || "$state" == activating || "$state" == reloading ]] || pid=""
    [[ -n "$state" && "$state" != inactive || -n "$pid" ]] || { REPLY="not loaded"; return 0; }
  fi
  if [[ -n "$pid" ]]; then REPLY="running $pid"; else REPLY="loaded"; fi
}
