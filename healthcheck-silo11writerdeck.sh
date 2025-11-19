#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; cmd=$BASH_COMMAND; echo "⛓️  [silo] ERROR: ${cmd} exited with ${rc} (line $LINENO)"; exit $rc' ERR

# ------------------------------------------------------------------------------------
# silo11writerdeck :: health-check (installer-aligned, username-agnostic)
# - Detects active mode (TTY system unit vs. user unit) and checks only what's relevant
# - Verifies wrapper, (optional) exporter, repo, core pkgs, and (if applicable) linger & unit content
# - Optional: compares installed units to repo copies (systemd/{user,system})
# - Keeps clean-uninstall as a success path without nagging
# ------------------------------------------------------------------------------------

WD_NAME="silo11writerdeck"

# ===== Feature toggles =====
# 0 = disable all custom export server checks; 1 = enable
: "${WD_EXPORT_ENABLE:=0}"

# ---- User-level layout ----
BIN_DIR="${HOME}/.local/bin"
CFG_DIR="${HOME}/.config/${WD_NAME}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${WD_NAME}"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
REPO_DIR="${HOME}/${WD_NAME}"
INSTALL_LOG="${STATE_DIR}/install.log"
REPO_INSTALL_LOG="${REPO_DIR}/install.log"
WD_HOME="${HOME}"

# ---- Repo unit locations (for optional drift checks) ----
REPO_USER_UNIT="${REPO_DIR}/systemd/user/${WD_NAME}-tui.service"
REPO_SYS_UNIT="${REPO_DIR}/systemd/system/${WD_NAME}-tty.service"

# ---- Binaries per installer ----
WD_WRAPPER_BIN="${BIN_DIR}/silo11writerdeck"
if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
  WD_EXPORT_BIN="${BIN_DIR}/export_http_server.py"
fi

# ---- Units per installer ----
WD_TUI_USER_UNIT="${WD_NAME}-tui.service"
WD_TUI_USER_UNIT_PATH="${SYSTEMD_USER_DIR}/${WD_TUI_USER_UNIT}"
WD_TTY_SYS_UNIT="${WD_NAME}-tty.service"
WD_TTY_SYS_UNIT_PATH="/etc/systemd/system/${WD_TTY_SYS_UNIT}"

# ---- Optional Bluetooth (hidden unless asked) ----
WD_BT_UNIT="bt-autopair-trust-connect.service"
BT_EXPECTED="${WD_BT_EXPECTED:-0}"   # set 1 to check/show BT

# ---- Unified manifest (match installer) ----
#   Default: ~/.local/state/silo11writerdeck/manifest
#   Override with WD_MANIFEST_ROOT to support non-standard layouts.
: "${WD_MANIFEST_ROOT:=${XDG_STATE_HOME:-$HOME/.local/state}/${WD_NAME}}"
MANIFEST_DIR="${WD_MANIFEST_ROOT}/manifest"
PKG_MANAGER="${MANIFEST_DIR}/pkg.manager"
PKG_REQUIRED="${MANIFEST_DIR}/pkg.required"
PKG_PREEXIST="${MANIFEST_DIR}/pkg.preexisting"
PKG_PURGE="${MANIFEST_DIR}/pkg.purge"
LINGER_MARKER="${MANIFEST_DIR}/linger.enabled"

# ---- Pretty prints ----
say()  { printf "⛓️  [silo] %s\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }
info() { printf "ℹ️  %s\n" "$*"; }
warn() { printf "⚠️  %s\n" "$*"; }
bad()  { printf "⛔ %s\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

FIXES=()
add_fix(){ [[ "${CLEAN_MODE:-0}" -eq 1 ]] && return; FIXES+=("$*"); }

# --- OS detect ---------------------------------------------------------------
case "$(uname -s)" in
  Darwin) IS_MACOS=1 ;;
  Linux)  IS_LINUX=1 ;;
esac

