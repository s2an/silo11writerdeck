#!/usr/bin/env bash
# File: update-silo11writerdeck.sh
# Purpose: Idempotent updater aligned with install-silo11writerdeck.sh
# Adds explicit takeover mode switching: [--system], [--user], [--user-linger], [--none]
# Usage:
#   bash update-silo11writerdeck.sh [--dry-run] [--system] [--user] [--user-linger] [--none] [/path/to/repo]

# Updates user-level bits only: wrapper (~/.local/bin/silo11writerdeck),
# export_http_server.py (soft-skip, under construction), and user unit (~/.config/systemd/user/silo11writerdeck-tui.service).
# Also (optionally) reconciles root manifest to ensure clean uninstalls across multiple installer runs:
#   /var/lib/silo11writerdeck/packages.purge := packages.txt - preexisting.txt
#
# Exit codes: 0 OK, non-zero on failure.

# # =====================================================================
# # Strict Mode & Logging
# # =====================================================================
set -Eeuo pipefail
umask 022

# # =====================================================================
# # Single Source of Truth (Names, User, Home)
# # =====================================================================
WD_NAME="silo11writerdeck"
WD_USER="${WD_USER:-${SUDO_USER:-$(id -un)}}"
WD_HOME="${WD_HOME-}"
if [[ -z "${WD_HOME}" ]]; then
  if command -v getent >/dev/null 2>&1; then
    WD_HOME="$(getent passwd "$WD_USER" | awk -F: '{print $6}')"
  fi
  WD_HOME="${WD_HOME:-$(eval echo "~${WD_USER}")}"
fi

STATE_DIR="${XDG_STATE_HOME:-$WD_HOME/.local/state}/${WD_NAME}"
LOCK_DIR="${STATE_DIR}/update.lock"
mkdir -p "${STATE_DIR}"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  echo "⛔  another update is already running (${LOCK_DIR})." >&2
  exit 3
fi

cleanup_lock(){ rmdir "${LOCK_DIR}" 2>/dev/null || true; }
cleanup_tmp(){ [[ -n "${TMP_ROOT:-}" && -d "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT" || true; }

# ensure both cleanups run on EXIT
trap 'cleanup_lock; cleanup_tmp' EXIT

say(){ echo "⛓️  [silo:update] $*"; }
warn(){ echo "⚠️  $*"; }
err(){ echo "⛔  $*" >&2; }

trap 'rc=$?; cmd=$BASH_COMMAND; say "ERROR: ${cmd} exited with $rc"; exit $rc' ERR

# # =====================================================================
# # Safety Guard (No Root)
# # =====================================================================
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  say "ERROR: do not run this updater as root."
  echo "       Run it as your normal user. It will use sudo only for manifest fix-ups."
  exit 1
fi

# # =====================================================================
# # OS Detection
# # =====================================================================
IS_MACOS=0
IS_LINUX=0
case "$(uname -s)" in
  Darwin) IS_MACOS=1 ;;
  Linux)  IS_LINUX=1 ;;
esac

# # =====================================================================
# # Updater Flags (Mode/Restart/Dry-run) & SRC Selection
# # =====================================================================
# Future Improvement: Better UX would be to prompt the user if they want to change during the update
DRY_RUN=0
SYSTEM_TAKEOVER=0
USER_TAKEOVER=0
USER_LINGER_TAKEOVER=0
NO_TAKEOVER=0
SRC_DEFAULT="${WD_HOME}/${WD_NAME}"
SRC="${WD_SRC:-$SRC_DEFAULT}"

