#!/usr/bin/env bash
set -Eeuo pipefail
# To debug: bash -x ./install-silo11writerdeck.sh

# umask: so logs and installed files are world-readable
umask 022
# simple logger (declare before trap so trap can call it)
say(){ echo "⛓️  [silo] $*"; }
# trap: clean failure line & shell-quoted command in the log
# safer than the @Q which has problems with Mac/Pre Bash 4.4
trap 'rc=$?; cmd=$BASH_COMMAND; say "ERROR: ${cmd} exited with $rc"; exit $rc' ERR

# Safety Check
# Refuse to run as root (prevents installing into /root by accident)
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  say "ERROR: do not run this installer as root."
  echo "       Run it as your normal user. The script will sudo only when needed."
  exit 1
fi

# --- OS detect (normalized flags + name) -------------------------------------
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
IS_MACOS=""
IS_LINUX=""
case "$OS_NAME" in
  Darwin) IS_MACOS=1 ;;
  Linux)  IS_LINUX=1 ;;
esac

# --- sed flavor flag (BSD/mac uses -E, GNU/Linux uses -r) --------------------
if [[ -n "${IS_MACOS:-}" ]]; then
  _SED_EXT='-E'
else
  _SED_EXT='-r'
fi

# =========================
# Single Source of Truth
# =========================

# ---- Files needed for early guard ----
WD_NAME="silo11writerdeck"
SRC="${1:-$HOME/${WD_NAME}}"          # repo root (argument or ~/silo11writerdeck)
WD_USER="${WD_USER:-${SUDO_USER:-$(id -un)}}"
WD_HOME="$(eval echo "~${WD_USER}")"
BIN_DIR="${WD_HOME}/.local/bin"
SYSTEMD_USER_DIR="${WD_HOME}/.config/systemd/user"
WD_WRAPPER_BIN="${BIN_DIR}/${WD_NAME}"
UPDATER_CANDIDATE="${SRC}/update-${WD_NAME}.sh"

# ---- Service files ----
SRC_USER_UNIT="${SRC}/systemd/user/${WD_NAME}-tui.service"
SRC_SYS_TTY_UNIT="${SRC}/systemd/system/${WD_NAME}-tty.service"

# ---- Unified manifest root (XDG by default; override with WD_MANIFEST_ROOT) ----
#   Default: ~/.local/state/silo11writerdeck/manifest  (XDG state — conventional for install/runtime state)
: "${WD_MANIFEST_ROOT:=${XDG_STATE_HOME:-$WD_HOME/.local/state}/${WD_NAME}}"
MANIFEST_DIR="${WD_MANIFEST_ROOT}/manifest"
LOG_DIR="${WD_MANIFEST_ROOT}"
mkdir -p "${MANIFEST_DIR}" "${LOG_DIR}" || true
# Canonical manifest files (OS-neutral names)
PKG_REQUIRED="${MANIFEST_DIR}/pkg.required"        # authoritative list to check
PKG_PREEXIST="${MANIFEST_DIR}/pkg.preexisting"     # present before install
PKG_PURGE="${MANIFEST_DIR}/pkg.purge"              # installed by this installer
PKG_MANAGER="${MANIFEST_DIR}/pkg.manager"          # "apt" | "brew"
# generic file manifest used by append_manifest()
MANIFEST_FILE="${MANIFEST_DIR}/manifest.txt"
[ -d "${MANIFEST_DIR}" ] && : > "${MANIFEST_FILE}" || true

# --- manifest helpers (shared Linux + macOS) ---
# Keep order, avoid duplicates
_contains_line() {
  local needle="$1" file="$2"
  [[ -f "$file" ]] || return 1
  grep -Fxq -- "$needle" "$file"
}

_append_unique_line() {
  local line="$1" file="$2"
  mkdir -p "$(dirname "$file")"
  if ! _contains_line "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
  fi
}

# ---- Linux Core Package Sets ----
PKG_CORE_LINUX=(
  # Requirement (pre-installed on most systems)
  python3          # main interpreter (runs TUI + agents)
  rsync            # required for updater
  # Writing Suite
  # diary          # macOS only for now (requires configuration to work on Pi)
  emacs-nox
  # gedit          # macOS only for now (heavy install on a Pi)
  nano             # lightweight terminal text editor
  # obsidian       # macOS only for now
  vim
  wordgrinder      # curses-based word processor
  # Network Tools
  network-manager  # provides `nmtui` for Wi-Fi setup
  bluez            # Linux Bluetooth stack
  rfkill           # toggles Wi-Fi/Bluetooth power
  wpasupplicant    # WPA client daemon + `wpa_cli` helper
)

# ---- macOS Core (split: formulae vs casks) ----
PKG_BREW_FORMULAE=(
  python3
  rsync
  diary
  emacs
  gedit
  nano
  vim
  wordgrinder
)

PKG_BREW_CASKS=(
  obsidian
)

# Homebrew helpers (handle formula vs cask distinctly)
brew_formula_present(){ brew list --formula --versions "$1" >/dev/null 2>&1; }
brew_cask_present(){ brew list --cask --versions "$1" >/dev/null 2>&1; }

brew_formula_version(){ brew list --formula --versions "$1" 2>/dev/null | awk '{print $2}' || true; }
brew_cask_version(){ brew list --cask --versions "$1" 2>/dev/null | awk '{print $2}' || true; }

# ---- Future Development: Bluetooth Auto-Pair-Trust-Connect (Linux only) ----
# Required by bt_autopair_trust_connect_agent.py
# Enables D-Bus and GLib event handling for BlueZ.
# python3-dbus  # D-Bus IPC bindings
# python3-gi    # PyGObject / GLib main loop

# ---- User-level (no sudo) ----
CFG_DIR="${WD_HOME}/.config/${WD_NAME}"
STATE_DIR="${XDG_STATE_HOME:-$WD_HOME/.local/state}/${WD_NAME}"
USER_UNIT="${SYSTEMD_USER_DIR}/${WD_NAME}-tui.service"
SYS_TTY_UNIT="/etc/systemd/system/${WD_NAME}-tty.service"