# ---- Helpers ----
brew_pkg_present(){
  local name="$1"
  brew list --formula --versions "$name" >/dev/null 2>&1 || \
  brew list --cask    --versions "$name" >/dev/null 2>&1
}

brew_pkg_version(){
  local name="$1"
  if brew list --formula --versions "$name" >/dev/null 2>&1; then
    brew list --formula --versions "$name" | awk '{print $2}'
  elif brew list --cask --versions "$name" >/dev/null 2>&1; then
    # casks may print 'latest' — that’s fine
    brew list --cask --versions "$name" | awk '{print $2}'
  else
    echo ""
  fi
}

user_systemd_available(){
  have systemctl && systemctl --user show-environment >/dev/null 2>&1
}

linger_status(){
  if have loginctl; then
    loginctl show-user "$(id -un)" -p Linger 2>/dev/null | cut -d= -f2 | grep -qx yes && echo yes || echo no
  else
    echo no
  fi
}

print_file_presence() { local p="$1" l="${2:-$1}"; [[ -e "$p" ]] && { printf "  ✓ %s\n" "$l"; return 0; } || { printf "  • %s MISSING\n" "$l"; return 1; }; }
is_exec() { [[ -x "$1" ]]; }
path_has_local_bin(){ printf "%s" ":$PATH:" | grep -q ":${HOME}/.local/bin:"; }

# --- Export server port probe (only when enabled) ---
if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
  port_8080_snapshot() {
    if have ss; then
      (have timeout && timeout 2 ss -H -tlnp || ss -H -tlnp) 2>/dev/null | awk '$4 ~ /:8080$/'
    elif have netstat; then
      if [[ -n "${IS_LINUX:-}" ]]; then
        (have timeout && timeout 2 netstat -tlnp || netstat -tlnp) 2>/dev/null | awk '/:8080[[:space:]]/'
      fi
    fi
    if [[ -n "${IS_MACOS:-}" ]] || ! have ss; then
      if have lsof; then
        lsof -nP -iTCP:8080 -sTCP:LISTEN 2>/dev/null
      fi
    fi
  }
else
  port_8080_snapshot(){ :; }  # no-op
fi

unit_state() { # $1= "sys" | "user", $2=unit  -> prints "load enabled active" and always exits 0
  local which="$1" unit="$2"
  local load="not-found" enabled="unknown" active="inactive"
  local cmd=(systemctl)

  # If systemctl missing (e.g., macOS), return not-found triplet
  if ! have systemctl; then
    printf "%s %s %s\n" "$load" "$enabled" "$active"
    return 0
  fi

  [[ "$which" == "user" ]] && cmd=(systemctl --user)
  if "${cmd[@]}" show "$unit" >/dev/null 2>&1; then
    load="$("${cmd[@]}" show -p LoadState --value "$unit" 2>/dev/null || echo unknown)"
    enabled="$("${cmd[@]}" is-enabled "$unit" 2>/dev/null || echo unknown)"
    if "${cmd[@]}" is-active --quiet "$unit"; then active="active"; else active="inactive"; fi
  fi
  printf "%s %s %s\n" "$load" "$enabled" "$active"
  return 0
}

# Normalize repo system unit template to a temp file for comparison:
# - supports ${WD_HOME}/${WD_USER} and %u placeholders
mk_norm_sys_unit(){
  local src="$1"; local out
  out="$(mktemp)"
  sed -e "s|\${WD_HOME}|${WD_HOME}|g" \
      -e "s|\${WD_USER}|$(id -un)|g" \
      -e "s|/home/%u|${WD_HOME}|g" \
      -e "s|User=%u|User=$(id -un)|g" \
      "$src" > "$out"
  echo "$out"
}

diff_or_note(){
  local a="$1" b="$2" label="$3"
  if command -v diff >/dev/null 2>&1; then
    diff -u --label "installed:${label}" --label "repo:${label}" "$a" "$b" || true
  fi
}