POSITIONAL_SRC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --system)
      SYSTEM_TAKEOVER=1; USER_TAKEOVER=0; USER_LINGER_TAKEOVER=0; NO_TAKEOVER=0; shift ;;
    --user)
      SYSTEM_TAKEOVER=0; USER_TAKEOVER=1; USER_LINGER_TAKEOVER=0; NO_TAKEOVER=0; shift ;;
    --user-linger)
      SYSTEM_TAKEOVER=0; USER_TAKEOVER=0; USER_LINGER_TAKEOVER=1; NO_TAKEOVER=0; shift ;;
    --none)
      SYSTEM_TAKEOVER=0; USER_TAKEOVER=0; USER_LINGER_TAKEOVER=0; NO_TAKEOVER=1; shift ;;
    --)
      shift; while [[ $# -gt 0 ]]; do POSITIONAL_SRC="$1"; shift; done; break ;;
    *)            POSITIONAL_SRC="$1"; shift ;;
  esac
done
[[ -n "$POSITIONAL_SRC" ]] && SRC="$POSITIONAL_SRC"

# # =====================================================================
# # Derived Paths & Important Files
# # =====================================================================
# Paths
APP_DIR="${WD_HOME}/${WD_NAME}"
BIN_DIR="${WD_HOME}/.local/bin"
CFG_DIR="${WD_HOME}/.config/${WD_NAME}"
SYSTEMD_USER_DIR="${WD_HOME}/.config/systemd/user"
WRAPPER_BIN="${BIN_DIR}/${WD_NAME}"
USER_UNIT="${SYSTEMD_USER_DIR}/${WD_NAME}-tui.service"

# Custom Export Server: Disabled/under construction
WD_ENABLE_EXPORT="${WD_ENABLE_EXPORT:-0}"
# Source files
SRC_TUI_DIR="${SRC}/tui"
SRC_TUI_MENU="${SRC_TUI_DIR}/menu.py"
SRC_EXPORT="${SRC}/http_server/export_http_server.py"
SRC_USER_UNIT="${SRC}/systemd/user/${WD_NAME}-tui.service"
SRC_SYS_TTY_UNIT="${SRC}/systemd/system/${WD_NAME}-tty.service"

# System unit identifiers (unchanged)
SYS_TTY_NAME="${WD_NAME}-tty.service"
SYS_TTY_PATH="/etc/systemd/system/${SYS_TTY_NAME}"

# Unified manifest root (same as installer)
: "${WD_MANIFEST_ROOT:=${XDG_STATE_HOME:-$WD_HOME/.local/state}/${WD_NAME}}"
MANIFEST_DIR="${WD_MANIFEST_ROOT}/manifest"
MANIFEST_FILE="${MANIFEST_DIR}/manifest.txt"

# Package manifest files (OS-neutral names)
PKG_MANAGER="${MANIFEST_DIR}/pkg.manager"       # "apt" | "brew" | etc.
PKG_REQUIRED="${MANIFEST_DIR}/pkg.required"     # authoritative required set
PKG_PREEXIST="${MANIFEST_DIR}/pkg.preexisting"  # present before install
PKG_PURGE="${MANIFEST_DIR}/pkg.purge"           # computed: required - preexisting

# Linger marker lives alongside manifest
LINGER_MARKER="${MANIFEST_DIR}/linger.enabled"

# File logging
LOG="${STATE_DIR}/update.log"
mkdir -p "$(dirname "$LOG")" "$BIN_DIR" "$CFG_DIR" "$STATE_DIR" "$SYSTEMD_USER_DIR" "$MANIFEST_DIR"
exec > >(tee -a "$LOG") 2>&1
echo "== [silo] ${WD_NAME} update uplink opened :: $(date) =="

# # =====================================================================
# # Install Detection (Early Short-Circuit if Not Installed)
# # =====================================================================
is_cmd(){ command -v "$1" >/dev/null 2>&1; }
is_wrapper_present(){ [[ -x "$WRAPPER_BIN" ]]; }
is_user_unit_present(){
  [[ -f "$USER_UNIT" ]] && return 0
  if [[ $IS_LINUX -eq 1 ]] && is_cmd systemctl; then
    systemctl --user is-enabled --quiet "$(basename "$USER_UNIT")" 2>/dev/null
    return $?
  fi
  return 1
}
is_sys_tty_enabled(){
  if [[ $IS_LINUX -eq 1 ]] && is_cmd systemctl; then
    systemctl is-enabled --quiet "${SYS_TTY_NAME}" >/dev/null 2>&1
    return $?
  fi
  return 1
}
is_installed(){ is_wrapper_present || is_user_unit_present || is_sys_tty_enabled; }

# installers (user/root)
install_file_root() {
  local src="$1"
  local dst="$2"
  local mode="${3:-644}"

  if [[ ! -f "$src" ]]; then
    warn "missing source: $src (skipped)"
    return 0
  fi

  say "updating (root): $dst"

  if [[ ${DRY_RUN:-0} -eq 1 ]]; then
    say "[dry-run] sudo mkdir -p \"$(dirname "$dst")\""
    say "[dry-run] sudo install -m \"$mode\" \"$src\" \"$dst\""
    return 0
  fi

  sudo mkdir -p "$(dirname "$dst")"
  sudo install -m "$mode" "$src" "$dst"
}
 
# --- is installed gate ---
if ! is_installed; then
  say "not installed for user '${WD_USER}' (no wrapper/unit/tty)."
  say "run the installer first:  bash install-${WD_NAME}.sh"
  exit 0
fi

# # =====================================================================
# # Repo Symlink
# # =====================================================================

# Require existing source tree; direct user to installer if missing
if [[ ! -d "$SRC" ]]; then
  err "source path not found: $SRC"
  say "Clone down the repo and run the installer instead:  bash install-${WD_NAME}.sh"
  exit 1
fi

# Repo-side log symlink (best-effort)
if [[ -w "${SRC}" ]]; then
  # macOS lacks -T; do rm+ln for portability
  rm -f "${SRC}/update.log" && ln -sfn "${LOG}" "${SRC}/update.log"
  say "repo log link set: ${SRC}/update.log → ${LOG}"
else
  say "note: repo path not writable; skipping ${SRC}/update.log symlink"
fi

# Keep %h/silo11writerdeck stable for units
if [[ "$SRC" != "$APP_DIR" ]]; then
  if [[ -L "$APP_DIR" || -f "$APP_DIR" ]]; then
    rm -f "$APP_DIR"
  elif [[ -d "$APP_DIR" ]]; then
    rmdir "$APP_DIR" 2>/dev/null || true  # only if empty; don’t nuke user content
  fi
  ln -sfn "$SRC" "$APP_DIR"
  say "link set (SRC != ${APP_DIR}): ${APP_DIR} → ${SRC}"
fi

say "SRC=${SRC}"

# # =====================================================================
# # Mode & Linger Detection / Requests
# # =====================================================================
# ---------- Mode & linger detectors ----------
current_mode(){
  # returns: system|user|none
  if [[ $IS_LINUX -eq 1 ]] && is_cmd systemctl && systemctl is-enabled --quiet "${SYS_TTY_NAME}" >/dev/null 2>&1; then
    echo "system"; return 0
  fi
  if [[ $IS_LINUX -eq 1 ]] && is_cmd systemctl && systemctl --user is-enabled --quiet "$(basename "$USER_UNIT")" 2>/dev/null; then
    echo "user"; return 0
  fi
  echo "none"
}

user_linger_enabled(){
  # returns 0 if linger=yes, 1 otherwise; non-linux treated as disabled
  if [[ $IS_LINUX -ne 1 ]] || ! is_cmd loginctl; then return 1; fi
  local l
  l="$(loginctl show-user "$WD_USER" 2>/dev/null | awk -F= '$1=="Linger"{print $2}')" || true
  [[ "$l" == "yes" ]]
}

requested_mode=""
requested_linger=0
if   [[ $SYSTEM_TAKEOVER -eq 1 ]]; then requested_mode="system"
elif [[ $USER_LINGER_TAKEOVER -eq 1 ]]; then requested_mode="user"; requested_linger=1
elif [[ $USER_TAKEOVER -eq 1 ]]; then requested_mode="user"
elif [[ $NO_TAKEOVER -eq 1 ]]; then requested_mode="none"
fi

# Takeover Mode Request Tracking
MODE_REQUEST="${requested_mode:-}"
LINGER_REQUEST="${requested_linger:-0}"

if [[ -n "$requested_mode" ]]; then
  say "mode requested: ${requested_mode}$([[ $requested_linger -eq 1 ]] && echo ' (linger)')"
fi

# ---------- Do not exit on already-in-mode; just remember it ----------
ALREADY_IN_REQUESTED_MODE=0
if [[ -n "${requested_mode:-}" ]]; then
  curr="$(current_mode)"
  if [[ "$curr" == "$requested_mode" ]]; then
    if [[ "$requested_mode" == "user" ]]; then
      if [[ $requested_linger -eq 1 ]]; then
        if user_linger_enabled; then ALREADY_IN_REQUESTED_MODE=1; fi
      else
        if ! user_linger_enabled; then ALREADY_IN_REQUESTED_MODE=1; fi
      fi
    else
      ALREADY_IN_REQUESTED_MODE=1
    fi
    [[ $ALREADY_IN_REQUESTED_MODE -eq 1 ]] && say "mode already correct; proceeding with repo update anyway."
  fi
fi

# # =====================================================================
# # Manifest Helpers & File Ops (User/Root) + systemd helpers
# # =====================================================================
manifest_add_file() {
  # usage: manifest_add_file /absolute/path
  local target="$1"
  [[ -n "$target" ]] || return 0

  mkdir -p "${MANIFEST_DIR}"

  # Ensure manifest file exists, but DO NOT truncate on each call
  if [[ ! -f "${MANIFEST_FILE}" ]]; then
    : > "${MANIFEST_FILE}" 2>/dev/null || true
  fi

  # Append only if not already present
  if ! grep -qxF "FILE ${target}" "${MANIFEST_FILE}" 2>/dev/null; then
    printf 'FILE %s\n' "${target}" >> "${MANIFEST_FILE}"
  fi
}

write_file_user(){ # content dest mode
  local content="$1" dst="$2" mode="${3:-644}"
  local tmp
  tmp="$(mktemp)" || { err "mktemp failed"; return 1; }
  printf '%s\n' "$content" > "$tmp"
  install_file_user "$tmp" "$dst" "$mode"
  rm -f "$tmp"
}

prep_script_user(){ # path -> normalize endings + chmod +x
  local p="$1"
  [[ $DRY_RUN -eq 1 ]] && { say "[dry-run] prep_script_user $p"; return 0; }
  if [[ $IS_MACOS -eq 1 ]]; then
    # BSD sed: use -i '' and ERE flag ordering
    sed -i '' -E 's/\r$//' "$p" 2>/dev/null || true
    sed -i '' -E $'1s/^\xEF\xBB\xBF//' "$p" 2>/dev/null || true
  else
    sed -i -r 's/\r$//' "$p" 2>/dev/null || true
    sed -i -r $'1s/^\xEF\xBB\xBF//' "$p" 2>/dev/null || true
  fi
  chmod +x "$p"
}

install_file_user(){ # src dest mode
  local src="$1" dst="$2" mode="${3:-644}"

  if [[ ! -f "$src" ]]; then
    warn "missing source: $src (skipped)"
    return 0
  fi

  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    say "unchanged: $(basename "$dst")"
    return 0
  fi

  say "updating: $dst"

  if [[ ${IS_LINUX:-0} -eq 1 ]]; then
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
      say "[dry-run] install -D -m \"$mode\" \"$src\" \"$dst\""
      return 0
    fi
    install -D -m "$mode" "$src" "$dst"
  else
    if [[ ${DRY_RUN:-0} -eq 1 ]]; then
      say "[dry-run] mkdir -p \"$(dirname "$dst")\""
      say "[dry-run] install -m \"$mode\" \"$src\" \"$dst\""
      return 0
    fi
    mkdir -p "$(dirname "$dst")"
    install -m "$mode" "$src" "$dst"
  fi
}

restart_user_unit(){ # unit-name
  local unit="$1"
  if [[ ${IS_LINUX:-0} -ne 1 ]] || ! command -v systemctl >/dev/null 2>&1; then
    say "systemctl not available (skipping restart of $unit)"
    return 0
  fi
  if systemctl --user is-enabled --quiet "$unit"; then
    say "restarting $unit (user)"
    [[ $DRY_RUN -eq 1 ]] && { say "[dry-run] systemctl --user restart $unit"; return 0; }
    systemctl --user restart "$unit" || warn "restart failed for $unit"
  else
    say "$unit not enabled; not restarting"
  fi
}

daemon_reload_enable_user(){ # unit-name
  local unit_name="$1"
  if [[ ${IS_LINUX:-0} -ne 1 ]] || ! command -v systemctl >/dev/null 2>&1; then
    say "systemctl not available (skipping user daemon-reload/enable for $unit_name)"
    return 0
  fi
  if is_sys_tty_enabled; then
    say "systemd (user) daemon-reload only (TTY mode detected)"
    [[ $DRY_RUN -eq 1 ]] && { say "[dry-run] systemctl --user daemon-reload && systemctl --user disable $unit_name"; return 0; }
    systemctl --user daemon-reload || warn "daemon-reload (user) failed (no session/linger?)"
    systemctl --user disable "$unit_name" >/dev/null 2>&1 || true
    return 0
  fi
  say "systemd (user) daemon-reload + reenable: $unit_name"
  [[ $DRY_RUN -eq 1 ]] && { say "[dry-run] systemctl --user daemon-reload && systemctl --user reenable $unit_name"; return 0; }
  systemctl --user daemon-reload || warn "daemon-reload (user) failed (no session/linger?)"
  systemctl --user reenable "$unit_name" >/dev/null 2>&1 || true
}

# --- mode helpers: stage/enable/disable/clean ---
stage_user_unit_from_repo(){
  if [[ ! -f "$SRC_USER_UNIT" ]]; then
    warn "repo user unit missing: $SRC_USER_UNIT (skipping)"
    return 1
  fi
  install_file_user "$SRC_USER_UNIT" "$USER_UNIT" 0644
  daemon_reload_enable_user "$(basename "$USER_UNIT")"
}

disable_user_unit(){
  if [[ ${IS_LINUX:-0} -eq 1 ]] && is_cmd systemctl; then
    systemctl --user disable "$(basename "$USER_UNIT")" >/dev/null 2>&1 || true
    systemctl --user stop    "$(basename "$USER_UNIT")" >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f "$USER_UNIT" 2>/dev/null || true
}

# Revert to method below this one after .service template expansion fix is resolved
stage_sys_tty_unit_from_repo(){
  if [[ ! -f "$SRC_SYS_TTY_UNIT" ]]; then
    warn "repo system tty unit missing: $SRC_SYS_TTY_UNIT (skipping)"
    return 1
  fi
  if grep -Eq '\$\{WD_(HOME|USER)\}' "$SRC_SYS_TTY_UNIT"; then
    err "system unit contains \${WD_HOME}/\${WD_USER} placeholders; updater does not render them."
    err "Use the installer to switch to --system, or ship a unit that uses systemd specifiers (User=… + %h)."
    return 2
  fi
  install_file_root "$SRC_SYS_TTY_UNIT" "$SYS_TTY_PATH" 0644
  if [[ ${IS_LINUX:-0} -eq 1 ]] && is_cmd systemctl; then
    [[ $DRY_RUN -eq 1 ]] && { say "[dry-run] sudo systemctl daemon-reload"; } || sudo systemctl daemon-reload
  fi
}
# This is the .service template expansion fix method to use after the resolution from the code block above
# stage_sys_tty_unit_from_repo(){
#   if [[ ! -f "$SRC_SYS_TTY_UNIT" ]]; then
#     warn "repo system tty unit missing: $SRC_SYS_TTY_UNIT (skipping)"
#     return 1
#   fi
#   install_file_root "$SRC_SYS_TTY_UNIT" "$SYS_TTY_PATH" 0644
#   if [[ ${IS_LINUX:-0} -eq 1 ]] && is_cmd systemctl; then
#     [[ $DRY_RUN -eq 1 ]] && { say "[dry-run] sudo systemctl daemon-reload"; } || sudo systemctl daemon-reload
#   fi
# }

disable_sys_tty_unit(){
  if [[ ${IS_LINUX:-0} -eq 1 ]] && is_cmd systemctl; then
    sudo systemctl disable --now "$SYS_TTY_NAME" >/dev/null 2>&1 || true
    sudo systemctl reset-failed "$SYS_TTY_NAME" >/dev/null 2>&1 || true
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  sudo rm -f "$SYS_TTY_PATH" 2>/dev/null || true
}

apply_mode_system(){
  # Comes from the templating and the system not liking %h during install and now {WD_HOME} during update
  say "System takeover update is not supported here. Please uninstall then reinstall with --system."
  say "No changes applied; continuing without switching mode."
  # Remove the return 2 below after fix and uncomment methods
  return 2
  # # --- Disabled until template expansion is fixed ---
  # disable_user_unit
  # stage_sys_tty_unit_from_repo || return 1

  # track tty unit file for uninstaller (ONLY after stage succeeds)
  if [[ ${IS_LINUX:-0} -eq 1 && -f "${SYS_TTY_PATH}" ]]; then
    manifest_add_file "${SYS_TTY_PATH}"
  fi

  if [[ ${IS_LINUX:-0} -eq 1 ]] && is_cmd systemctl; then
    [[ $DRY_RUN -eq 1 ]] && { say "[dry-run] sudo systemctl enable --now $SYS_TTY_NAME"; } \
                          || sudo systemctl enable --now "$SYS_TTY_NAME"
  fi
  if [[ -f "${LINGER_MARKER}" ]]; then
    [[ $DRY_RUN -eq 1 ]] && say "[dry-run] sudo rm -f ${LINGER_MARKER}" || sudo rm -f "${LINGER_MARKER}"
  fi
}

apply_mode_user(){
  say "applying mode: USER"
  disable_sys_tty_unit
  stage_user_unit_from_repo || return 1

  if [[ ${LINGER_REQUEST:-0} -eq 1 && ${IS_LINUX:-0} -eq 1 ]] && is_cmd loginctl; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "[dry-run] loginctl enable-linger ${WD_USER}"
      say "[dry-run] install -D -m 0644 /dev/null ${LINGER_MARKER}"
    else
      loginctl enable-linger "${WD_USER}" >/dev/null 2>&1 || warn "could not enable linger for ${WD_USER}"
      install -D -m 0644 /dev/null "${LINGER_MARKER}"
    fi
  fi

  restart_user_unit "$(basename "$USER_UNIT")"
}

apply_mode_none(){
  say "applying mode: NONE (no autostart)"
  disable_user_unit
  disable_sys_tty_unit
  # --- clear linger marker (leaves actual linger state untouched) ---
  if [[ -f "${LINGER_MARKER}" ]]; then
    [[ $DRY_RUN -eq 1 ]] && say "[dry-run] rm -f ${LINGER_MARKER}" || rm -f "${LINGER_MARKER}"
  fi
}

# # =====================================================================
# # Overwrite silo11writerdeck directory (preserve !save_files_here)
# # =====================================================================
# Preflight guard if rsync is not installed
command -v rsync >/dev/null 2>&1 || { err "rsync not found (required)"; exit 2; }

# Rsync to working dir with deletes
sync_repo_into_src() {
  local from_dir="$1"
  local to_dir="${SRC}"
  mkdir -p "${to_dir}"

  # Use --delete-after so we don't momentarily break during transfer
  rsync ${DRY_RUN:+--dry-run} -aiv --delete-after \
    --exclude='.git/' \
    --exclude='**/.git' --exclude='**/.git/**' \
    --exclude='.github/' \
    --exclude='.venv/' \
    --exclude='\!save_files_here/**' \
    --exclude='!save_files_here/**' \
    "${from_dir}/" "${to_dir}/"
}

# --- (BSD/GNU safe; no xargs -r) ---
normalize_owner() {
  command -v chown >/dev/null 2>&1 || return 0
  # change only top-level items excluding the protected dir
  find "${SRC}" -mindepth 1 -maxdepth 1 ! -name '!save_files_here' -exec chown -R "${WD_USER}:${WD_USER}" {} +
}

# # =====================================================================
# # Repo Sync Configuration (URL/Branch detection + clone helper)
# # =====================================================================

# Installation dir (the working copy you want to overwrite)
: "${SRC:=${WD_HOME}/${WD_NAME}}"

# Remote + branch. If SRC is a git repo, prefer its origin/branch; else use env/fallbacks.
: "${WD_REPO_URL:=}"
: "${WD_REPO_BRANCH:=main}"

# Try to infer url/branch from existing repo (if present)
if [ -d "${SRC}/.git" ] && command -v git >/dev/null 2>&1; then
  _url="$(git -C "${SRC}" remote get-url origin 2>/dev/null || true)"
  _branch="$(git -C "${SRC}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  [ -n "${_url}" ] && WD_REPO_URL="${WD_REPO_URL:-${_url}}"
  [ -n "${_branch}" ] && WD_REPO_BRANCH="${WD_REPO_BRANCH:-${_branch}}"
fi

# Final guard: require a URL unless the SRC is already a repo. If neither, soft-skip.
if [ -z "${WD_REPO_URL}" ] && [ ! -d "${SRC}/.git" ]; then
  warn "No repository URL detected and ${SRC} is not a git repo; skipping remote update."
  WD_REPO_URL=""
fi

# Optional shallow depth
: "${WD_REPO_DEPTH:=1}"

# ===== Fetch latest into a clean temp clone (shallow, no submodules) =====
fetch_latest_repo() {
  git_available || { err "git not found"; return 2; }
  if ! remote_reachable "${WD_REPO_URL}" "${WD_REPO_BRANCH}"; then
    return 65  # custom: remote not reachable/offline
  fi
  TMP_ROOT="$(mktemp -d -t ${WD_NAME}.XXXXXX)"
  TMP_REPO="${TMP_ROOT}/repo"
  say "cloning ${WD_REPO_URL}#${WD_REPO_BRANCH} → ${TMP_REPO}"
  if [[ "${WD_REPO_DEPTH}" -gt 0 ]]; then
    git clone --depth="${WD_REPO_DEPTH}" --branch "${WD_REPO_BRANCH}" \
      "${WD_REPO_URL}" "${TMP_REPO}"
  else
    git clone --branch "${WD_REPO_BRANCH}" "${WD_REPO_URL}" "${TMP_REPO}"
  fi
  echo "${TMP_REPO}"
}

# # =====================================================================
# # Repo Pull + Replace + Optional Restart
# # =====================================================================
# ===== Helper: skip if repo is unattainable, but contine with the rest
git_available(){ command -v git >/dev/null 2>&1; }

remote_reachable(){
  # Return 0 if we can see the remote; 1 otherwise (offline, DNS, firewall, bad URL, etc.)
  # Use a short timeout so we fail fast.
  local url="$1" branch="$2"
  [[ -z "$url" ]] && return 1
  git_available || return 1
  GIT_ASKPASS=/bin/true git ls-remote --heads --exit-code --timeout=8 "$url" "$branch" >/dev/null 2>&1
}

explain_offline_skip(){
  warn "cannot reach repo (${WD_REPO_URL:-unset}) or git unavailable; skipping pull and leaving local files as-is."
  warn "A full OTA update requires an internet connection."
}

# ===== Main: pull + replace (preserve !save_files_here) =====
run_repo_pull_replace() {
  local tmp_repo
  tmp_repo="$(fetch_latest_repo)" || {
    rc=$?
    if [[ $rc -eq 65 ]]; then
      explain_offline_skip
      return 0
    fi
    if [[ $rc -eq 2 ]]; then
      err "git is required for remote updates; install git or set WD_REPO_URL later."
      return 0
    fi
    return $rc
  }
  sync_repo_into_src "${tmp_repo}"
  normalize_owner
  say "repo sync complete → ${SRC}"
}

# === invoke ===
run_repo_pull_replace

# # =====================================================================
# # Wrapper Refresh (CLI launcher)
# # =====================================================================
say "refreshing launcher at: ${WRAPPER_BIN}"
WRAPPER_CONTENT='#!/usr/bin/env bash
# silo11writerdeck: launch the silo11writerdeck TUI from anywhere
set -Eeuo pipefail

# Resolve home in case this is run via sudo -E
WD_USER="${WD_USER:-${SUDO_USER:-$(id -un)}}"
WD_HOME="$(eval echo "~${WD_USER}")"

APP_DIR="${WD_HOME}/silo11writerdeck"
if [[ ! -d "${APP_DIR}" ]]; then
  echo "⛔ silo11writerdeck: app directory not found at ${APP_DIR}" >&2
  exit 1
fi

cd "${APP_DIR}"
exec /usr/bin/env python3 -m tui.menu "$@"
'
write_file_user "$WRAPPER_CONTENT" "$WRAPPER_BIN" 755
prep_script_user "$WRAPPER_BIN"

# Add to manifest for uninstaller tracking
manifest_add_file "${WRAPPER_BIN}"

# # =====================================================================
# # User Unit Maintenance (if present) — No Mode Change Requested
# # =====================================================================
# If no explicit mode change requested, keep previous behavior:
if [[ ${IS_LINUX:-0} -eq 1 ]]; then
  if [[ -z "$MODE_REQUEST" ]]; then
    if is_sys_tty_enabled; then
      say "systemd (user) daemon-reload only (TTY mode detected)"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      systemctl --user disable "$(basename "$USER_UNIT")" >/dev/null 2>&1 || true
    else
      if [[ -f "$SRC_USER_UNIT" ]]; then
        install_file_user "$SRC_USER_UNIT" "$USER_UNIT" 0644
        daemon_reload_enable_user "$(basename "$USER_UNIT")"
      else
        warn "repo user unit missing: $SRC_USER_UNIT (skipping)"
      fi
    fi
  fi
fi

# Add to manifest for uninstaller tracking
if [[ -f "${USER_UNIT}" ]]; then
  manifest_add_file "${USER_UNIT}"
fi

# # =====================================================================
# # Manifest Reconciliation (optional root step)
# # =====================================================================
# Core set + helpers (drop file-based lists; parse arrays from installer; bash 3.x safe) ---

# Package presence probes
linux_pkg_present()   { dpkg -s "$1" >/dev/null 2>&1; }
brew_formula_present(){ brew list --formula --versions "$1" >/dev/null 2>&1; }
brew_cask_present()   { brew list --cask --versions "$1"    >/dev/null 2>&1; }

# Simple membership test: _in_list "item" ARRAY_NAME
_in_list() {
  local needle="$1" arr="$2" x
  eval 'for x in "${'"$arr"'[@]}"; do [[ "$x" == "'"$needle"'" ]] && return 0; done'
  return 1
}

# Parse a bash array from the installer into a target array (bash 3.x friendly; no mapfile)
_parse_array_from_installer() {
  local name="$1" outvar="$2"
  local installer="${SRC}/install-${WD_NAME}.sh"
  eval "$outvar=()"
  [[ -s "$installer" ]] || return 0

  # Write the array body to a temp file first so we can check awk’s status
  local tf
  tf="$(mktemp)" || return 0

  if awk -v n="$name" '
      $0 ~ "^[[:space:]]*" n "[[:space:]]*=\\(" { inside=1; next }
      inside && $0 ~ /[)][[:space:]]*$/        { inside=0; exit }
      inside                                   { print }
    ' "$installer" >"$tf" 2>/dev/null
  then
    # Read tokens line-by-line (bash 3.x friendly), strip comments/whitespace
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      [[ -n "$line" ]] || continue
      line="${line%\"}"; line="${line#\"}"
      eval "$outvar+=(\"\$line\")"
    done < "$tf"
  fi

  rm -f "$tf" 2>/dev/null || true
}

