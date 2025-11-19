#!/usr/bin/env bash
# File: uninstall-silo11writerdeck.sh
# Purpose: Drop-in, cross-platform uninstaller (Linux + macOS) for silo11writerdeck
# Safe, verbose, and idempotent. No assumptions about prior manifests or services.

set -Eeuo pipefail
umask 022

# =========================
# Single source of truth
# =========================
WD_NAME="silo11writerdeck"

# Target user (allow WD_USER override; prefer SUDO_USER; else current user)
WD_USER="${WD_USER:-${SUDO_USER:-$(id -un)}}"
WD_HOME="$(eval echo "~${WD_USER}")"

# OS detect
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
IS_MACOS=0; IS_LINUX=0
[[ "$OS_NAME" == "Darwin" ]] && IS_MACOS=1
[[ "$OS_NAME" == "Linux"  ]] && IS_LINUX=1

# ----- Linux systemd units (if present) -----
SYS_TTY_UNIT="${WD_NAME}-tty.service"                 # /etc/systemd/system/${WD_NAME}-tty.service
USR_TUI_UNIT="${WD_NAME}-tui.service"                 # ${WD_HOME}/.config/systemd/user/${WD_NAME}-tui.service
SYS_TTY_UNIT_PATH="/etc/systemd/system/${SYS_TTY_UNIT}"
SYSTEMD_USER_DIR="${WD_HOME}/.config/systemd/user"
USR_TUI_UNIT_PATH="${SYSTEMD_USER_DIR}/${USR_TUI_UNIT}"

# ----- macOS launchd agents (opportunistic cleanup; support both naming schemes) -----
# Supported names across drafts:
#   • io.silo11.writerdeck.plist
MACOS_LAUNCHD_DIR="${WD_HOME}/Library/LaunchAgents"

# ----- Common user-level bits -----
BIN_DIR="${WD_HOME}/.local/bin"
WD_WRAPPER_BIN="${BIN_DIR}/${WD_NAME}"
# Custom Export Server: disabled/under construction
# WD_EXPORT_BIN="${BIN_DIR}/export_http_server.py"

# --- unified manifest (XDG) ---
: "${WD_MANIFEST_ROOT:=${XDG_STATE_HOME:-${WD_HOME}/.local/state}/${WD_NAME}}"
MANIFEST_DIR="${WD_MANIFEST_ROOT}/manifest"
MANIFEST_FILE="${MANIFEST_DIR}/manifest.txt"

# Package metadata (OS-neutral file names)
PKG_MANAGER="${MANIFEST_DIR}/pkg.manager"       # "apt" | "brew"
PKG_REQUIRED="${MANIFEST_DIR}/pkg.required"     # full required set
PKG_PREEXIST="${MANIFEST_DIR}/pkg.preexisting"  # preexisting at install
PKG_PURGE="${MANIFEST_DIR}/pkg.purge"           # required - preexisting

# Linger marker (now lives with unified manifest)
LINGER_MARKER="${MANIFEST_DIR}/linger.enabled"

# =========================
# Behavior toggles (safe defaults)
# =========================
WD_CLEAN_DOTFILES="${WD_CLEAN_DOTFILES:-0}"   # 1 = remove ambient dotfiles (very conservative)
WD_DISABLE_LINGER="${WD_DISABLE_LINGER:-0}"   # Linux systemd linger: 1 = disable

# =========================
# Sudo / userctl shims (Linux) — no impact on macOS
# =========================
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then SUDO=""; else SUDO="sudo"; fi

HAS_SYSTEMD=0
if (( IS_LINUX )) && command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
  HAS_SYSTEMD=1
fi

if (( HAS_SYSTEMD )); then
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    USRCTL=(sudo -u "$WD_USER" -H systemctl --user)
  else
    USRCTL=(systemctl --user)
  fi
else
  USRCTL=(true)  # harmless no-op
fi