# ---- Start ----
start_ts=$(date +%s)
say "=== silo systems probe :: ${WD_NAME} === $(date)"
uname -a | sed 's/^/⚙️  kernel: /'
if [[ -r /etc/os-release ]]; then . /etc/os-release; printf '🌍 os: %s %s (%s)\n' "${NAME:-?}" "${VERSION:-?}" "${VERSION_CODENAME:-?}"; fi
echo "👤 user: $(id -un)"
echo "🏠 home: ${HOME}"
echo

# --- Detect artifacts ---
WRAP_PRESENT=0; [[ -f "$WD_WRAPPER_BIN" ]] && WRAP_PRESENT=1
if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
  EXP_PRESENT=0; [[ -n "${WD_EXPORT_BIN:-}" && -f "$WD_EXPORT_BIN" ]] && EXP_PRESENT=1
else
  EXP_PRESENT=0
fi
USER_UNIT_FILE_PRESENT=0; [[ -f "$WD_TUI_USER_UNIT_PATH" ]] && USER_UNIT_FILE_PRESENT=1
SYS_TTY_UNIT_FILE_PRESENT=0; [[ -f "$WD_TTY_SYS_UNIT_PATH" ]] && SYS_TTY_UNIT_FILE_PRESENT=1

USER_SYSTEMD=0; user_systemd_available && USER_SYSTEMD=1

if ! IFS=' ' read -r TTY_LOAD TTY_ENABLED TTY_ACTIVE < <(unit_state sys "$WD_TTY_SYS_UNIT"); then
  TTY_LOAD="not-found"; TTY_ENABLED="unknown"; TTY_ACTIVE="inactive"
fi
if (( USER_SYSTEMD )); then
  if ! IFS=' ' read -r U_LOAD U_ENABLED U_ACTIVE < <(unit_state user "$WD_TUI_USER_UNIT"); then
    U_LOAD="not-found"; U_ENABLED="unknown"; U_ACTIVE="inactive"
  fi
else
  U_LOAD="not-found"; U_ENABLED="unknown"; U_ACTIVE="inactive"
fi

if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
  PORT_8080_OPEN=0; [[ -n "$(port_8080_snapshot || true)" ]] && PORT_8080_OPEN=1
else
  PORT_8080_OPEN=0
fi

# --- Clean uninstall path ---
CLEAN_MODE=0
if (( WRAP_PRESENT==0 && USER_UNIT_FILE_PRESENT==0 && SYS_TTY_UNIT_FILE_PRESENT==0 )) && \
   [[ "$TTY_LOAD" == "not-found" && "$U_LOAD" == "not-found" ]] && \
   { [[ "${WD_EXPORT_ENABLE}" != "1" ]] || (( EXP_PRESENT==0 && PORT_8080_OPEN==0 )); }; then
  CLEAN_MODE=1
  say "# status summary"
  if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
    echo "  ${WD_NAME} not installed for user '$(id -un)'."
    echo "  (no units, wrapper, exporter, or open :8080)"
  else
    echo "  ${WD_NAME} not installed for user '$(id -un)'."
    echo "  (no units or wrapper)"
  fi
  echo
  ok "Health-check: clean uninstalled state."
  duration=$(( $(date +%s) - start_ts ))
  say "=== probe complete :: silo optimized === (${duration}s)"
  echo
  exit 0
fi

# --- Decide mode (TTY vs USER) ---
MODE="unknown"
if [[ "$TTY_ENABLED" == "enabled" ]]; then
  MODE="tty"
elif [[ "$U_ENABLED" == "enabled" ]]; then
  MODE="user"
elif [[ "$TTY_LOAD" == "loaded" && "$U_LOAD" != "loaded" ]]; then
  MODE="tty"
elif [[ "$U_LOAD" == "loaded" && "$TTY_LOAD" != "loaded" ]]; then
  MODE="user"
fi