# Read desired core sets from installer arrays only
read_core_sets() {
  CORE_LINUX=()
  CORE_BREW_FORMULAE=()
  CORE_BREW_CASKS=()
  _parse_array_from_installer "PKG_CORE_LINUX"   CORE_LINUX
  _parse_array_from_installer "PKG_BREW_FORMULAE" CORE_BREW_FORMULAE
  _parse_array_from_installer "PKG_BREW_CASKS"    CORE_BREW_CASKS
}

reconcile_pkgs(){
  mkdir -p "${MANIFEST_DIR}"
  [[ -e "${PKG_PREEXIST}" ]] || : > "${PKG_PREEXIST}"
  [[ -e "${PKG_PURGE}"    ]] || : > "${PKG_PURGE}"

  # Preserve old required for diff BEFORE we overwrite it
  local tmp_old; tmp_old="$(mktemp)"; : > "$tmp_old"
  if [[ -s "${PKG_REQUIRED}" ]]; then
    cp -f "${PKG_REQUIRED}" "$tmp_old"
  fi

  # Build desired set from installer arrays
  read_core_sets
  local mgr DESIRED=()
  if [[ ${IS_LINUX:-0} -eq 1 ]]; then
    DESIRED=( "${CORE_LINUX[@]}" )
    mgr=apt
  elif [[ ${IS_MACOS:-0} -eq 1 ]]; then
    DESIRED=( "${CORE_BREW_FORMULAE[@]}" "${CORE_BREW_CASKS[@]}" )
    mgr=brew
  else
    DESIRED=()
    mgr="unknown"
  fi

  # Write new pkg.required (sorted, unique)
  if ((${#DESIRED[@]})); then
    # print array items, sort -u
    : > "${PKG_REQUIRED}"
    local it
    for it in "${DESIRED[@]}"; do 
      printf '%s\n' "$it"
    done | LC_ALL=C sort -u >> "${PKG_REQUIRED}"
  else
    : > "${PKG_REQUIRED}"
  fi

  # Compute diffs vs previous required
  local ADDED REMOVED
  ADDED="$(comm -13 <(LC_ALL=C sort -u "$tmp_old") <(LC_ALL=C sort -u "${PKG_REQUIRED}"))"
  REMOVED="$(comm -23 <(LC_ALL=C sort -u "$tmp_old") <(LC_ALL=C sort -u "${PKG_REQUIRED}"))"

  # Detect currently missing core from the new required set
  local MISSING_NOW=() p
  while IFS= read -r p || [[ -n "$p" ]]; do
    [[ -n "$p" ]] || continue
    if [[ ${IS_LINUX:-0} -eq 1 ]]; then
      linux_pkg_present "$p" || MISSING_NOW+=( "$p" )
    elif [[ ${IS_MACOS:-0} -eq 1 ]]; then
      if _in_list "$p" CORE_BREW_FORMULAE; then
        brew_formula_present "$p" || MISSING_NOW+=( "$p" )
      else
        brew_cask_present "$p"    || MISSING_NOW+=( "$p" )
      fi
    fi
  done < "${PKG_REQUIRED}"

  # Reporting
  say "— core diff (via ${mgr}) —"
  if [[ -n "$ADDED" ]]; then
    echo "  Core added since last version:"
    echo "$ADDED" | sed 's/^/    + /'
  else
    echo "  Core added since last version: (none)"
  fi
  if [[ -n "$REMOVED" ]]; then
    echo "  Core removed since last version:"
    echo "$REMOVED" | sed 's/^/    - /'
  else
    echo "  Core removed since last version: (none)"
  fi
  if ((${#MISSING_NOW[@]})); then
    echo "  Core required by this version but not currently installed on this host:"
    for p in "${MISSING_NOW[@]}"; do 
      echo "    • $p"
    done
      echo "  (Updater does not auto-reinstall these; install manually if needed.)"
    else
      echo "  Core required by this version but not currently installed on this host: (none)"
    fi

  # Install newly ADDED core now (default behavior). Append only actually-installed to pkg.purge.
  if [[ -n "$ADDED" ]]; then
    if [[ ${IS_LINUX:-0} -eq 1 ]]; then
      local TO_INSTALL_ADDED=()
      while IFS= read -r p || [[ -n "$p" ]]; do
        [[ -n "$p" ]] || continue
        linux_pkg_present "$p" || TO_INSTALL_ADDED+=( "$p" )
      done <<< "$ADDED"

      if ((${#TO_INSTALL_ADDED[@]})); then
        say "installing newly-added core (apt): ${TO_INSTALL_ADDED[*]}"
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${TO_INSTALL_ADDED[@]}"; then
          for p in "${TO_INSTALL_ADDED[@]}"; do 
            linux_pkg_present "$p" && echo "$p" >> "${PKG_PURGE}"
          done
        else
          warn "apt install reported failure; verifying individually…"
          for p in "${TO_INSTALL_ADDED[@]}"; do 
            linux_pkg_present "$p" && echo "$p" >> "${PKG_PURGE}"
          done
        fi
      fi

    elif [[ ${IS_MACOS:-0} -eq 1 ]]; then
      local TO_INSTALL_FORM=() TO_INSTALL_CASK=()
      while IFS= read -r p || [[ -n "$p" ]]; do
        [[ -n "$p" ]] || continue
        if _in_list "$p" CORE_BREW_FORMULAE; then
          brew_formula_present "$p" || TO_INSTALL_FORM+=( "$p" )
        else
          brew_cask_present "$p"    || TO_INSTALL_CASK+=( "$p" )
        fi
      done <<< "$ADDED"

      if ((${#TO_INSTALL_FORM[@]})); then
        say "installing newly-added core (brew formula): ${TO_INSTALL_FORM[*]}"
        brew install "${TO_INSTALL_FORM[@]}" || true
        for p in "${TO_INSTALL_FORM[@]}"; do brew_formula_present "$p" && echo "$p" >> "${PKG_PURGE}"; done
      fi

      if ((${#TO_INSTALL_CASK[@]})); then
        say "installing newly-added core (brew cask): ${TO_INSTALL_CASK[*]}"
        brew install --cask "${TO_INSTALL_CASK[@]}" || true
        for p in "${TO_INSTALL_CASK[@]}"; do brew_cask_present "$p" && echo "$p" >> "${PKG_PURGE}"; done
      fi
    fi
  fi

  rm -f "$tmp_old"
}

# Update manifests first
reconcile_pkgs

# # =====================================================================
# # Apply Mode Change (if requested) + Final Restarts
# # =====================================================================
# --- macOS-safe mode dispatch (no ${var,,}) ---
apply_requested_mode(){
  if [[ -n "${MODE_REQUEST:-}" ]]; then
    case "$MODE_REQUEST" in
      user|USER|User)           apply_mode_user ;;
      system|SYSTEM|System|tty|TTY|Tty)  apply_mode_system ;;
      none|NONE|None)           apply_mode_none ;;
      *)                        warn "unknown mode: $MODE_REQUEST (ignored)";;
    esac
  fi
}

# Apply mode change if requested (never exits early)
apply_requested_mode

# Restart only when in user mode or when no tty unit is enabled
if [[ -z "$MODE_REQUEST" || "$MODE_REQUEST" == "user" || "$MODE_REQUEST" == "none" ]]; then
  if is_sys_tty_enabled; then
    say "TTY system unit is active; skipping user unit restart to avoid duplicate TUIs."
    say "logs (system): sudo journalctl -u ${SYS_TTY_NAME} -e"
  else
    restart_user_unit "$(basename "$USER_UNIT")"
    say "logs (user): journalctl --user -u ${WD_NAME}-tui.service -e"
  fi
fi

# # =====================================================================
# # Final Messaging
# # =====================================================================
echo
echo "== [silo] update complete :: $(date) =="


# # # =====================================================================
# # # Optional Export Server Staging (Disabled by default)
# # # =====================================================================
# # ---------- Step X: Export server (user-level) ----------
# if [[ ${WD_ENABLE_EXPORT} -eq 1 ]]; then
#   if [[ ${IS_LINUX:-0} -eq 1 ]]; then
#     if [[ -f "$SRC_EXPORT" ]]; then
#       say "staging export server (user-level)…"
#       install_file_user "$SRC_EXPORT" "${BIN_DIR}/export_http_server.py" 755
#       prep_script_user    "${BIN_DIR}/export_http_server.py"
#     else
#       warn "export server unavailable at ${SRC_EXPORT} — 🛠️ feature under construction (skipping)"
#     fi
#   else
#     say "bypassing export server staging (non-Linux host)."
#   fi
# else
#   say "export server updates disabled (WD_ENABLE_EXPORT=0)."
# fi

# # Add to manifest for uninstaller tracking
# if [[ ${WD_ENABLE_EXPORT} -eq 1 && ${IS_LINUX:-0} -eq 1 && -f "${BIN_DIR}/export_http_server.py" ]]; then
#   manifest_add_file "${BIN_DIR}/export_http_server.py"
# fi
# # Revert the above to below after onstruction
# # if [[ ${IS_LINUX:-0} -eq 1 && -f "${BIN_DIR}/export_http_server.py" ]]; then
# #   manifest_add_file "${BIN_DIR}/export_http_server.py"
# # fi