# =========================
# Pretty prints & trap
# =========================
say()  { printf "⛓️  [silo] %s\n" "$*"; }
warn() { printf "⚠️  [silo] %s\n" "$*"; }
err()  { printf "⛔ [silo] %s\n" "$*"; }
trap 'rc=$?; cmd=$BASH_COMMAND; err "abort: line $LINENO: ${cmd} exited with $rc"; exit $rc' ERR

# =========================
# Counters
# =========================
removed_units=0
removed_unit_links=0
removed_files=0
files_failed=0
purged_pkgs=0

# --- portable readarray (Bash 3.2-safe) ---
# usage:
#   readarray_portable VARNAME < file
#   readarray_portable VARNAME < <(command)
readarray_portable() {
  local __var="$1"; shift
  local __line __i=0 __q
  # ensure target exists and is reset to empty array
  eval "$__var=()"
  # Read all lines, including a last line without a trailing newline
  while IFS= read -r __line || [[ -n "$__line" ]]; do
    # Escape for safe eval and assign to array element
    printf -v __q '%q' "$__line"
    eval "$__var[\$__i]=$__q"
    __i=$((__i+1))
  done
}

# --- unique tracking (portable: Bash 3.2-friendly) ---
# Keep ordered lists and enforce uniqueness with linear search
removed_list=()   # ordered record of first-seen removals
absent_list=()    # ordered record of first-seen absences

# Set-u safe array membership test via array NAME (no direct expansion if unset)
# usage: _arr_contains "needle" array_name
_arr_contains() {
  local needle="$1" arrname="$2"
  local x
  # Only expand if array is set (empty arrays still count as set)
  # ${var+_} expands to non-empty iff var is set
  if eval '[[ -n ${'"$arrname"'+_} ]]'; then
    eval 'for x in "${'"$arrname"'[@]}"; do
             [[ "$x" == "'"$needle"'" ]] && return 0
           done'
  fi
  return 1
}

_mark_removed() {
  local p="$1"
  [[ -z "$p" ]] && return 0
  if ! _arr_contains "$p" removed_list; then
    removed_list+=("$p")
  fi
}

_mark_absent() {
  local p="$1"
  [[ -z "$p" ]] && return 0
  if ! _arr_contains "$p" absent_list; then
    absent_list+=("$p")
  fi
}

removed_count() { echo "${#removed_list[@]}"; }
absent_count()  { echo "${#absent_list[@]}"; }

# =========================
# Helpers
# =========================

rm_one_user() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    if [[ -d "$path" && ! -L "$path" ]]; then return 1; fi
    printf '  rm %-59s … ' "$path"
    if rm -f -- "$path"; then
      echo "REMOVED"
      _mark_removed "$path"
      ((++removed_files))
    else
      echo "FAILED"
      ((++files_failed))
    fi

  else
    if _arr_contains "$path" removed_list; then
      printf "  rm %-59s … already removed earlier\n" "$path"
      return 0
    fi
    if _arr_contains "$path" absent_list; then
      printf "  rm %-59s … already noted absent\n" "$path"
      return 0
    fi
    printf "  rm %-59s … not present\n" "$path"
    _mark_absent "$path"
  fi
}

rm_one_root() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    if [[ -d "$path" && ! -L "$path" ]]; then return 1; fi
    printf '  rm %-59s … ' "$path"
    if $SUDO rm -f -- "$path"; then
      echo "REMOVED"
      _mark_removed "$path"
      ((++removed_files))
    else
      echo "FAILED"
      ((++files_failed))
    fi

  else
    if _arr_contains "$path" removed_list; then
      printf "  rm %-59s … already removed earlier\n" "$path"
      return 0
    fi

    if _arr_contains "$path" absent_list; then
      printf "  rm %-59s … already noted absent\n" "$path"
      return 0
    fi

    printf "  rm %-59s … not present\n" "$path"
    _mark_absent "$path"
  fi
}