say "# mode"
case "$MODE" in
  tty)  ok "Mode: TTY (system unit drives the TUI on /dev/tty1)";;
  user) ok "Mode: USER (systemd --user drives the TUI)";;
  *)    warn "Mode not clearly determined (neither unit enabled)";;
esac
echo

# 0) Logs & environment (advisory-only PATH)
say "# logs & environment"

print_file_presence "$INSTALL_LOG" "~/.local/state/${WD_NAME}/install.log" || true

if [[ -L "$REPO_INSTALL_LOG" ]]; then
  tgt="$(readlink -f "$REPO_INSTALL_LOG" 2>/dev/null || readlink "$REPO_INSTALL_LOG" 2>/dev/null || true)"
  if [[ "$tgt" == "$INSTALL_LOG" ]]; then
    printf "  ✓ repo log link: %s → %s\n" "$REPO_INSTALL_LOG" "$tgt"
  else
    printf "  • repo log link mismatch: %s → %s\n" "$REPO_INSTALL_LOG" "${tgt:-?}"
  fi
fi

# Python presence check
if have python3; then
  printf "  ✓ python3: %s\n" "$(python3 --version 2>/dev/null)"
else
  echo "  • python3 MISSING"
  if [[ -n "${IS_MACOS:-}" ]]; then
    add_fix "Install Python via Homebrew: brew install python3"
  else
    add_fix "Install Python via apt: sudo apt-get install -y python3"
  fi
fi

# PATH sanity advisory
if ! path_has_local_bin; then
  info "PATH note: ~/.local/bin not on PATH (okay for services; add if you want 'silo11writerdeck' in new shells)"
fi
echo

# 1) Services (show only what matters)
say "# service sentries"
if [[ "$BT_EXPECTED" == "1" ]]; then
  read BT_LOAD BT_ENABLED BT_ACTIVE < <(unit_state sys "$WD_BT_UNIT")
  printf "%s %s (loaded=%s, active=%s, enabled=%s)\n" \
    $([[ "$BT_LOAD" == "loaded" && "$BT_ENABLED" == "enabled" && "$BT_ACTIVE" == "active" ]] && echo "✅" || echo "⚠️") \
    "$WD_BT_UNIT" "$BT_LOAD" "$BT_ACTIVE" "$BT_ENABLED"
fi

# TTY
TTY_ICON="✓"
if [[ "$TTY_LOAD" == "loaded" && "$TTY_ENABLED" == "enabled" && "$TTY_ACTIVE" == "active" ]]; then
  TTY_ICON="✅"
elif [[ "$TTY_LOAD" == "loaded" || "$TTY_ENABLED" == "enabled" || "$TTY_ACTIVE" == "active" ]]; then
  TTY_ICON="⚠️"
fi
printf "%s %s (loaded=%s, active=%s, enabled=%s)\n" \
  "$TTY_ICON" "$WD_TTY_SYS_UNIT" "$TTY_LOAD" "$TTY_ACTIVE" "$TTY_ENABLED"

# USER
if (( USER_SYSTEMD )); then
  if [[ "$MODE" == "tty" ]]; then
    printf "ℹ️  (user) %s (loaded=%s, active=%s, enabled=%s — expected disabled in TTY mode)\n" \
      "$WD_TUI_USER_UNIT" "$U_LOAD" "$U_ACTIVE" "$U_ENABLED"
  else
    U_ICON="⚠️"
    if [[ "$U_LOAD" == "loaded" && "$U_ENABLED" == "enabled" && ( "$U_ACTIVE" == "active" || "$U_ACTIVE" == "activating" ) ]]; then
      U_ICON="✅"
    fi
    printf "%s (user) %s (loaded=%s, active=%s, enabled=%s)\n" \
      "$U_ICON" "$WD_TUI_USER_UNIT" "$U_LOAD" "$U_ACTIVE" "$U_ENABLED"
    # Only suggest enabling if we're actually in USER mode
    if [[ "$MODE" == "user" ]]; then
      [[ "$U_LOAD"    != "loaded"    ]] && add_fix "Recreate user unit: ./install-silo11writerdeck.sh"
      [[ "$U_ENABLED" != "enabled"   ]] && add_fix "Enable user TUI: systemctl --user enable --now ${WD_TUI_USER_UNIT}"
      [[ "$U_ACTIVE"  != "active" && "$U_ACTIVE" != "activating" ]] && add_fix "Start user TUI: systemctl --user restart ${WD_TUI_USER_UNIT}"
    fi
  fi