# ---- Source files in repo  ----
SRC_TUI_DIR="${SRC}/tui"
SRC_TUI_MENU="${SRC_TUI_DIR}/menu.py"
# Under Construction
# SRC_EXPORT="${SRC}/http_server/export_http_server.py"

# =========================
# Early stop if silo11writerdeck is already installed
# =========================
HC_CANDIDATES=(
  "${BIN_DIR}/healthcheck-${WD_NAME}"
  "${WD_HOME}/.${WD_NAME}/healthcheck-${WD_NAME}"
  "${SRC}/healthcheck-${WD_NAME}"
)

is_installed_quick() {
  [[ -x "${WD_WRAPPER_BIN}" ]] || return 1
  if [[ -f "${SYSTEMD_USER_DIR}/${WD_NAME}-tui.service" ]] || [[ -f "/etc/systemd/system/${WD_NAME}-tty.service" ]]; then
    return 0
  fi
  # consider installed if unified manifest exists with any content
  [[ -d "${MANIFEST_DIR}" && ( -s "${PKG_REQUIRED}" || -s "${PKG_PURGE}" || -s "${MANIFEST_FILE}" ) ]]
}

if is_installed_quick; then
  say "detected existing ${WD_NAME} install (quick check)."
  if [[ -x "$UPDATER_CANDIDATE" ]]; then
    say "➡️  ${WD_NAME} appears installed. Run the updater instead:"
    say "    bash ${UPDATER_CANDIDATE}"
  else
    say "➡️  ${WD_NAME} appears installed. Use your project updater to avoid overwriting the purge manifest."
  fi
  exit 0
fi

# 2) Try a healthcheck with a short timeout (best-effort, non-fatal)
HC_BIN=""
for c in "${HC_CANDIDATES[@]}"; do
  if [[ -x "$c" ]]; then HC_BIN="$c"; break; fi
done
if [[ -n "$HC_BIN" ]]; then
  if command -v timeout >/dev/null 2>&1; then
    if timeout 3s "$HC_BIN" >/dev/null 2>&1; then
      say "healthcheck indicates ${WD_NAME} is already installed."
      if [[ -x "$UPDATER_CANDIDATE" ]]; then
        say "➡️  Run: bash ${UPDATER_CANDIDATE}"
      else
        say "➡️  Use your updater to keep the purge manifest intact."
      fi
      exit 0
    fi
  else
    ( "$HC_BIN" >/dev/null 2>&1 ) &
  fi
fi

# =========================
# Installer Logging (XDG)
# =========================
LOG="${XDG_STATE_HOME:-$WD_HOME/.local/state}/${WD_NAME}/install.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "== [silo] ${WD_NAME} install uplink opened :: $(date) =="

# Create/refresh the repo-side install.log symlink, but only if the repo is writable
REPO_LOG="${SRC}/install.log"
if [[ -w "${SRC}" ]]; then
  # ln -sfnT "${LOG}" "${REPO_LOG}" # not compatible with macOS
  rm -f "${REPO_LOG}" && ln -sfn "${LOG}" "${REPO_LOG}"
  say "repo log link set: ${REPO_LOG} → ${LOG}"
else
  say "note: repo path not writable; skipping ${REPO_LOG} symlink"
fi

# =========================
# Sanity checks
# =========================
if [[ ! -d "$SRC" ]]; then
  say "ERROR: repo not found at: $SRC"
  say "Usage: $0 /path/to/${WD_NAME} (or place it at ~/silo11writerdeck)"
  exit 1
fi
if [[ ! -f "$SRC_TUI_MENU" ]]; then
  say "ERROR: missing TUI entrypoint at ${SRC_TUI_MENU}"
  exit 1
fi

# Ensure %h/silo11writerdeck points at the repo we’re installing from
if [[ "$SRC" != "$WD_HOME/${WD_NAME}" ]]; then
  # ln -sfnT "$SRC" "$WD_HOME/${WD_NAME}" # Not supported on macOS
  rm -f "$WD_HOME/${WD_NAME}" && ln -sfn "$SRC" "$WD_HOME/${WD_NAME}"
  say "link set (SRC != \$WD_HOME/${WD_NAME}): ${WD_HOME}/silo11writerdeck → ${SRC}"
fi