# Linux: find & delete systemd wants/ symlinks of a unit
purge_sysunit_symlinks() {
  (( HAS_SYSTEMD )) || { echo 0; return 0; }
  local unit="${1:-}" count=0
  [[ -z "$unit" ]] && { echo 0; return 0; }
  local links=()
  readarray_portable links < <(find /etc/systemd/system -type l -lname "*$unit" 2>/dev/null || true)

  if ((${#links[@]})); then
    for l in "${links[@]}"; do
      printf '  rm %s … ' "$l"
      if $SUDO rm -f "$l"; then echo "REMOVED"; ((count++)); else echo "FAILED"; fi
    done
  fi
  echo "$count"
}

# Linux: stop/disable system unit (safe if missing)
stop_disable_sysunit() {
  (( HAS_SYSTEMD )) || return 0
  local unit="${1:-}"
  [[ -z "$unit" ]] && return 0
  printf '  systemctl stop %s … ' "$unit"
  if $SUDO systemctl stop "$unit" >/dev/null 2>&1; then echo "OK"; else echo "not running or unknown"; fi
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    printf '  systemctl kill %s … ' "$unit"; $SUDO systemctl kill "$unit" && echo "SIGTERM sent" || echo "FAILED"
  fi
  printf '  systemctl disable %s … ' "$unit"
  $SUDO systemctl disable "$unit" >/dev/null 2>&1 && echo "OK" || echo "not enabled or unknown"
  printf '  systemctl daemon-reload … '; $SUDO systemctl daemon-reload && echo "OK" || echo "FAILED"
  printf '  systemctl reset-failed %s … ' "$unit"; $SUDO systemctl reset-failed "$unit" >/dev/null 2>&1 && echo "OK" || echo "N/A"
}

# Linux user unit stop/disable
stop_disable_userunit() {
  (( HAS_SYSTEMD )) || return 0
  local unit="${1:-}"
  [[ -z "$unit" ]] && return 0
  printf '  systemctl --user stop %s … ' "$unit"
  if "${USRCTL[@]}" stop "$unit" >/dev/null 2>&1; then echo "OK"; else echo "not running or unknown"; fi
  printf '  systemctl --user disable %s … ' "$unit"
  if "${USRCTL[@]}" disable "$unit" >/dev/null 2>&1; then echo "OK"; else echo "not enabled or unknown"; fi
}

# Linux user wants/ symlink
purge_user_wants_link(){
  (( HAS_SYSTEMD )) || return 0
  local unit="$1"
  local link="${SYSTEMD_USER_DIR}/default.target.wants/${unit}"
  [[ -e "$link" || -L "$link" ]] || return 0
  printf '  rm %s … ' "$link"
  if rm -f -- "$link"; then
    echo "REMOVED"; ((++removed_unit_links))
  else
    echo "FAILED"
  fi
}

# # macOS: launchctl unload + plist removal (no-op if absent)
# # --- macOS plist removal registers as a removed file ---
# macos_unload_plist() {
#   local plist="$1"
#   [[ -f "$plist" ]] || { echo "  (launchd plist not present: $plist)"; return 0; }
#   printf '  launchctl unload %s … ' "$plist"
#   if launchctl unload "$plist" >/dev/null 2>&1; then echo "OK"; else echo "not loaded or unknown"; fi
#   rm_one_user "$plist"
#   ((++removed_units))
# }

# Disabled/Under Construction
# Custom export server (Linux/macOS)
# kill_export_server() {
#   local killed=0
#   if [[ -e "$WD_EXPORT_BIN" ]]; then
#     printf '  pkill -f -- %s … ' "$WD_EXPORT_BIN"
#     if $SUDO pkill -f -- "$WD_EXPORT_BIN" >/dev/null 2>&1; then echo "SIGTERM sent"; killed=1; else echo "N/A"; fi
#   fi

#   # Fallback: kill any listener on TCP:8080 that looks like export_http_server.py
#   if command -v lsof >/dev/null 2>&1; then
#     # need to rework to avoid mapfile (not good for bash 3.3)
#     mapfile -t pids < <(lsof -n -iTCP:8080 -sTCP:LISTEN -Fp 2>/dev/null | sed -n 's/^p//p' | sort -u)
#   elif (( IS_LINUX )) && command -v ss >/dev/null 2>&1; then
#     mapfile -t pids < <(ss -H -tlnp 2>/dev/null | awk '$4 ~ /:8080$/ {print $NF}' | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u)
#   else
#     pids=()
#   fi
#   for pid in "${pids[@]:-}"; do
#     if ps -o args= -p "$pid" 2>/dev/null | grep -Eq 'export_http_server\.py'; then
#       printf '  kill %s (export_http_server.py) … ' "$pid"
#       if $SUDO kill "$pid" 2>/dev/null; then echo "KILLED"; killed=1; else echo "FAILED"; fi
#     fi
#   done
#   (( killed )) && sleep 0.3 || true
# }

# Remove files listed in manifest.txt lines like:  FILE /path/to/file
rm_from_manifest_file_list() {
  local mf="$1"; [[ -s "$mf" ]] || return 0
  say "scanning manifest file list: $mf"
  while IFS= read -r line; do
    [[ "$line" =~ ^FILE[[:space:]]+(.+)$ ]] || continue
    target="${BASH_REMATCH[1]}"
    # Use root for system paths; user for everything else
    if [[ "$target" == /usr/* || "$target" == /etc/* || "$target" == /var/* || "$target" == /boot/* || "$target" == /Library/* ]]; then
      rm_one_root "$target" || true
    else
      rm_one_user "$target" || true
    fi
  done < "$mf"
}

# Linux: if we removed the tty unit, re-enable getty
reenable_getty_if_tty_unit_removed() {
  (( HAS_SYSTEMD )) || return 0
  if ! systemctl cat "${SYS_TTY_UNIT}" >/dev/null 2>&1; then
    printf '  systemctl enable --now getty@tty1.service … '
    $SUDO systemctl enable --now getty@tty1.service >/dev/null 2>&1 && echo "OK" || echo "FAILED (re-enable manually)"
  fi
}

# Remove the legacy PATH blocks (portable awk, works on macOS & Linux)
strip_path_block_legacy() {
  local f
  for f in "${WD_HOME}/.profile" "${WD_HOME}/.bashrc"; do
    [[ -f "$f" ]] || continue
    if grep -q '^# Ensure user-local bin is first on PATH' "$f"; then
      tmp="$(mktemp)"; awk '
        BEGIN{skip=0}
        /^# Ensure user-local bin is first on PATH$/ {skip=1}
        skip==1 && /^fi$/ {skip=0; next}
        skip==1 {next}
        {print}
      ' "$f" > "$tmp" && mv "$tmp" "$f"
      echo "  stripped PATH snippet from ${f}"
    fi
    if grep -q '^# Ensure user-local bin is on PATH (non-login shells)' "$f"; then
      tmp="$(mktemp)"; awk '
        BEGIN{skip=0}
        /^# Ensure user-local bin is on PATH \(non-login shells\)$/ {skip=1}
        skip==1 && /^fi$/ {skip=0; next}
        skip==1 {next}
        {print}
      ' "$f" > "$tmp" && mv "$tmp" "$f"
      echo "  stripped PATH (non-login) snippet from ${f}"
    fi
  done
}

# Remove our new, marked PATH block between BEGIN/END markers (portable)
PATH_MARK_BEGIN="# >>> ${WD_NAME} PATH begin >>>"
PATH_MARK_END="# <<< ${WD_NAME} PATH end <<<"

remove_marked_path_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  if grep -qF "$PATH_MARK_BEGIN" "$file" 2>/dev/null; then
    tmp="$(mktemp)"
    awk -v b="$PATH_MARK_BEGIN" -v e="$PATH_MARK_END" '
      BEGIN{skip=0}
      index($0,b){skip=1; next}
      index($0,e){skip=0; next}
      skip==1 {next}
      {print}
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    say "PATH snippet removed from $(basename "$file")"
  fi
}

rmdir_if_empty() { [[ -d "$1" ]] && rmdir -- "$1" 2>/dev/null || true; }

clean_ambient_dotfiles() {
  local removed=0
  rm -f "${WD_HOME}/.sudo_as_admin_successful" 2>/dev/null && echo "  removed: ~/.sudo_as_admin_successful" && removed=1 || true
  rm -f "${WD_HOME}/.wget-hsts" 2>/dev/null && echo "  removed: ~/.wget-hsts" && removed=1 || true
  if [[ -f "${WD_HOME}/.bash_history" ]] && [[ ! -s "${WD_HOME}/.bash_history" || -z "$(tr -d '[:space:]' < "${WD_HOME}/.bash_history")" ]]; then
    rm -f "${WD_HOME}/.bash_history" && echo "  removed: empty ~/.bash_history" && removed=1 || true
  fi
  return $removed
}

# =========================
# Run
# =========================
say "== ${WD_NAME} uninstaller engaged :: $(date) =="
echo "  os detected:    ${OS_NAME}"
echo "  target user:    ${WD_USER}"
echo "  target home:    ${WD_HOME}"

# --- early escape if not installed ---
if [[ ! -x "$WD_WRAPPER_BIN" && ! -f "$USR_TUI_UNIT_PATH" && ! -f "$SYS_TTY_UNIT_PATH" ]]; then
  echo "⛓️  [silo] (no wrapper, user unit, or system unit found at expected paths)"
  echo "⛓️  [silo] ${WD_NAME} not detected — nothing to uninstall."
  echo "⛓️  [silo] clearly you will not survive long in the wastes..."
  exit 0
fi

# Power Down Services / Agents
say "Powering down services/agents"

# Disabled for now: Custom Export Server
# # Common: kill ad-hoc export server
# say "  checking export server"
# kill_export_server

if (( HAS_SYSTEMD )); then
  "${USRCTL[@]}" show-environment >/dev/null 2>&1 || warn "  user systemd not available (no session/linger); best-effort"
  stop_disable_userunit "$USR_TUI_UNIT" || true
  say "  checking for ${SYS_TTY_UNIT} (tty-bound system unit)"
  stop_disable_sysunit "$SYS_TTY_UNIT" || true
  purge_user_wants_link "$USR_TUI_UNIT" || true

  # Remove any lingering systemd wants/ symlinks for the TTY service
  links_removed="$(purge_sysunit_symlinks "$SYS_TTY_UNIT")"
  links_removed="${links_removed##*$'\n'}"    # last line only
  links_removed="${links_removed//[^0-9]/}"   # strip non-digits
  links_removed="${links_removed:-0}"         # default 0
  removed_unit_links=$(( removed_unit_links + links_removed ))

  # Remove the unit files themselves
  say "  removing installed unit files"
  if [[ -f "$USR_TUI_UNIT_PATH" || -L "$USR_TUI_UNIT_PATH" ]]; then
    rm_one_user "$USR_TUI_UNIT_PATH"
    ((++removed_units))
  else
    echo "  (user unit not present: $USR_TUI_UNIT_PATH)"
  fi

  if [[ -f "$SYS_TTY_UNIT_PATH" || -L "$SYS_TTY_UNIT_PATH" ]]; then
    rm_one_root "$SYS_TTY_UNIT_PATH"
    ((++removed_units))
  else
    echo "  (system unit not present: $SYS_TTY_UNIT_PATH)"
  fi
elif (( IS_MACOS )); then
  # macOS auto-start cleanup is handled in a dedicated step later.
  :
else
  warn "  no known service manager detected; skipping service removal"
fi

# Revoke Linger (Linux only; only if we enabled it)
if (( HAS_SYSTEMD )); then
  say "Disabling linger (if we enabled it)"
  if [[ -f "$LINGER_MARKER" ]] || [[ "${WD_DISABLE_LINGER}" == "1" ]]; then
    printf '  loginctl disable-linger %s … ' "$WD_USER"
    if $SUDO loginctl disable-linger "$WD_USER" >/dev/null 2>&1; then
      echo "OK"
      rm_one_user "$LINGER_MARKER"
    else
      echo "FAILED"
    fi
  elif loginctl show-user "$WD_USER" 2>/dev/null | grep -q '^Linger=yes$'; then
    warn "linger is enabled for ${WD_USER} (not changed because we didn’t enable it)."
    echo "  disable manually with: loginctl disable-linger ${WD_USER}"
  fi
fi

# # Remove macOS Auto-Start
# say "Remove macOS Auto-Start"
# if (( IS_MACOS )); then
#   say "  macOS: removing all auto-start mechanisms (launchd + profile auto-enter)"

#   # 3.1) launchd login agents — broader sweep than MACOS_PLISTS
#   _macos_launchd_dir="${MACOS_LAUNCHD_DIR:-${WD_HOME}/Library/LaunchAgents}"
#   if [[ -d "${_macos_launchd_dir}" ]]; then
#     _plist_candidates=()
#     readarray_portable _plist_candidates < <(
#       find "${_macos_launchd_dir}" -maxdepth 1 -type f \( \
#         -name "io.silo11.writerdeck.plist"         -o \
#         -name "com.${WD_NAME}.tui.plist"           -o \
#         -name "com.${WD_NAME}.tty.plist"           -o \
#         -name "com.${WD_NAME}.*.plist"             -o \
#         -name "com.${WD_NAME}.*.plist" \
#       \) 2>/dev/null | sort -u
#     )
#     if ((${#_plist_candidates[@]})); then
#       for _p in "${_plist_candidates[@]}"; do
#         printf '  launchctl unload %s … ' "$_p"
#         if launchctl unload "$_p" >/dev/null 2>&1; then echo "OK"; else echo "not loaded or unknown"; fi
#         printf '  rm %s … ' "$_p"
#         if rm -f -- "$_p"; then echo "REMOVED"; ((++removed_units)); else echo "FAILED"; fi
#       done
#     else
#       say "  (no launch agents matching ${WD_NAME} found in ${_macos_launchd_dir})"
#     fi
#   else
#     say "  (LaunchAgents dir not present: ${_macos_launchd_dir})"
#   fi

#   # 3.2) Terminal auto-enter snippet in shell profiles
#   _auto_begin="# >>> ${WD_NAME} auto-launch (added by installer) >>>"
#   _auto_end="# <<< ${WD_NAME} auto-launch <<<"
#   _remove_autoenter_block() {
#     local file="$1"
#     [[ -f "$file" ]] || return 0
#     if grep -qF "$_auto_begin" "$file" 2>/dev/null; then
#       local tmp; tmp="$(mktemp)"
#       awk -v b="$_auto_begin" -v e="$_auto_end" '
#         BEGIN{skip=0}
#         index($0,b){skip=1; next}
#         index($0,e){skip=0; next}
#         skip==1 {next}
#         {print}
#       ' "$file" > "$tmp" && mv "$tmp" "$file"
#       say "  removed Terminal auto-enter hook from $(basename "$file")"
#     fi
#   }
#   _remove_autoenter_block "${WD_HOME}/.zprofile"
#   _remove_autoenter_block "${WD_HOME}/.bash_profile"
#   _remove_autoenter_block "${WD_HOME}/.zshrc"
# fi

# Remove Installed Logs, Symlinks, and Manifests
say "Removing logs, symlinks, and manifests"

REPO_DIR="${WD_HOME}/${WD_NAME}"
REPO_INSTALL_LOG="${REPO_DIR}/install.log"
REPO_UPDATE_LOG="${REPO_DIR}/update.log"

# Remove repo-side log symlinks if present
rm_one_user "$REPO_INSTALL_LOG"
rm_one_user "$REPO_UPDATE_LOG"

# Use the unified manifest BEFORE touching ~/.local/state/${WD_NAME}
rm_from_manifest_file_list "$MANIFEST_FILE"
files_removed_now="$(removed_count)"
files_absent_now="$(absent_count)"
printf "  — files so far: %d removed (unique), %d absent (unique), %d failed\n" \
  "$files_removed_now" "$files_absent_now" "$files_failed"

# Defensive sweep for common user-level files (only if still present)
say "  defensive sweep for common user-level files"
if [[ -e "${WD_WRAPPER_BIN}" || -L "${WD_WRAPPER_BIN}" ]]; then
  rm_one_user "${WD_WRAPPER_BIN}" || true
fi

# NOTE: Do NOT delete ${WD_HOME}/.local/state/${WD_NAME} here.
# Postpone directory removals to [8/8] so the files dont show up as "absent".
# Same for ~/.config/${WD_NAME}: postpone to [8/8] for consistent accounting.

# Custom export server: disabled/under constuction
# rm_one_user "${WD_EXPORT_BIN}"            || true

# Clean User Shell Environment (PATH snippets)
say "Stripping PATH snippets from shell profiles"
strip_path_block_legacy

# Remove marked PATH blocks from common init files (bash & zsh)
for f in \
  "${WD_HOME}/.profile" \
  "${WD_HOME}/.bashrc" \
  "${WD_HOME}/.bash_profile" \
  "${WD_HOME}/.zprofile" \
  "${WD_HOME}/.zshrc"
do
  remove_marked_path_block "$f"
done

# Restore init/service manager state
say "Restoring system state"

if (( HAS_SYSTEMD )); then
  $SUDO systemctl daemon-reload || true
  "${USRCTL[@]}" daemon-reload || true
  say "  re-enabling getty (console login) if we owned tty1"
  reenable_getty_if_tty_unit_removed
elif (( IS_MACOS )); then
  # Nothing global to reload for launchd; unloading plists was enough
  :
fi

# Package cleanup (unified manifests) ---
say "Package cleanup"
purged_pkgs=0
if [[ -s "${PKG_MANAGER}" && -s "${PKG_PURGE}" ]]; then
  mgr="$(cat "${PKG_MANAGER}")"
  pur=()
  readarray_portable pur < "${PKG_PURGE}"

  case "$mgr" in
    apt)
      # Load preexisting (if available) to avoid purging things that were on the box already.
      pre=()
      if [[ -s "${PKG_PREEXIST}" ]]; then
        readarray_portable pre < "${PKG_PREEXIST}"
      fi

      # Build a safe purge list:
      #   only items in pkg.purge
      #   AND currently installed
      #   AND NOT listed as preexisting at install time
      pkgs_to_purge=()
      for p in "${pur[@]}"; do
        [[ -n "$p" ]] || continue
        # skip if recorded as preexisting
        skip=0
        for q in "${pre[@]}"; do
          [[ "$p" == "$q" ]] && { skip=1; break; }
        done
        (( skip )) && continue
        # only purge if still installed now
        if dpkg -s "$p" >/dev/null 2>&1; then
          pkgs_to_purge+=("$p")
        fi
      done

      if ((${#pkgs_to_purge[@]})); then
        echo "  packages installed by ${WD_NAME} (verified safe to purge): ${pkgs_to_purge[*]}"
        $SUDO apt-get purge -y "${pkgs_to_purge[@]}" || true
        purged_pkgs=${#pkgs_to_purge[@]}
      else
        echo "  (nothing to purge safely)"
      fi

      # Follow with a conservative autoremove to shed orphaned dependencies
      echo "  running: sudo apt-get autoremove -y"
      $SUDO apt-get autoremove -y || true
      ;;

    brew)
      if ((${#pur[@]})); then
        echo "  packages installed by ${WD_NAME}: ${pur[*]}"
        brew uninstall --ignore-dependencies "${pur[@]}" || true
        purged_pkgs=${#pur[@]}
      else
        echo "  (nothing recorded in pkg.purge)"
      fi
      ;;

    *)
      echo "  (unknown package manager: ${mgr}; skipping)"
      ;;
  esac
else
  echo "  (no unified pkg manager/purge files at ${MANIFEST_DIR}; skipping)"
fi

# Final Sweep (unified) ---
say "Final sweep"

# If the manifest directory is still present, remove individual files first.
if [[ -d "${MANIFEST_DIR}" ]]; then
  rm_one_user "${MANIFEST_FILE}"
  rm_one_user "${PKG_MANAGER}"
  rm_one_user "${PKG_REQUIRED}"
  rm_one_user "${PKG_PREEXIST}"
  rm_one_user "${PKG_PURGE}"
  rm_one_user "${LINGER_MARKER}"
  rmdir_if_empty "${MANIFEST_DIR}"
else
  say "  (manifest dir already removed earlier; skipping file-level cleanup)"
fi

# Now it’s safe to remove config & state directories entirely
rm -rf "${WD_HOME}/.config/${WD_NAME}" "${WD_MANIFEST_ROOT}" 2>/dev/null || true

# Optional deep clean (conservative)
if [[ "$WD_CLEAN_DOTFILES" == "1" ]]; then
  say "deep clean: removing ambient dotfiles"
  clean_ambient_dotfiles || true
fi

# Remove empty dirs we might’ve created
rmdir_if_empty "${SYSTEMD_USER_DIR}/default.target.wants"
rmdir_if_empty "${SYSTEMD_USER_DIR}"
rmdir_if_empty "${BIN_DIR}"
rmdir_if_empty "${WD_HOME}/.local/state"
rmdir_if_empty "${WD_HOME}/.local"
rmdir_if_empty "${WD_HOME}/.config/${WD_NAME}"
rmdir_if_empty "${WD_HOME}/.config"

# # macOS: tidy launchd dir if empty
# if (( IS_MACOS )); then
#   rmdir_if_empty "${MACOS_LAUNCHD_DIR}"
# fi

# Remove ~/silo11writerdeck if it was a symlink we created
REPO_LINK="${WD_HOME}/${WD_NAME}"
if [[ -L "$REPO_LINK" ]]; then
  printf '  rm %s … ' "$REPO_LINK"
  if rm -f -- "$REPO_LINK"; then
    echo "REMOVED"
    _mark_removed "$REPO_LINK"
  else
    echo "FAILED"
  fi
fi

# =========================
# Summary
# =========================
say "— summary —"
printf "  units/agents removed: %d (unit/plist files), %d (wants/ symlinks)\n" "$removed_units" "$removed_unit_links"
# --- Summary using unique removed count ---
files_removed="$(removed_count)"
files_absent="$(absent_count)"
printf "  files:                %d removed (unique), %d absent, %d failed\n" \
  "$files_removed" "$files_absent" "$files_failed"

# Show the removed file list
if (( files_removed > 0 )); then
  echo "  removed files:"
  for f in "${removed_list[@]}"; do
    echo "    - $f"
  done
fi
if (( files_absent > 0 )); then
  echo "  absent files:"
  for f in "${absent_list[@]}"; do
    echo "    - $f"
  done
fi
echo   "  packages purged:     $purged_pkgs"
say "== uninstallation complete :: good luck out there in the wastes =="
say " delete your local '${WD_NAME}' directory/folder for complete removal "