else
  info "user systemd not available (no session/linger) — irrelevant in TTY mode."
fi
echo

# 1a) Unit content sanity (only for the active mode)
say "# unit content sanity"
if [[ "$MODE" == "user" && -f "$WD_TUI_USER_UNIT_PATH" ]]; then
  wd="$(grep -E '^WorkingDirectory=' "$WD_TUI_USER_UNIT_PATH" | head -1 | cut -d= -f2- || true)"
  es="$(grep -E '^ExecStart=' "$WD_TUI_USER_UNIT_PATH"      | head -1 | cut -d= -f2- || true)"
  sd="$(grep -E '^Environment=WD_STATE_DIR=' "$WD_TUI_USER_UNIT_PATH" | head -1 | cut -d= -f2- || true)"
  cdv="$(grep -E '^Environment=WD_CFG_DIR='   "$WD_TUI_USER_UNIT_PATH" | head -1 | cut -d= -f2- || true)"

  if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
    eb="$(grep -E '^Environment=WD_EXPORT_BIN=' "$WD_TUI_USER_UNIT_PATH" | head -1 | cut -d= -f2- || true)"
    eb_val="${eb#WD_EXPORT_BIN=}"
  fi

  [[ "$wd" == "%h/silo11writerdeck"                    ]] || add_fix "Set WorkingDirectory=%h/silo11writerdeck"
  [[ "$es" == "%h/.local/bin/silo11writerdeck"         ]] || add_fix "Set ExecStart=%h/.local/bin/silo11writerdeck"

  if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
    if [[ -f "${WD_EXPORT_BIN:-/nonexistent}" ]]; then
      [[ "$eb_val" == "%h/.local/bin/export_http_server.py" ]] || add_fix "Set WD_EXPORT_BIN=%h/.local/bin/export_http_server.py"
    else
      [[ -n "$eb" ]] && info "WD_EXPORT_BIN present but exporter not installed (ok; optional)"
    fi
  fi

  [[ "${sd#WD_STATE_DIR=}" == "%h/.local/state/silo11writerdeck" ]] || add_fix "Set WD_STATE_DIR=%h/.local/state/silo11writerdeck"
  [[ "${cdv#WD_CFG_DIR=}"  == "%h/.config/silo11writerdeck"      ]] || add_fix "Set WD_CFG_DIR=%h/.config/silo11writerdeck"

  if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
    [[ -n "$wd$es$sd$cdv$eb" ]] && printf "  ✓ user unit fields present\n" || printf "  • some fields missing in user unit\n"
  else
    [[ -n "$wd$es$sd$cdv"   ]] && printf "  ✓ user unit fields present\n" || printf "  • some fields missing in user unit\n"
  fi
elif [[ "$MODE" == "tty" ]]; then
  info "Skipping user-unit content checks (TTY mode)."
else
  info "No unit content to check."
fi
echo

# 1b) Unit drift vs repo (optional advisory)
if [[ -f "$REPO_USER_UNIT" && -f "$WD_TUI_USER_UNIT_PATH" ]]; then
  say "# unit drift (user)"
  if cmp -s "$REPO_USER_UNIT" "$WD_TUI_USER_UNIT_PATH"; then
    printf "  ✓ user unit matches repo copy\n"
  else
    printf "  • user unit differs from repo copy\n"
    info "Run installer to refresh, or inspect diff below:"
    diff_or_note "$WD_TUI_USER_UNIT_PATH" "$REPO_USER_UNIT" "${WD_TUI_USER_UNIT}"
    add_fix "Refresh user unit from repo: ./install-silo11writerdeck.sh"
  fi
  echo