# =========================
# Helpers (User/Root)
# =========================
# --- (sudo warm-up) ---
if command -v sudo >/dev/null 2>&1; then
  say "warming up sudo session..."
  sudo -v || true
  # Keep it alive while the installer runs
  ( while true; do sleep 60; sudo -n true 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null || true' EXIT
fi

# In-place sed that works on both GNU (Linux) and BSD (macOS)
# usage: _sed_inplace [sudo] '<script>' <file>
_sed_inplace() {
  local use_sudo=
  [[ "${1:-}" == "sudo" ]] && use_sudo=1 && shift
  local script="$1"; shift

  if [[ -n "${IS_MACOS:-}" ]]; then
    # BSD sed: sed -E -i '' 'script' file...
    if [[ -n "$use_sudo" ]]; then
      sudo sed "$_SED_EXT" -i '' "$script" "$@"
    else
      sed "$_SED_EXT" -i '' "$script" "$@"
    fi
  else
    # GNU sed: sed -r -i 'script' file...
    if [[ -n "$use_sudo" ]]; then
      sudo sed "$_SED_EXT" -i "$script" "$@"
    else
      sed "$_SED_EXT" -i "$script" "$@"
    fi
  fi
}

# Stream sed into a new file (no in-place). Accepts multiple -e scripts.
# usage: _sed_file <infile> <outfile> 's|old|new|g' 's|old2|new2|g' ...
_sed_file() {
  local infile="$1" outfile="$2"; shift 2
  local args=()
  for s in "$@"; do args+=(-e "$s"); done
  sed "$_SED_EXT" "${args[@]}" "$infile" > "$outfile"
}

# Escape replacement strings for sed (/, &, |)
sed_escape() { printf '%s' "$1" | sed 's/[\/&|]/\\&/g'; }

# Install helpers (root/user) with OS-aware behavior
# - Linux: use `install -D` (creates parent dirs)
# - macOS: BSD `install` lacks -D → use `mkdir -p` then `install -m`
install_file_root(){ # src dest [mode]
  local src="$1" dst="$2" mode="${3:-644}"
  if [[ -n "${IS_LINUX:-}" ]]; then
    sudo install -D -m "$mode" "$src" "$dst"
  else
    # macOS / other BSDs
    sudo mkdir -p "$(dirname "$dst")"
    sudo install -m "$mode" "$src" "$dst"
  fi
}

install_file_user(){ # src dest [mode]
  local src="$1" dst="$2" mode="${3:-644}"
  if [[ -n "${IS_LINUX:-}" ]]; then
    install -D -m "$mode" "$src" "$dst"
  else
    # macOS / other BSDs
    mkdir -p "$(dirname "$dst")"
    install -m "$mode" "$src" "$dst"
  fi
}
append_manifest(){ # kind path
  local kind="$1" path="$2"
  printf '%s %s\n' "$kind" "$path" >> "${MANIFEST_FILE}"
}
prep_script_root() {
  local p="$1"
  # strip CRLF line endings
  _sed_inplace sudo 's/\r$//' "$p" || true
  # strip UTF-8 BOM if present
  _sed_inplace sudo $'1s/^\xEF\xBB\xBF//' "$p" || true
  sudo chmod +x "$p"
}
prep_script_user() {
  local p="$1"
  _sed_inplace 's/\r$//' "$p" || true
  _sed_inplace $'1s/^\xEF\xBB\xBF//' "$p" || true
  chmod +x "$p"
}

# Ensure helper scripts in the repo are executable (quality of life)
for p in \
  "${SRC}/update-${WD_NAME}.sh" \
  "${SRC}/uninstall-${WD_NAME}.sh" \
  "${SRC}/healthcheck-${WD_NAME}.sh"
do
  [[ -f "$p" ]] && prep_script_user "$p"
done

# =========================
# Prepare user-level dirs & state
# =========================
mkdir -p "$BIN_DIR" "$CFG_DIR" "$STATE_DIR" "$SYSTEMD_USER_DIR" "${MANIFEST_DIR}"

# =========================
# Core packages (root install) — LINUX ONLY
# =========================
declare -a TO_INSTALL=()
if [[ -n "${IS_LINUX:-}" ]]; then
  pkg_version(){ dpkg-query -W -f='${Version}\n' "$1" 2>/dev/null || echo "unknown"; }

  say "refreshing apt caches… (fast tweaks: only english, full list instead of diffs, only IPv4)"
  sudo apt-get update \
    -o Acquire::Languages=none \
    -o Acquire::PDiffs=false \
    -o Acquire::ForceIPv4=true

  # --- Unified manifest (Linux) ---
  echo "apt" > "${PKG_MANAGER}"

  # IMPORTANT:
  # - PKG_REQUIRED is re-written (authoritative desired set for this version)
  # - PKG_PREEXIST & PKG_PURGE are *append-only* (never truncated), so reruns don’t lose history
  : > "${PKG_REQUIRED}"
  touch "${PKG_PREEXIST}" "${PKG_PURGE}"

  # record required set (fresh each run)
  for p in "${PKG_CORE_LINUX[@]}"; do
    printf '%s\n' "$p" >> "${PKG_REQUIRED}"
  done

  # decide install set
  TO_INSTALL=()
  for p in "${PKG_CORE_LINUX[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then
      say "pkg present: $p ($(pkg_version "$p"))"
      _append_unique_line "$p" "${PKG_PREEXIST}"   # remember it was *already* present
    else
      TO_INSTALL+=("$p")
    fi
  done

  if ((${#TO_INSTALL[@]})); then
    say "installing: ${TO_INSTALL[*]}"
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${TO_INSTALL[@]}"; then
      # Only mark those that actually landed
      for p in "${TO_INSTALL[@]}"; do
        if dpkg -s "$p" >/dev/null 2>&1; then
          _append_unique_line "$p" "${PKG_PURGE}"  # we installed this; safe to purge later
        fi
      done
    else
      say "WARN: apt install reported failure; checking which packages actually installed…"
      for p in "${TO_INSTALL[@]}"; do
        if dpkg -s "$p" >/dev/null 2>&1; then
          _append_unique_line "$p" "${PKG_PURGE}"
        fi
      done
    fi
  else
    say "all core packages already present"
  fi

elif [[ -n "${IS_MACOS:-}" ]]; then
  # -------------------------
  # macOS (Homebrew) path
  # -------------------------
  if ! command -v brew >/dev/null 2>&1; then
    say "Homebrew not found. Please install Homebrew from https://brew.sh and re-run."
    exit 1
  fi

  say "refreshing brew metadata…"
  brew update || true

  # unified manifest (macOS)
  echo "brew" > "${PKG_MANAGER}"

  # IMPORTANT:
  # - PKG_REQUIRED is re-written each run (authoritative desired set)
  # - PKG_PREEXIST & PKG_PURGE are *append-only* (like Linux) so history is preserved
  : > "${PKG_REQUIRED}"
  touch "${PKG_PREEXIST}" "${PKG_PURGE}"

  # Record required set (both formulae and casks)
  for p in "${PKG_BREW_FORMULAE[@]}"; do echo "$p" >> "${PKG_REQUIRED}"; done
  for c in "${PKG_BREW_CASKS[@]}";   do echo "$c" >> "${PKG_REQUIRED}"; done

  # Build install lists and log what is already present (no associative arrays)
  TO_INSTALL_FORMULAE=()
  for p in "${PKG_BREW_FORMULAE[@]}"; do
    if brew_formula_present "$p"; then
      v="$(brew_formula_version "$p")"
      say "pkg present: ${p}${v:+ ($v)}"
      _append_unique_line "$p" "${PKG_PREEXIST}"   # already present before this run
    else
      TO_INSTALL_FORMULAE+=("$p")
    fi
  done

  TO_INSTALL_CASKS=()
  for c in "${PKG_BREW_CASKS[@]}"; do
    if brew_cask_present "$c"; then
      v="$(brew_cask_version "$c")"
      say "pkg present: ${c}${v:+ (cask $v)}"
      _append_unique_line "$c" "${PKG_PREEXIST}"
    else
      TO_INSTALL_CASKS+=("$c")
    fi
  done

  # Install missing formulae
  if ((${#TO_INSTALL_FORMULAE[@]})); then
    say "installing via brew (formula): ${TO_INSTALL_FORMULAE[*]}"
    brew install "${TO_INSTALL_FORMULAE[@]}" || true
    # Re-check and only mark those that were actually installed now
    for p in "${TO_INSTALL_FORMULAE[@]}"; do
      if brew_formula_present "$p"; then
        _append_unique_line "$p" "${PKG_PURGE}"
      fi
    done
  fi

  # Install missing casks
  if ((${#TO_INSTALL_CASKS[@]})); then
    say "installing via brew (cask): ${TO_INSTALL_CASKS[*]}"
    brew install --cask "${TO_INSTALL_CASKS[@]}" || true
    # Re-check and only mark those that were actually installed now
    for c in "${TO_INSTALL_CASKS[@]}"; do
      if brew_cask_present "$c"; then
        _append_unique_line "$c" "${PKG_PURGE}"
      fi
    done
  fi

  # If nothing was missing
  if ((!${#TO_INSTALL_FORMULAE[@]} && !${#TO_INSTALL_CASKS[@]})); then
    say "all core packages already present (brew)"
  fi
fi

# =========================
# --- Friendly CLI launcher
# =========================
echo "🔧 Installing silo11writerdeck launcher at: ${WD_WRAPPER_BIN}"
mkdir -p "${BIN_DIR}"
cat > "${WD_WRAPPER_BIN}" <<'EOF'
#!/usr/bin/env bash
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
EOF
chmod +x "${WD_WRAPPER_BIN}"

# --- PATH bootstrap, macOS & Linux ---
say "Ensuring ~/.local/bin is on PATH for this user (login + interactive shells)"

: "${WD_USER:=$(id -un)}"
: "${WD_HOME:=$(eval echo "~${WD_USER}")}"
USER_SHELL_BASENAME="${SHELL##*/}"

PATH_MARK_BEGIN="# >>> ${WD_NAME} PATH begin >>>"
PATH_MARK_END="# <<< ${WD_NAME} PATH end <<<"

add_path_snippet() {
  local file="$1"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] || : > "$file"

  if grep -qF "$PATH_MARK_BEGIN" "$file" 2>/dev/null; then
    say "  ✓ PATH snippet already present in $(basename "$file")"
    return 0
  fi

  {
    echo
    echo "$PATH_MARK_BEGIN"
    cat <<'EOSNIP'
# Ensure user-local bin is on PATH so 'silo11writerdeck' works in new shells
if [ -d "$HOME/.local/bin" ]; then
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH";; esac
fi
EOSNIP
    echo "$PATH_MARK_END"
  } >> "$file"

  say "  ✓ PATH snippet added to $(basename "$file")"
}

# Decide target files based on OS and current shell.
# Rules of thumb:
# - macOS Terminal uses login shells:
#     zsh  -> ~/.zprofile
#     bash -> ~/.bash_profile   (we also cover ~/.bashrc if it exists)
# - Linux terminals are usually non-login interactive:
#     zsh  -> ~/.zshrc
#     bash -> ~/.bashrc         (we also cover ~/.profile for login shells)
FILES=()
if [[ -n "${IS_MACOS:-}" ]]; then
  # macOS (login shells)
  if [[ "$USER_SHELL_BASENAME" == "zsh" ]]; then
    FILES+=("${WD_HOME}/.zprofile" "${WD_HOME}/.zshrc")
  elif [[ "$USER_SHELL_BASENAME" == "bash" ]]; then
    FILES+=("${WD_HOME}/.bash_profile")
    [[ -f "${WD_HOME}/.bashrc" ]] && FILES+=("${WD_HOME}/.bashrc")
  else
    FILES+=("${WD_HOME}/.profile")
  fi
else
  # Linux (non-login interactive)
  if [[ "$USER_SHELL_BASENAME" == "zsh" ]]; then
    FILES+=("${WD_HOME}/.zshrc")
  elif [[ "$USER_SHELL_BASENAME" == "bash" ]]; then
    FILES+=("${WD_HOME}/.bashrc" "${WD_HOME}/.profile")
  else
    FILES+=("${WD_HOME}/.profile")
  fi
fi

# Apply snippet to all target files
for f in "${FILES[@]}"; do
  add_path_snippet "$f"
done

# Post-note / immediate-use hint
if [[ -n "${IS_MACOS:-}" ]]; then
  # Do NOT source files on macOS here (slow; only affects subshell). Provide a safe one-liner instead.
  echo
  echo "To use the launcher in THIS shell immediately, run:"
  echo '    export PATH="$HOME/.local/bin:$PATH"'
  if command -v zsh >/dev/null 2>&1 && [[ "${SHELL##*/}" == "zsh" ]]; then
    echo '    rehash'
  fi
  echo
  echo "New Terminal windows/tabs will inherit PATH via your ~/.zprofile (and ~/.zshrc if present)."
else
  # Linux: optionally source now so this installer shell picks it up immediately
  for f in "${FILES[@]}"; do
    # shellcheck disable=SC1090
    [[ -f "$f" ]] && . "$f" >/dev/null 2>&1 || true
  done
fi

echo "✅ ${WD_NAME} installed. Launch with: '${WD_NAME}' after reboot"

# =====================================================================
# Prompt helper that talks directly to /dev/tty (works under tee)
# =====================================================================
# Usage: ask_yes_no_tty "Prompt text" [Y|N]
# Returns: 0 for yes, 1 for no
ask_yes_no_tty() {
  local prompt="${1:-Proceed?}"
  local default="${2:-Y}"   # Y or N
  local hint
  case "$default" in
    Y|y) hint="[Y/n] " ;;
    N|n) hint="[y/N] " ;;
    *)   hint="[Y/n] " ; default="Y" ;;
  esac
  local ans=""
  if [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]]; then
    printf "%s %s" "$prompt" "$hint" > /dev/tty
    IFS= read -r ans < /dev/tty || true
  fi
  # Empty answer => default
  if [[ -z "$ans" ]]; then
    [[ "$default" =~ ^[Yy]$ ]] && return 0 || return 1
  fi
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO)   return 1 ;;
    *)           [[ "$default" =~ ^[Yy]$ ]] && return 0 || return 1 ;;
  esac
}

# Read a simple numeric choice from /dev/tty, stripping escape noise.
# Usage: _read_menu_choice "prompt" "default_digit"
_read_menu_choice() {
  local prompt="${1:-Select: }"
  local def="${2:-1}"
  local ans=""
  if [[ -e /dev/tty && -r /dev/tty ]]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r ans < /dev/tty || true
  fi
  # Strip common escape sequences like ^[[A, ^[[3~, etc.
  ans="${ans//$'\e'/}"                       # drop ESC
  ans="$(printf '%s' "$ans" | tr -cd '0-9')" # keep digits only
  case "$ans" in
    1|2|3) printf '%s\n' "$ans" ;;
    "" )   printf '%s\n' "$def" ;;
    * )    printf '%s\n' "$def" ;;
  esac
}

# =====================================================================
# Auto-Start Decision Block (Linux) (user prompt via /dev/tty; systemd units/linger)
# =====================================================================
# Env knobs:
#   WD_TAKEOVER=1|0
#   WD_ENABLE_LINGER=1|0
#   WD_ENABLE_LINGER_DEFAULT=Y|N
#   WD_ATTACH_TTY=1|0
: "${WD_ENABLE_LINGER:=}"
: "${WD_ENABLE_LINGER_DEFAULT:=Y}"
: "${WD_ATTACH_TTY:=1}"
: "${LINGER_MARKER:=${MANIFEST_DIR}/linger.enabled}"

if [[ -z "${IS_LINUX:-}" ]]; then
  say "Non-Linux environment (${OS_NAME}); skipping auto-start configuration."
  say "You can launch '${WD_NAME}' manually from the shell after install."
else
  HAS_SYSTEMD=0
  if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
    HAS_SYSTEMD=1
  fi

  WD_INSTALL_MODE="${WD_INSTALL_MODE:-}"
  TAKEOVER=0

  if [[ "$HAS_SYSTEMD" -eq 0 ]]; then
    say "Systemd not available; skipping auto-start configuration."
  else
    # Resolve mode from env if provided
    if [[ -n "${WD_INSTALL_MODE}" ]]; then
      case "${WD_INSTALL_MODE}" in
        tty)  TAKEOVER=1; WD_ATTACH_TTY=1 ;;
        user) TAKEOVER=1; WD_ATTACH_TTY=0 ;;
        none) TAKEOVER=0 ;;
        *)    say "WARN: WD_INSTALL_MODE must be one of: tty | user | none. Falling back to prompt."; WD_INSTALL_MODE="";;
      esac
    fi
    # Back-compat
    if [[ -z "${WD_INSTALL_MODE}" && -n "${WD_TAKEOVER:-}" ]]; then
      TAKEOVER="${WD_TAKEOVER}"
    fi
    # Interactive prompt only if undecided by env
    if [[ -z "${WD_INSTALL_MODE}" && -z "${WD_TAKEOVER:-}" ]]; then
      {
        echo
        echo "Auto-start setup (choose one):"
        echo "  [1] System service        Full Takeover: Ideal for a true writerdeck experience"
        echo "  [2] User service          Runs as user, the following 'linger' option will allow to bypass login (dev mode writerdeck experience)"
        echo "  [3] No autostart          (launch manually with 'silo11writerdeck' from console/terminal/cli)"
      } > /dev/tty 2>/dev/null || true
      choice="$(_read_menu_choice 'Selection [1/2/3] (default: 1): ' 1)"
      case "${choice}" in
        2) TAKEOVER=1; WD_ATTACH_TTY=0; say "Auto-Start Staged: user service";;
        3) TAKEOVER=0;                  say "Auto-Start Skipped";;
        *) TAKEOVER=1; WD_ATTACH_TTY=1; say "Auto-Start Staged: system TTY service";;
      esac
    fi
  fi

  if [[ "${TAKEOVER}" == "1" ]]; then
    # linger prompt (user mode only)
    if [[ "${WD_ATTACH_TTY}" == "0" ]]; then
      if [[ -z "${WD_ENABLE_LINGER}" ]]; then
        {
          echo
          echo "Bypass login option for user service:"
          echo "  Enable 'linger' for ${WD_USER} so the user service can start at boot without logging in?"
        } > /dev/tty 2>/dev/null || true
        if ask_yes_no_tty "Enable linger for ${WD_USER}?" "${WD_ENABLE_LINGER_DEFAULT}"; then
          WD_ENABLE_LINGER=1
          say "Auto-Login Staged"
        else
          WD_ENABLE_LINGER=0
          say "Auto-Login Skipped"
        fi
      fi
    fi

    if [[ "${WD_ENABLE_LINGER}" == "1" ]]; then
      if loginctl enable-linger "${WD_USER}" >/dev/null 2>&1; then
        say "linger enabled for user ${WD_USER} — user services can start at boot without login"
        echo "enabled $(date -Is)" | sudo tee "$LINGER_MARKER" >/dev/null
        [[ -n "${MANIFEST_FILE:-}" ]] && append_manifest "FILE" "${LINGER_MARKER}"
      else
        say "WARN: failed to enable linger for ${WD_USER}. You may need to run:"
        echo "      sudo loginctl enable-linger ${WD_USER}"
      fi
    fi

    # This only needs the POSIX fallback since macOS defaults to not using the service
    if [[ "${WD_ATTACH_TTY}" == "1" ]]; then
      if [[ ! -f "${SRC_SYS_TTY_UNIT}" ]]; then
        say "ERROR: system unit file missing: ${SRC_SYS_TTY_UNIT}"
        say "      Set WD_ATTACH_TTY=0 to use the user service instead."
        exit 1
      fi

      # --- render & install unit(s) ------------------------------------------------
      # Create a temp file with a .service suffix (nice for debugging tools/logs)
      tmp_unit="$(mktemp --suffix=.service 2>/dev/null || mktemp /tmp/XXXXXX.service)"

      # Safely escape replacements
      _WD_HOME_ESC="$(sed_escape "${WD_HOME}")"  # for RHS
      _WD_USER_ESC="$(sed_escape "${WD_USER}")"  # for RHS

      # Regex-escape LHS literals so sed (ERE/BRE) treats them as plain text
      _LHS_HOME_ESC="$(printf '%s' '${WD_HOME}' | sed 's/[][(){}.^$*+?|\\/]/\\&/g')"
      _LHS_USER_ESC="$(printf '%s' '${WD_USER}' | sed 's/[][(){}.^$*+?|\\/]/\\&/g')"

      # Render the SYSTEM (TTY) unit: replace ${WD_HOME} and ${WD_USER}
      _sed_file "${SRC_SYS_TTY_UNIT}" "${tmp_unit}" \
        "s|${_LHS_HOME_ESC}|${_WD_HOME_ESC}|g" \
        "s|${_LHS_USER_ESC}|${_WD_USER_ESC}|g"

      # Normalize CRLF/BOM (harmless no-ops if absent)
      _sed_inplace sudo 's/\r$//' "${tmp_unit}" || true
      _sed_inplace sudo $'1s/^\xEF\xBB\xBF//' "${tmp_unit}" || true

      # Install the rendered system unit
      install_file_root "${tmp_unit}" "${SYS_TTY_UNIT}" 644
      rm -f "${tmp_unit}"

      # Activate the TTY service (and replace getty on tty1)
      sudo systemctl daemon-reload
      sudo systemctl disable --now getty@tty1.service >/dev/null 2>&1 || true

      sudo systemctl enable --now "${WD_NAME}-tty.service" || {
        say "ERROR: enabling ${WD_NAME}-tty.service failed — status & unit follow:"
        systemctl status "${WD_NAME}-tty.service" --no-pager -l || true
        say "Installed unit (first 200 lines, numbered):"
        nl -ba "${SYS_TTY_UNIT}" | sed -n '1,200p' || true
        exit 1
      }

      [[ -n "${MANIFEST_FILE:-}" ]] && append_manifest "FILE" "${SYS_TTY_UNIT}"
      say "TTY service enabled: ${WD_NAME}-tty.service (visible on vt1)"
      say "Logs: sudo journalctl -u ${WD_NAME}-tty.service -e"
    else
      # ------------------- USER UNIT PATH (optional alt to TTY) -------------------
      if [[ ! -f "${SRC_USER_UNIT}" ]]; then
        say "ERROR: user unit file missing: ${SRC_USER_UNIT}"
        say "      Set WD_ATTACH_TTY=1 to use the TTY service instead."
        exit 1
      fi

      # If the user-unit has tokens, render them; otherwise copy as-is.
      if grep -Eq '\$\{WD_HOME\}|\$\{WD_USER\}|User=%u' "${SRC_USER_UNIT}"; then
        tmp_user_unit="$(mktemp --suffix=.service 2>/dev/null || mktemp /tmp/XXXXXX.service)"
        _sed_file "${SRC_USER_UNIT}" "${tmp_user_unit}" \
          "s|\$\{WD_HOME\}|${_WD_HOME_ESC}|g" \
          "s|\$\{WD_USER\}|${_WD_USER_ESC}|g" \
          "s|User=%u|User=${_WD_USER_ESC}|g"
        _sed_inplace 's/\r$//' "${tmp_user_unit}" || true
        _sed_inplace $'1s/^\xEF\xBB\xBF//' "${tmp_user_unit}" || true
        install_file_user "${tmp_user_unit}" "${USER_UNIT}" 644
        rm -f "${tmp_user_unit}"
      else
        install_file_user "${SRC_USER_UNIT}" "${USER_UNIT}" 644
      fi

      systemctl --user daemon-reload >/dev/null 2>&1 || true
      if systemctl --user enable --now "${WD_NAME}-tui.service"; then
        [[ -n "${MANIFEST_FILE:-}" ]] && append_manifest "FILE" "${USER_UNIT}"
        say "User service enabled: ${WD_NAME}-tui.service"
        say "Logs: journalctl --user -u ${WD_NAME}-tui.service -e"
      else
        say "WARN: failed to enable/start user service (no session yet?)."
        echo "      Try later after login: systemctl --user daemon-reload && systemctl --user enable --now ${WD_NAME}-tui.service"
      fi
    fi

    echo "== [silo] verification =="
    if [[ "${WD_ATTACH_TTY}" == "1" ]]; then
      systemctl is-enabled "${WD_NAME}-tty.service"   >/dev/null 2>&1 && echo "[confirm] tty TUI enabled" || echo "[warn] tty TUI not enabled"
      systemctl is-active  "${WD_NAME}-tty.service"   >/dev/null 2>&1 && echo "[confirm] tty TUI active"  || echo "[warn] tty TUI not active"
    else
      systemctl --user is-enabled "${WD_NAME}-tui.service" >/dev/null 2>&1 && echo "[confirm] user TUI enabled" || echo "[warn] user TUI not enabled"
      systemctl --user is-active  "${WD_NAME}-tui.service" >/dev/null 2>&1 && echo "[confirm] user TUI active"  || echo "[warn] user TUI not active"
    fi
  else
    say "Auto-start disabled. You can launch manually with: ${WD_NAME}"
    if [[ "$HAS_SYSTEMD" -eq 1 ]]; then
      say "tip: To enable later, re-run with WD_TAKEOVER=1 (NOTE: I think the updater needs to handle this WIP)"
    fi
  fi
fi


# # =====================================================================
# # Auto-Start Decision Block (macOS)
# # =====================================================================
# ############### Under Construction: Framework only (not yet attempted) ############
# ---  install-silo11writerdeck.sh (macOS auto-start 1/2/3 + profile helpers) ---
# Purpose:
#   • macOS choice: (1) launchd login agent, (2) Terminal auto-enter via shell profile, (3) neither
#   • Idempotent: switching modes removes the other mechanism cleanly
#   • Correct profile targets by OS/shell:
#       - macOS:   zsh -> ~/.zprofile, bash -> ~/.bash_profile
#       - Linux:   zsh -> ~/.zshrc,   bash -> ~/.bashrc
#   • Non-interactive override: WD_MAC_AUTOSTART=launchd|profile|none
#
# Assumes:
#   - Logger `say` exists
#   - IS_MACOS set elsewhere for Darwin
#   - Repo plist at ${SRC}/macos/io.silo11.writerdeck.plist (allows %HOME% placeholder)

# ---- profile helpers (used by both modes and uninstaller) -------------------

# SHELL_NAME="$(basename "${SHELL:-}")"

# _profile_targets() {
#   if [[ -n "${IS_MACOS:-}" ]]; then
#     case "$SHELL_NAME" in
#       zsh)  echo "$HOME/.zprofile" ;;      # Terminal.app uses login shells → .zprofile
#       bash) echo "$HOME/.bash_profile" ;;  # Terminal.app uses login shells → .bash_profile
#       *)    echo "$HOME/.profile" ;;
#     esac
#   else
#     # Linux terminals are typically non-login interactive shells
#     case "$SHELL_NAME" in
#       zsh)  echo "$HOME/.zshrc" ;;
#       bash) echo "$HOME/.bashrc" ;;
#       *)    echo "$HOME/.profile" ;;
#     esac
#   fi
# }