fi
if [[ -f "$REPO_SYS_UNIT" && -f "$WD_TTY_SYS_UNIT_PATH" ]]; then
  say "# unit drift (system/tty)"
  tmp_norm="$(mk_norm_sys_unit "$REPO_SYS_UNIT")"
  if cmp -s "$tmp_norm" "$WD_TTY_SYS_UNIT_PATH"; then
    printf "  ✓ system tty unit matches normalized repo copy\n"
  else
    printf "  • system tty unit differs from normalized repo copy\n"
    diff_or_note "$WD_TTY_SYS_UNIT_PATH" "$tmp_norm" "${WD_TTY_SYS_UNIT}"
    add_fix "Refresh system tty unit: uninstall, then rerun installer"
  fi
  rm -f "$tmp_norm"
  echo
fi

# 2) Repo & entrypoint
say "# repo & entrypoint"
print_file_presence "$REPO_DIR" "~/${WD_NAME}" || add_fix "Ensure ~/silo11writerdeck exists (installer symlinks it if needed)"
print_file_presence "${REPO_DIR}/tui/menu.py" "tui/menu.py" || add_fix "Missing TUI module: verify repo has tui/menu.py"
echo

# 3) User artifacts
say "# user artifacts (bins/config/state)"
if print_file_presence "$WD_WRAPPER_BIN" "silo11writerdeck (launcher)"; then
  if ! is_exec "$WD_WRAPPER_BIN"; then
    echo "  • launcher not executable"
    add_fix "chmod +x ~/.local/bin/silo11writerdeck"
  else
    # Accept common, valid forms for the Exec line
    if grep -Eq '^[[:space:]]*exec[[:space:]]+([^[:space:]]+/)?(env[[:space:]]+)?python3([[:space:]]+-I)?[[:space:]]+-m[[:space:]]+tui\.menu([[:space:]]|$)' "$WD_WRAPPER_BIN"; then
      printf "  ✓ launcher exec matches: python3 -m tui.menu\n"
    else
      warn "launcher exec line differs from expected 'python3 -m tui.menu'"
      add_fix "Recreate launcher via installer (restores correct Exec)"
      awk 'NR<=3 || /^exec[[:space:]]/ {print "    > "$0}' "$WD_WRAPPER_BIN" | sed '1s/^/    current lines:\n/'
    fi
  fi
else
  add_fix "Recreate launcher: ./install-silo11writerdeck.sh (restores ~/.local/bin/silo11writerdeck)."
fi

print_file_presence "$CFG_DIR"        "~/.config/${WD_NAME}"      >/dev/null || true
print_file_presence "$STATE_DIR"      "~/.local/state/${WD_NAME}" >/dev/null || true

if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
  if ! print_file_presence "${WD_EXPORT_BIN:-/nonexistent}" "export_http_server.py"; then
    info "exporter missing (optional): feature under construction or intentionally disabled"
  else
    is_exec "$WD_EXPORT_BIN" || { echo "  • exporter not executable"; add_fix "chmod +x ~/.local/bin/export_http_server.py"; }
  fi
fi
echo

# 4) Core packages (OS-aware; references PKG_CORE_* directly)
say "# core packages"

if [[ ! -s "${PKG_MANAGER}" || ! -s "${PKG_REQUIRED}" ]]; then
  echo "⚠️  package manifest incomplete at ${MANIFEST_DIR} (manager/required)."