# _remove_profile_snippet() {
#   local target
#   for target in $(_profile_targets); do
#     [[ -f "$target" ]] || continue
#     if grep -q "silo11writerdeck auto-launch" "$target" 2>/dev/null; then
#       sed -i.bak '/>>> silo11writerdeck auto-launch/,/<<< silo11writerdeck auto-launch/d' "$target" || true
#       say "  • removed auto-enter hook from ${target}"
#     fi
#   done
# }

# _add_profile_snippet() {
#   local target; target="$(_profile_targets)"
#   [[ -f "$target" ]] || : > "$target"

#   local AUTO_LAUNCH_SNIPPET='
# # >>> silo11writerdeck auto-launch (added by installer) >>>
# # Auto-enter the deck for interactive Terminal sessions.
# # macOS: placed in login file (.zprofile/.bash_profile) because Terminal runs login shells.
# # Linux: placed in interactive file (.zshrc/.bashrc) because terminals are usually non-login shells.
# if [[ $- == *i* && -x "$HOME/.local/bin/silo11writerdeck" ]]; then
#   case "$TERM" in
#     *silo11writerdeck*|*screen*|*tmux*) ;;  # skip if nested
#     *) exec "$HOME/.local/bin/silo11writerdeck";;
#   esac
# fi
# # <<< silo11writerdeck auto-launch <<<
# '
#   if ! grep -q "silo11writerdeck auto-launch" "$target" 2>/dev/null; then
#     printf "%s\n" "$AUTO_LAUNCH_SNIPPET" >> "$target"
#     say "  ✓ appended auto-enter hook to ${target}"
#   else
#     say "  • auto-enter hook already present in ${target}"
#   fi
# }

# # ---- macOS 1/2/3 chooser (launchd / profile / none) ------------------------

# if [[ -n "${IS_MACOS:-}" ]]; then
#   say "macOS auto-start configuration"

#   AGENT_DIR="$HOME/Library/LaunchAgents"
#   PLIST_NAME="io.silo11.writerdeck.plist"
#   PLIST_SRC="${SRC}/macos/${PLIST_NAME}"
#   PLIST_DST="${AGENT_DIR}/${PLIST_NAME}"

#   _unload_launchd() {
#     if launchctl list | grep -q "io.silo11.writerdeck" 2>/dev/null; then
#       launchctl unload -w "$PLIST_DST" 2>/dev/null || true
#       say "  • launchd agent unloaded"
#     fi
#   }

#   _remove_launchd_plist() {
#     [[ -f "$PLIST_DST" ]] || return 0
#     rm -f "$PLIST_DST" || true
#     say "  • launchd agent plist removed: $PLIST_DST"
#   }

#   _install_launchd_plist() {
#     mkdir -p "$AGENT_DIR"
#     if [[ -f "$PLIST_SRC" ]]; then
#       # Replace %HOME% placeholder if present
#       local HOME_ESC; HOME_ESC="${HOME//\//\\/}"
#       sed "s/%HOME%/${HOME_ESC}/g" "$PLIST_SRC" > "$PLIST_DST"
#       chmod 644 "$PLIST_DST"
#       say "  ✓ installed launch agent: $PLIST_DST"
#     else
#       say "  ERROR: missing plist source at ${PLIST_SRC}"
#       return 1
#     fi
#   }