else
  mgr="$(cat "${PKG_MANAGER}")"
  # Bash 3.2-safe replacement for mapfile
  req=()
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    req+=("$line")
  done < "${PKG_REQUIRED}"
  printf "  🔎 Checking %d packages via %s\n" "${#req[@]}" "$mgr"

  ok=0; miss=0
  case "$mgr" in
    apt)
      for p in "${req[@]}"; do
        if dpkg -s "$p" >/dev/null 2>&1; then
          v="$(dpkg-query -W -f='${Version}\n' "$p" 2>/dev/null || true)"
          printf "  ✓ %-16s %s\n" "$p" "${v:+($v)}"
          ((++ok))
        else
          printf "  ⛔ %-16s missing\n" "$p"
          ((++miss))
        fi
      done
      if (( miss )); then
        echo "  tip: sudo apt-get install ${req[*]}"
      fi
      ;;
    brew)
      for p in "${req[@]}"; do
        if brew_pkg_present "$p"; then
          v="$(brew_pkg_version "$p")"
          printf "  ✓ %-16s %s\n" "$p" "${v:+($v)}"; ((ok++))
        else
          printf "  ⛔ %-16s missing\n" "$p"; ((miss++))
        fi
      done
      (( miss )) && echo "  tip: use 'brew install <formula>' or 'brew install --cask <app>' as appropriate"
      ;;
    *)
      echo "⚠️  unknown pkg manager '${mgr}'"
      ;;
  esac
  echo "  — summary: ${ok} present, ${miss} missing"
fi

# 5) Linger (only relevant in USER mode)
if [[ "$MODE" == "user" ]]; then
  say "# linger"
  LSTAT="$(linger_status)"; echo "  user linger: ${LSTAT}"
  [[ "$LSTAT" == "yes" ]] || add_fix "Enable headless user services: loginctl enable-linger $(id -un)"
  [[ -r "$LINGER_MARKER" ]] && printf "  ✓ linger marker: %s\n" "$LINGER_MARKER"
  echo
fi

# 6) Export channel (TCP 8080) — only when enabled
if [[ "${WD_EXPORT_ENABLE}" == "1" ]]; then
  say "# export server (HTTP 8080)"
  if [[ -n "${IS_MACOS:-}" || "$(uname -s)" == "Darwin" ]]; then
    echo "  • not applicable on macOS (Linux-only feature)"
  else
    print_file_presence "${WD_EXPORT_BIN:-/nonexistent}" "~/.local/bin/export_http_server.py" || true
    if port_8080_snapshot | grep -q .; then
      echo "  ✓ port 8080 listener detected"
    else
      echo "  • port 8080 not listening (start from menu when needed)"
    fi
  fi
  echo
fi

# 7) Status summary
say "# status summary"
case "$MODE" in
  tty)
    echo "  Mode: TTY"
    echo "  TTY unit:    ${TTY_LOAD}/${TTY_ENABLED}/${TTY_ACTIVE}"
    echo "  User unit:   ${U_LOAD}/${U_ENABLED}/${U_ACTIVE} (informational only)"
    ;;
  user)
    echo "  Mode: USER"
    echo "  User unit:   ${U_LOAD}/${U_ENABLED}/${U_ACTIVE}"
    echo "  TTY unit:    ${TTY_LOAD}/${TTY_ENABLED}/${TTY_ACTIVE} (should be disabled)"
    ;;
  *)
    echo "  Mode: undetermined (neither unit enabled)"
    ;;
esac
echo

# 8) Done
duration=$(( $(date +%s) - start_ts ))
say "=== probe complete :: silo optimized === (${duration}s)"
echo

# Only show remediation if there are real issues for the chosen mode
if (( ${#FIXES[@]} > 0 )); then
  bad "Remediation:"
  uniq_fixes=()
  for f in "${FIXES[@]}"; do
    skip=0
    for seen in "${uniq_fixes[@]}"; do
      if [[ "$seen" == "$f" ]]; then
        skip=1
        break
      fi
    done
    (( skip )) && continue
    uniq_fixes+=("$f")
    echo "  - $f"
  done
  exit 1
else
  exit 0
fi