#   _load_launchd() {
#     launchctl load -w "$PLIST_DST" 2>/dev/null && say "  ✓ launchd agent loaded (auto-start on login)"
#   }

#   # Choose mode: env or interactive prompt
#   CHOICE=""
#   case "${WD_MAC_AUTOSTART:-}" in
#     launchd|profile|none) CHOICE="$WD_MAC_AUTOSTART" ;;
#     *)
#       if [[ -t 0 || -t 1 ]]; then
#         echo
#         echo "Choose macOS auto-start mode:"
#         echo "  [1] launchd login agent (Terminal opens on login into silo11writerdeck)"
#         echo "  [2] Terminal auto-enter (only when you open Terminal)"
#         echo "  [3] neither"
#         printf "Select 1/2/3 [default: 2]: " >/dev/tty
#         read -r CHNUM </dev/tty || CHNUM=""
#         case "$CHNUM" in
#           1) CHOICE="launchd" ;;
#           3) CHOICE="none" ;;
#           ""|2|*) CHOICE="profile" ;;
#         esac
#       else
#         CHOICE="profile"  # non-interactive default: lightweight
#       fi
#       ;;
#   esac

#   say "selected: ${CHOICE}"

#   case "$CHOICE" in
#     launchd)
#       # Ensure profile hook is removed; then install & load launch agent
#       _remove_profile_snippet
#       _unload_launchd
#       _install_launchd_plist && _load_launchd
#       echo "  • disable later: launchctl unload -w \"$PLIST_DST\""
#       ;;

#     profile)
#       # Ensure launchd is removed; then add profile hook
#       _unload_launchd
#       _remove_launchd_plist
#       _add_profile_snippet
#       ;;

#     none)
#       # Remove both mechanisms
#       _remove_profile_snippet
#       _unload_launchd
#       _remove_launchd_plist
#       say "  • macOS auto-start disabled (neither)"
#       ;;
#   esac

#   echo
# fi

# =========================
# Additional Manifests (non-service)
# =========================
[[ -n "${MANIFEST_FILE:-}" ]] && append_manifest "FILE" "${WD_WRAPPER_BIN}"
# Disabled for now: Custom Export Server
# [[ -n "${MANIFEST_FILE:-}" && -f "${BIN_DIR}/export_http_server.py" ]] && append_manifest "FILE" "${BIN_DIR}/export_http_server.py"

# =========================
# Final Install Messaging
# =========================
echo
echo "   == [silo] constructed :: $(date) =="
echo "⛓️⛓️ ${WD_NAME} install complete. ⛓️⛓️"
echo "After reboot (if auto-start enabled): the TUI should appear automatically."
echo "Otherwise, run '${WD_NAME}' to launch from console/cli."


# Below is disabled for now. Work in progress!

# =========================
# Custom Export Server (Unauthorized Zone)
# =========================
# if [[ -n "${IS_MACOS:-}" ]]; then
#   # On macOS, users have easy file management; skip export server staging entirely.
#   say "macOS detected; bypassing export server staging."
# else
#   if [[ -f "$SRC_EXPORT" ]]; then
#     say "staging export server (user-level)…"
#     install_file_user "$SRC_EXPORT" "${BIN_DIR}/export_http_server.py" 755
#     prep_script_user    "${BIN_DIR}/export_http_server.py"
#   else
#     say " 🛠️ Feature under construction: Custom Export Server"
#   fi
# fi

# =========================
# Bluetooth Auto Pair/Connect/Trust (Unauthorized Zone)
# =========================
# Root-Level
# WD_BT_AGENT="/usr/local/bin/bt_autopair_trust_connect_agent.py"
# WD_BT_LAUNCH="/usr/local/bin/bt-autopair-trust-connect.sh"
# WD_BT_UNIT="bt-autopair-trust-connect.service"
# WD_BT_UNIT_DST="/etc/systemd/system/${WD_BT_UNIT}"
# Source Files
# SRC_BT_AGENT="${SRC}/bluetooth/bt_autopair_trust_connect_agent.py"
# SRC_BT_LAUNCH="${SRC}/bluetooth/bt-autopair-trust-connect.sh"
# SRC_BT_UNIT="${SRC}/bluetooth/${WD_BT_UNIT}"

# # =========================
# # Install Auto Pair/Trust/Connect Bluetooth agent (root service)
# # =========================
# say "installing bluetooth auto-pair agent + launcher + service (root)…"
# if [[ -f "$SRC_BT_AGENT" ]]; then
#   install_file_root "$SRC_BT_AGENT" "$WD_BT_AGENT" 755
#   prep_script_root "$WD_BT_AGENT"
# else
#   say "WARN: bluetooth agent missing at ${SRC_BT_AGENT}"
# fi
#
# if [[ -f "$SRC_BT_LAUNCH" ]]; then
#   install_file_root "$SRC_BT_LAUNCH" "$WD_BT_LAUNCH" 755
#   prep_script_root "$WD_BT_LAUNCH"
# else
#   say "WARN: bluetooth launcher missing at ${SRC_BT_LAUNCH}"
# fi
#
# if [[ -f "$SRC_BT_UNIT" ]]; then
#   install_file_root "$SRC_BT_UNIT" "$WD_BT_UNIT_DST" 644
#   sudo systemctl daemon-reload
#   sudo systemctl reenable "$WD_BT_UNIT" >/dev/null || true
#   # enable, but don’t start during install (avoids Wi-Fi/SSH blips)
#   sudo systemctl enable "$WD_BT_UNIT" || true
#   sudo systemctl is-enabled "$WD_BT_UNIT" && echo "[confirm] ${WD_BT_UNIT} enabled"
# else
#   say "WARN: ${SRC_BT_UNIT} not found; bluetooth service not installed."
# fi
