#!/usr/bin/env python3
# File: actions.py
# Description: Helper functions invoked by menu.py (no curses unless explicitly passed in)
# Flavor-only: silo/courier wording for user-visible messages

import os
import time
import curses
import socket
import subprocess
import shlex
from pathlib import Path
import re
from datetime import datetime
import platform
import shutil

from .view import select_loop, draw_silo_hud
from .widgets import success_dialog, error_dialog, confirm_action
from .theme import init_theme, set_theme, get_theme, available_themes
from .layout import safe_addnstr_inner, draw_centered_inner


# ---------- Utilities ----------
CONFIG = Path("/boot/firmware/config.txt")
KEY = "display_hdmi_rotate"  # values: 0=0°, 1=90°, 2=180°, 3=270°

def _sudo_run(cmd: str, check: bool = True) -> subprocess.CompletedProcess:
    """Run command with sudo in a login shell, capture output."""
    return subprocess.run(["sudo", "bash", "-lc", cmd], check=check, text=True, capture_output=True)

# ---------- OS detection / UX helpers ----------
IS_MACOS = (platform.system() == "Darwin")
IS_LINUX  = (platform.system() == "Linux")

# ---------- Cross-platform UX helpers (standardized macOS messaging) ----------
def launch_app(
    stdscr,
    *,
    label: str,
    kind: str,                      # "tui" or "gui"
    hint_tool: str,                 # name for hints ("Vim", "Gedit", "Obsidian")
    mac_app: str | None = None,     # GUI app name for macOS `open -a`
    argv: list[str] | None = None,  # command to run on this OS (CLI path/name)
    apt_pkg: str | None | bool = None,
    brew_pkg: str | None | bool = None,
    brew_cask: bool = False,
):
    """
    Unified launcher:
      - kind="tui": suspend curses, run, restore; errors shown in-TUI.
      - kind="gui": stay in curses; on macOS uses `open -a`, on Linux spawns GUI binary (Popen).
    All failures: show error_dialog/_missing_tool_hint inside TUI (no console flicker).
    """
    if kind not in ("tui", "gui"):
        error_dialog(stdscr, f"Invalid launcher kind: {kind}", title="Launcher Error")
        return

    # Determine command for *this* OS when not using macOS `open -a`
    cmd_this = (argv or [hint_tool])

    if kind == "gui":
        if IS_MACOS:
            # macOS GUI path via `open -a`
            target = mac_app or hint_tool
            rc = subprocess.run(["/usr/bin/open", "-a", target]).returncode
            if rc != 0:
                _missing_tool_hint(hint_tool, brew_pkg=(brew_pkg if brew_pkg is not None else hint_tool.lower()), brew_cask=brew_cask, stdscr=stdscr)
            return
        # Linux/other GUI path – fire-and-forget
        try:
            subprocess.Popen(cmd_this, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except FileNotFoundError:
            _missing_tool_hint(hint_tool, brew_pkg=brew_pkg, apt_pkg=(apt_pkg if apt_pkg is not None else hint_tool.lower()), stdscr=stdscr)
        except Exception as e:
            error_dialog(stdscr, f"{label} failed: {e}", title=f"{label} ERROR")
        return

    # kind == "tui"
    try:
        curses.endwin()
        try:
            rc = subprocess.run(cmd_this).returncode
        except FileNotFoundError:
            rc = 127
    finally:
        try:
            stdscr.clear(); curses.doupdate()
        except Exception:
            pass

    if rc == 0:
        return
    if rc == 127:
        _missing_tool_hint(hint_tool, brew_pkg=brew_pkg, apt_pkg=(apt_pkg if apt_pkg is not None else hint_tool.lower()), stdscr=stdscr)
    else:
        error_dialog(stdscr, f"{label} exited with code {rc}", title=f"{label} ERROR")

def _macos_block(stdscr, feature: str, settings_path: str, title: str = "Not Supported on macOS"):
    """
    Show a consistent 'managed by macOS' message.
    Example: _macos_block(stdscr, "Wi-Fi", "System Settings → Wi-Fi")
    """
    msg = f"{feature} is managed by macOS. Use  menu → {settings_path}."
    if stdscr is not None:
        error_dialog(stdscr, msg, title=title)
    else:
        print("⛓️  [silo] " + msg)

def _missing_tool_hint(
    tool: str,
    *,
    apt_pkg: str | None | bool = None,    # None => infer; ""/False => disable apt hint on Linux
    brew_pkg: str | None | bool = None,   # None => infer; ""/False => disable brew hint on macOS
    brew_cask: bool = False,
    stdscr=None
):
    """
    Platform-aware 'tool not found' hint.

    Defaults:
      - If brew_pkg is None on macOS, infer brew_pkg = tool.lower()
      - If apt_pkg is None on Linux,  infer apt_pkg  = tool.lower()

    Edge-case:
      - To *disable* Homebrew hint on macOS (no known formula), pass brew_pkg="" (or False).
        This prevents falling back to apt on macOS and shows a neutral macOS message instead.
    """
    # Decide platform-specific suggestion
    if IS_MACOS:
        # If explicitly disabled, show a neutral macOS message
        if brew_pkg is False or brew_pkg == "":
            msg = f"{tool} is not available via Homebrew on macOS."
        else:
            # Infer default package name if not provided
            pkg = (brew_pkg if isinstance(brew_pkg, str) else tool.lower())
            if brew_cask:
                msg = f"{tool} not found. Provision with: brew install --cask {pkg}"
            else:
                msg = f"{tool} not found. Provision with: brew install {pkg}"
    else:
        # Linux / other
        # If explicitly disabled, show a neutral "not via apt" message
        if apt_pkg is False or apt_pkg == "":
            # Keep it generic so this helper works for any tool (Obsidian included)
            msg = f"{tool} is not available via apt on this system."
            # (Optional) You can append your own project hint elsewhere if you want.
        else:
            # Infer apt package if not provided
            pkg = (apt_pkg if isinstance(apt_pkg, str) and apt_pkg else tool.lower())
            msg = f"{tool} not found. Provision with: sudo apt install {pkg}"
 

    if stdscr is not None:
        error_dialog(stdscr, msg, title="Missing Tool")
    else:
        print("⛓️  [silo] " + msg)

# --- Last Used (lightweight, state-only) ---------------------------------------
from typing import Optional

def _state_dir() -> Path:
    xdg_state = os.environ.get("XDG_STATE_HOME")
    base = Path(xdg_state) if xdg_state else Path.home() / ".local" / "state"
    d = base / "silo11writerdeck"
    d.mkdir(parents=True, exist_ok=True)
    return d

_LAST_USED_FILE = _state_dir() / "last_used.txt"

def record_last_used(app_id: str) -> None:
    """Persist the last-used writing app id (e.g., 'vim', 'gedit')."""
    try:
        _LAST_USED_FILE.write_text(app_id.strip() + "\n", encoding="utf-8")
    except Exception:
        # Non-fatal; launching should not fail because we couldn't write state.
        pass

def get_last_used() -> Optional[str]:
    """Return last-used app id or None if unknown."""
    try:
        text = _LAST_USED_FILE.read_text(encoding="utf-8").strip()
        return text or None
    except Exception:
        return None

def run_app_and_record(app_id: str, cmd: list[str]) -> int:
    """
    Convenience runner for writing apps.
    Usage: return run_app_and_record("vim", ["vim"])
    """
    record_last_used(app_id)
    try:
        return subprocess.run(cmd).returncode
    finally:
        # (Nothing else for now; hook for future telemetry if needed)
        pass
# --- /Last Used ----------------------------------------------------------------

# ---------- Footer Integration ----------
def draw_default_footer(stdscr):
    """Smart default footer for silo11writerdeck menus."""
    try:
        from .widgets import draw_footer_integrated_mainmenu
        from .view import DEFAULT_HINTS
        draw_footer_integrated_mainmenu(stdscr, hints=DEFAULT_HINTS)
    except Exception:
        pass  # silently skip if curses/widgets fail

# ======================================================================
#  Writing Suite
# ======================================================================

def run_diary(stdscr=None):
    record_last_used("diary")
    launch_app(
        stdscr,
        label="Diary",
        kind="tui",
        hint_tool="Diary",
        argv=["diary"],
        apt_pkg=False,
        brew_pkg="diary",
    )

def run_emacs(stdscr=None):
    record_last_used("emacs")
    launch_app(
        stdscr,
        label="Emacs",
        kind="tui",
        hint_tool="Emacs",
        argv=["emacs"],
        apt_pkg="emacs",
        brew_pkg="emacs",
    )

def run_gedit(stdscr=None):
    record_last_used("gedit")
    launch_app(
        stdscr,
        label="Gedit",
        kind="gui",
        hint_tool="Gedit",
        mac_app="Gedit",
        argv=["gedit"],
        apt_pkg=False,
        brew_pkg="gedit",
    )

def run_nano(stdscr=None):
    record_last_used("nano")
    launch_app(
        stdscr,
        label="Nano",
        kind="tui",
        hint_tool="nano",
        argv=["nano"],
        apt_pkg="nano",
        brew_pkg="nano",
    )

def run_obsidian(stdscr=None):
    record_last_used("obsidian")
    launch_app(
        stdscr,
        label="Obsidian",
        kind="gui",
        hint_tool="Obsidian",
        mac_app="Obsidian",
        argv=["obsidian"],
        apt_pkg=False,
        brew_pkg="obsidian",
        brew_cask=True,
    )

def run_vim(stdscr=None):
    record_last_used("vim")
    launch_app(
        stdscr,
        label="Vim",
        kind="tui",
        hint_tool="vim",
        argv=["vim"],
        apt_pkg="vim",
        brew_pkg="vim",
    )

def run_wordgrinder(stdscr=None):
    record_last_used("wordgrinder")
    launch_app(
        stdscr,
        label="WordGrinder",
        kind="tui",
        hint_tool="WordGrinder",
        argv=["wordgrinder"],
        apt_pkg="wordgrinder",
        brew_pkg="wordgrinder",
    )

# ======================================================================
#  File Operations
# ======================================================================

def _choose_export_dir_and_url(preferred_rel: str = "silo11writerdeck/!save_files_here", home_dir: str | None = None):
    """Choose export directory and compute URL path for UI."""
    if home_dir is None:
        home_dir = os.path.expanduser("~")

    preferred_dir = os.path.join(home_dir, preferred_rel)
    if os.path.isdir(preferred_dir):
        # Our HTTP server serves EXPORT_DIR as its docroot, so the URL to it is simply "/".
        EXPORT_DIR = preferred_dir
        url_path = "/"
    else:
        # Fallback: serve $HOME at root (same URL path)
        EXPORT_DIR = home_dir
        url_path = "/"

    return EXPORT_DIR, url_path, home_dir

def run_builtin_http_server(stdscr, port: int = 8080):
    LOG = "/tmp/builtin_http_server.log"
    EXPORT_DIR, url_path, _home = _choose_export_dir_and_url()

    def _port_open(p=port):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.25)
        try:
            return s.connect_ex(("127.0.0.1", p)) == 0
        finally:
            s.close()

    cmd = ["python3", "-m", "http.server", str(port), "--directory", EXPORT_DIR]

    # DRY: use shared HUD so visuals & footer match main menu
    try:
        draw_silo_hud(stdscr, f"EXPORT DOCK // PORT {port}")
    except Exception:
        stdscr.clear()

    if _port_open():
        safe_addnstr_inner(stdscr, 4, 2, "📡 Built-in HTTP server already running.")
    else:
        with open(LOG, "ab", buffering=0) as f:
            subprocess.Popen(cmd, stdout=f, stderr=f, start_new_session=True)
        safe_addnstr_inner(stdscr, 4, 2, "📡 Built-in HTTP server started.")

    # Determine LAN IP
    ip = "127.0.0.1"
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
    except Exception:
        pass

    safe_addnstr_inner(stdscr, 6, 2,  "Relay the dock to a runner device on the same LAN:")
    safe_addnstr_inner(stdscr, 8,  2, f"   http://{ip}:{port}{url_path}")
    safe_addnstr_inner(stdscr, 10, 2, "Open the URL above in a browser on another device to download files.")
    safe_addnstr_inner(stdscr, 12, 2, f"(Serving from: {EXPORT_DIR})")
    safe_addnstr_inner(stdscr, 14, 2, f"(logs: {LOG})")
    draw_default_footer(stdscr)
    safe_addnstr_inner(stdscr, 16, 2, "Press any key to return to menu.")
    stdscr.refresh()
    stdscr.getch()

# ======================================================================
#  Network Tools
# ======================================================================

# ----------Wi-Fi: Network Manager TUI ----------

def run_nmtui_wifi(stdscr):
    """
    UI-first wrapper for NetworkManager's TUI:
    - On macOS: show a dialog (Linux-only feature).
    - On Linux: briefly show a HUD, drop to nmtui, then return cleanly.
    """
    if IS_MACOS:
        _macos_block(stdscr, "Wi-Fi", "System Settings → Wi-Fi")
        return
    try:
        draw_silo_hud(stdscr, "NETWORK MANAGER // nmtui")
        stdscr.refresh(); time.sleep(0.15)
    except Exception:
        pass
    curses.endwin()
    subprocess.run(["nmtui"])
    stdscr.clear(); curses.doupdate()

# ---------- Bluetoothctl Wrapper ----------

# ----- shell helpers -----
def _sh(cmd, timeout=10):
    if isinstance(cmd, str):
        cmd = shlex.split(cmd)
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except Exception as e:
        # Make 'command not found' less cryptic for callers
        if isinstance(e, FileNotFoundError):
            # Returncode 127 mimics “command not found”
            return 127, "", f"{getattr(e, 'filename', '') or 'command'} not found"
        return 1, "", str(e)

def _bt(args, timeout=10):
    return _sh(["bluetoothctl", "--"] + list(args), timeout=timeout)

def _short_mac(mac: str) -> str:
    return mac[-5:] if len(mac) >= 5 else mac

# ----- low-level bluetooth ops -----
def _bt_power(on=True):           return _bt(["power", "on" if on else "off"])
def _bt_scan(on=True):            return _bt(["scan", "on" if on else "off"])
# def _bt_pair(mac):                return _bt(["pair", mac], timeout=10)      # 10s per request
# def _bt_trust(mac):               return _bt(["trust", mac])
def _bt_connect(mac):             return _bt(["connect", mac], timeout=10)   # 10s per request
def _bt_remove(mac):              return _bt(["remove", mac])
def _bt_info(mac):                return _bt(["info", mac])
def _bt_agent_default():
    _bt(["agent", "NoInputNoOutput"])
    return _bt(["default-agent"])

_DEVICE_LINE = re.compile(r"Device\s+([0-9A-Fa-f:]{17})\s*(.*)$")

def _bt_devices():
    rc, out, err = _bt(["devices"])
    if rc != 0:
        return rc, [], err
    devs = []
    for line in out.splitlines():
        m = _DEVICE_LINE.match(line.strip())
        if m:
            mac = m.group(1)
            name = m.group(2).strip()
            devs.append((mac, name))
    return 0, devs, ""

def _bt_paired_devices():
    rc, out, err = _bt(["paired-devices"])
    if rc != 0:
        return rc, [], err
    devs = []
    for line in out.splitlines():
        m = _DEVICE_LINE.match(line.strip())
        if m:
            mac = m.group(1)
            name = m.group(2).strip()
            devs.append((mac, name))
    return 0, devs, ""

# ----- bluetooth UI helpers -----
def _flash_status(stdscr, msg, delay=0.8):
    draw_silo_hud(stdscr, msg)
    stdscr.refresh()
    time.sleep(delay)

def _labels_with_disambiguation(devs):
    """
    devs: list[(mac, name)] ; returns labels[] with duplicate names suffixed ‹:xx:xx›
    """
    counts = {}
    bases = []
    for mac, nm in devs:
        nm = (nm or "").strip()
        base = nm if nm else mac
        bases.append(base)
        counts[base] = counts.get(base, 0) + 1

    labels = []
    for (mac, nm), base in zip(devs, bases):
        if counts.get(base, 0) > 1:
            labels.append(f"{base} ‹{_short_mac(mac)}›")
        else:
            labels.append(base)
    return labels

# ----- Bluetooth Connect view (Paired only) -----
def _view_connect(stdscr):
    """
    Lists paired devices only (fast; no scan). No icons in lists.
    """
    _flash_status(stdscr, "Loading paired devices…", delay=0.2)
    _bt_power(True)  # best effort

    rc_p, paired, err_p = _bt_paired_devices()
    if rc_p != 0:
        # Tailored macOS message (no bluetoothctl/BlueZ)
        if IS_MACOS and shutil.which("bluetoothctl") is None:
            _macos_block(stdscr, "Bluetooth", "System Settings → Bluetooth")
        return

    paired_list = list(paired)

    labels = []
    entries = []  # (mac, name) OR ("refresh"/"back", None)
    if paired_list:
        labels.append("— Paired —"); entries.append(("header", None))
        labels += _labels_with_disambiguation(paired_list)
        entries += [(mac, (nm or mac) or mac) for mac, nm in paired_list]

    # Always provide refresh/back
    labels += ["Refresh", "Back"]
    entries += [("refresh", None), ("back", None)]

    while True:
        idx = select_loop(stdscr, "BLUETOOTH // CONNECT (Paired)", labels, current=0)
        mac, name = entries[idx]

        if mac == "header":
            continue
        if mac == "refresh":
            return _view_connect(stdscr)  # rebuild the view fresh
        if mac == "back":
            return

        actions = ["Connect", "Remove", "Info", "Back"]
        pick = select_loop(stdscr, f"Paired: {name}", actions, current=0)
        if pick == 0:
            _flash_status(stdscr, f"Connecting {name}…", delay=0.1)
            rc, out, err = _bt_connect(mac)
            if rc != 0:
                error_dialog(stdscr, f"Connect failed:\n{err or out}", title="Connect")
            else:
                _flash_status(stdscr, "Link established")
        elif pick == 1:
            if confirm_action(stdscr, f"Remove {name}?"):
                _flash_status(stdscr, f"Removing {name}…", delay=0.1)
                rc, out, err = _bt_remove(mac)
                if rc != 0:
                    error_dialog(stdscr, f"Remove failed:\n{err or out}", title="Remove")
                else:
                    _flash_status(stdscr, "Removed")
                    return _view_connect(stdscr)  # refresh list
        elif pick == 2:
            rc, out, err = _bt_info(mac)
            if rc != 0:
                error_dialog(stdscr, f"Info failed:\n{err or out}", title="Info")
            else:
                error_dialog(stdscr, out or "(no info)", title=f"Info — {name}")
        else:
            continue

# ----- Bluetooth Add Device (scan, then attempt direct connect; NO auto-pair/trust) -----
def _view_add_device(stdscr, scan_seconds=6):
    _bt_agent_default()
    _flash_status(stdscr, f"Scanning for ~{scan_seconds}s…", delay=0.1)
    rc, _, err = _bt_power(True)
    if rc != 0:
        error_dialog(stdscr, f"Power on failed:\n{err}", title="Power")
        return

    _bt_scan(True); time.sleep(max(3, int(scan_seconds))); _bt_scan(False)

    rc, devs, err = _bt_devices()
    if rc != 0 or not devs:
        error_dialog(stdscr, "No devices discovered. Try again.", title="Scan")
        return

    labels = _labels_with_disambiguation(devs) + ["Back"]
    pick = select_loop(stdscr, "ADD DEVICE // SELECT TARGET", labels, current=0)
    if pick == len(labels) - 1:
        return

    mac, name = devs[pick]
    disp = (name or mac).strip() or mac

    # Do NOT auto-pair or auto-trust. Attempt direct connect only.
    _flash_status(stdscr, f"Connecting {disp}…", delay=0.1)
    rc, out, err = _bt_connect(mac)
    if rc != 0:
        error_dialog(stdscr, f"Connect failed (device may require pairing):\n{err or out}", title="Connect")
    else:
        _flash_status(stdscr, "Link established")

# ----- Bluetooth Power & Controller helpers (HUD-first) -----

# def _flow_power_toggle(stdscr, turn_on=True):
#     _flash_status(stdscr, f"Power {'on' if turn_on else 'off'}…", delay=0.1)
#     rc, out, err = _bt_power(turn_on)
#     if rc != 0:
#         error_dialog(stdscr, f"Power {'on' if turn_on else 'off'} failed:\n{err or out}", title="Power")
#     else:
#         _flash_status(stdscr, f"Power {'enabled' if turn_on else 'disabled'}")

def _flow_controller_info(stdscr):
    _flash_status(stdscr, "Querying controllers…", delay=0.1)
    rc, out, err = _bt(["list"])
    if rc != 0:
        error_dialog(stdscr, f"Controller list failed:\n{err or out}", title="Controllers")
        return
    ctrls = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("Controller "):
            parts = line.split(None, 2)
            if len(parts) >= 2:
                mac = parts[1]
                name = parts[2] if len(parts) == 3 else mac
                ctrls.append((mac, name))
    if not ctrls:
        error_dialog(stdscr, "No controllers found.", title="Controllers")
        return
    if len(ctrls) == 1:
        ctrl_mac = ctrls[0][0]
    else:
        labels = [f"{name} [{mac}]" for mac, name in ctrls] + ["Back"]
        pick = select_loop(stdscr, "CONTROLLERS — SELECT", labels, current=0)
        if pick == len(labels) - 1:
            return
        ctrl_mac = ctrls[pick][0]

    rc, out, err = _bt(["show", ctrl_mac])
    if rc != 0:
        error_dialog(stdscr, f"Show failed:\n{err or out}", title="Controller info")
    else:
        error_dialog(stdscr, out or "(no info)", title="Controller info")

# ----- Bluetooth Top-level menu (icons only here) -----
def run_bluetoothctl_shell(stdscr):
    """
    Main wrapper entrypoint referenced by the main menu.
    Icons only at top level. 'Connect' lists paired devices only.
    'Add Device' scans and lets you attempt Connect (no auto-pair/trust).
    """
    # Proactive macOS check so we show a helpful dialog instead of crashing later.
    if IS_MACOS and shutil.which("bluetoothctl") is None:
        _macos_block(stdscr, "Bluetooth", "System Settings → Bluetooth")
        return

    _bt_agent_default()  # smoother pairing

    MENU = [
        ("Connect (Paired)", "☍", _view_connect),
        ("Add Device (Scan → Connect)", "⌕", _view_add_device),
        ("Controllers → Info", "⌁", _flow_controller_info),
        ("Back", "◀", None),
    ]

    labels  = [label for label, _, _ in MENU]
    icons   = [icon  for _, icon, _ in MENU]
    actions = [func  for _, _, func in MENU]

    while True:
        choice = select_loop(stdscr, "BLUETOOTH // CONTROL DECK", labels, icons=icons, current=0)
        action = actions[choice]
        if action is None:
            return
        action(stdscr)


# ======================================================================
#  Display & Themes
# ======================================================================

# ---------- Screen Rotation ----------
def get_current_rotation() -> int | None:
    if not CONFIG.exists(): return None
    for line in CONFIG.read_text(errors="ignore").splitlines():
        m = re.match(rf"^\s*{KEY}\s*=\s*([0-3])\s*(#.*)?$", line)
        if m: return int(m.group(1))
    return None

def set_rotation(rot_val: int) -> None:
    assert rot_val in (0,1,2,3)
    # Prevent sudo prompt / file edits on non-Pi systems (e.g., macOS)
    if not CONFIG.exists():
        raise FileNotFoundError("Screen rotation is managed by macOS. Use  menu → System Settings → Displays → Rotation.")

    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"/boot/firmware/config.txt.wb-backup-{ts}"
    _sudo_run(f"cp {shlex.quote(str(CONFIG))} {shlex.quote(backup)}")

    script = rf'''
set -e
CFG={shlex.quote(str(CONFIG))}
TMP="$(mktemp)"
if grep -Eq '^\s*{KEY}\s*=' "$CFG"; then
  awk 'BEGIN{{changed=0}}
       match($0,/^\s*{KEY}\s*=/){{print "{KEY}={rot_val}"; changed=1; next}}
       {{print}} END{{}}' "$CFG" > "$TMP"
else
  cat "$CFG" > "$TMP"
  echo "{KEY}={rot_val}" >> "$TMP"
fi
install -m 0644 "$TMP" "$CFG"
rm -f "$TMP"
'''
    _sudo_run(script)

def rotation_label(rot_val: int | None) -> str:
    mapping = {0:"0°", 1:"90°", 2:"180°", 3:"270°"}
    return mapping.get(rot_val, "not set")

# ---------- Theme Switcher ----------
def launch_theme_switcher_action(stdscr):
    """
    Persists selection via set_theme() and re-inits color pairs live.
    """
    curses.curs_set(0)
    options = [
        ("Day",   "day",   "☀"),
        ("Night", "night", "☾"),
        ("Toxic", "toxic", "☣"),
        ("Back",  None,    "◀"),
    ]
    labels = [t for (t, _, _) in options]
    icons  = [i for (_, _, i) in options]
    title = "APPEARANCE // THEME"

    while True:
        pick = select_loop(stdscr, title, labels, icons=icons, current=0)
        label, val, icon = options[pick]

        if val is None:  # 'Back'
            return

        try:
            # Persist choice and update current session palette
            set_theme(val)
            init_theme(val)
            # Brief confirmation splash, then return to the list
            banner = f"THEME SET: {label.upper()}  {icon}"
            draw_silo_hud(stdscr, banner)
            stdscr.refresh()
            time.sleep(0.25)
            # Loop continues; list always opens at the first item
        except Exception as e:
            error_dialog(stdscr, f"Failed to switch theme: {e}", title="FAULT // THEME")
            # On error, continue loop so the user can try again or back out

# ======================================================================
#  System Maintenance
# ======================================================================

# --- helpers: run CLI tools and show results -------------------------------------------------
# def _expand(path: str) -> str:
#     # Expand ~ and $VARS in user-provided paths
#     return os.path.expandvars(os.path.expanduser(path))

def _find_tool(preferred: str, fallbacks: list[str]) -> str | None:
    """
    Return a shell-safe command string to run the first existing tool.
    """
    candidates = [preferred, *fallbacks]
    for c in candidates:
        # Allow either absolute path or a bare command that resolves via PATH
        if "/" in c:
            if Path(c).exists():
                return c
        else:
            # Test if the command exists in PATH
            chk = subprocess.run(["bash", "-lc", f"command -v {c} >/dev/null 2>&1"])
            if chk.returncode == 0:
                return c
    return None

def _safe_addstr(win, y: int, x: int, s: str, maxw: int | None = None):
    """Safely write within screen bounds; avoid bottom-right overflow."""
    try:
        h, w = win.getmaxyx()
        if y < 0 or y >= h or x < 0 or x >= w:
            return
        limit = w - x
        if maxw is not None:
            limit = min(limit, maxw)
        # leave last column alone to avoid bottom-right write ERR
        limit = max(0, min(limit, (w - x - 1)))
        if limit <= 0:
            return
        win.addstr(y, x, s[:limit])
    except curses.error:
        pass

def _show_output_pager(stdscr, title: str, text: str):
    """
    Minimal scrollable pager inside curses.
    Keys: ↑/↓, PgUp/PgDn, Space, g (top), G (bottom), q/ESC to exit.
    """
    lines = text.splitlines() or [""]
    top = 0
    while True:
        h, w = stdscr.getmaxyx()
        stdscr.erase()
        if h < 2 or w < 2:
            stdscr.refresh()
            ch = stdscr.getch()
            if ch in (ord('q'), 27):
                return
            continue

        # Header
        header = f" {title} — {len(lines)} lines "
        _safe_addstr(stdscr, 0, 0, header)

        # Body
        body_h = max(1, h - 3)  # one extra line reserved for hint/footer
        for i in range(body_h):
            idx = top + i
            if idx >= len(lines):
                break
            _safe_addstr(stdscr, 1 + i, 0, lines[idx])

        # Footer + hint
        footer = f" {top+1}-{min(top+body_h, len(lines))} of {len(lines)} "
        hint   = " Press q/ESC to exit "
        footer_line = f"{footer.ljust(max(0, w - len(hint)))}{hint}"
        _safe_addstr(stdscr, h - 1, 0, footer_line)

        stdscr.refresh()

        ch = stdscr.getch()
        if ch in (ord('q'), 27):  # q or ESC
            return
        elif ch == curses.KEY_DOWN:
            if top + body_h < len(lines):
                top += 1
        elif ch == curses.KEY_UP:
            if top > 0:
                top -= 1
        else:
            # ignore all other keys
            continue

def _run_cli_tool_pager(stdscr, label: str, cmd: str):
    """
    Capture stdout+stderr and show in a scrollable TUI pager. Exit code drives the toast color.
    """
    # Run the command via bash -lc so PATH/aliases/env apply
    proc = subprocess.run(
        ["bash", "-lc", cmd],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    output = proc.stdout or ""
    title = f"{label} OUTPUT"
    _show_output_pager(stdscr, title, output)

    if proc.returncode == 0:
        success_dialog(stdscr, f"{label} completed successfully.", title="SUCCESS!")
    else:
        error_dialog(stdscr, f"{label} failed (exit {proc.returncode}).", title="MALFUNCTION!")

# --- actions: wire up healthcheck/update/uninstall -------------------------------------------

def launch_healthcheck_action(stdscr):
    cmd = _find_tool(
        "~/.local/bin/healthcheck-silo11writerdeck",
        ["healthcheck-silo11writerdeck", "./healthcheck-silo11writerdeck.sh"],
    )
    if not cmd:
        error_dialog(stdscr, "Health Check tool not found.", title="TOOL MISSING")
        return
    _run_cli_tool_pager(stdscr, "Health Check", cmd)

def launch_update_action(stdscr):
    cmd = _find_tool(
        "~/.local/bin/update-silo11writerdeck",
        ["update-silo11writerdeck", "./update-silo11writerdeck.sh"],
    )
    if not cmd:
        error_dialog(stdscr, "Update tool not found.", title="TOOL MISSING")
        return
    _run_cli_tool_pager(stdscr, "Update", cmd)

def launch_uninstall_action(stdscr):
    if not confirm_action(stdscr, "Uninstall"):
        error_dialog(stdscr, "Uninstall canceled.", title="Aborted")
        return

    cmd = _find_tool(
        "~/.local/bin/uninstall-silo11writerdeck",
        ["uninstall-silo11writerdeck", "./uninstall-silo11writerdeck.sh"],
    )
    if not cmd:
        error_dialog(stdscr, "Uninstall tool not found.", title="TOOL MISSING")
        return
    _run_cli_tool_pager(stdscr, "Uninstall", cmd)


# ======================================================================
#  Power Controls
# ======================================================================

def bt_power(on: bool, stdscr=None):
    # On macOS (no BlueZ/bluetoothctl), show managed-by-macOS dialog.
    if IS_MACOS or shutil.which("bluetoothctl") is None:
        _macos_block(stdscr, "Bluetooth", "System Settings → Bluetooth")
        return
    # Linux / BlueZ path
    rc, out, err = _bt_power(on)
    if rc != 0:
        if stdscr is not None:
            error_dialog(stdscr, f"Bluetooth power {'on' if on else 'off'} failed:\n{err or out}", title="Bluetooth Power")
        else:
            print(f"⛓️  [silo] Bluetooth power {'on' if on else 'off'} failed: {err or out}")

def wifi_power(on: bool, stdscr=None):
    if IS_MACOS or shutil.which("nmcli") is None:
        _macos_block(stdscr, "Wi-Fi", "System Settings → Wi-Fi")
        return
    cmd = ["nmcli", "radio", "wifi", "on" if on else "off"]
    subprocess.run(cmd, check=False)

def reboot_pi(stdscr=None):
    if IS_MACOS:
        _macos_block(stdscr, "Reboot", "Restart")
        return
    subprocess.run(["sudo", "reboot"])

def shutdown_pi(stdscr=None):
    if IS_MACOS:
        _macos_block(stdscr, "Shutdown", "Shut Down")
        return
    subprocess.run(["sudo", "shutdown", "now"])

def exit_to_console(): raise SystemExit(0)


# ======================================================================
#  Unauthorized Zone
# ======================================================================

# ---------- File Export (custom HTTP server) ----------
def run_custom_http_server(stdscr, port: int = 8080):
    LOG = "/tmp/export_http_server.log"
    SCRIPT = "/usr/local/bin/export_http_server.py"
    EXPORT_DIR, url_path, _home = _choose_export_dir_and_url()

    def _port_open(p=port):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.25)
        try: return s.connect_ex(("127.0.0.1", p)) == 0
        finally: s.close()

    # DRY: shared HUD (keeps patina/frame/rail/footer consistent)
    try:
        draw_silo_hud(stdscr, "TRANSMIT TO THE WASTES // TRANSMISSION UPLINK")
    except Exception:
        stdscr.clear()

    if not os.path.exists(SCRIPT):
        draw_centered_inner(stdscr, 2, "⛔ Transmission device missing in /usr/local/bin/")
        draw_centered_inner(stdscr, 4, "Install the script: export_http_server.py")
        draw_centered_inner(stdscr, 6, "Or use the built-in Export File option.")
        draw_centered_inner(stdscr, 8, "Press any key to return to the silo.")
        stdscr.refresh()
        stdscr.getch()
        return

    cmd = ["/usr/bin/python3", SCRIPT, "--dir", EXPORT_DIR, "--list"]

    if _port_open():
        safe_addnstr_inner(stdscr, 4, 2, "📡 Transmission already active.")
    else:
        with open(LOG, "ab", buffering=0) as f:
            subprocess.Popen(cmd, stdout=f, stderr=f, start_new_session=True)
        safe_addnstr_inner(stdscr, 4, 2, "📡 Transmission broadcast engaged.")

    # LAN IP
    ip = "127.0.0.1"
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
    except Exception: pass

    safe_addnstr_inner(stdscr, 6, 2,  "Relay the signal to operatives in the wastes:")
    safe_addnstr_inner(stdscr, 8,  2, f"   http://{ip}:{port}{url_path}")
    safe_addnstr_inner(stdscr, 10, 2, "Download the supply stash to any runner device.")
    safe_addnstr_inner(stdscr, 12, 2, f"(Serving from: {EXPORT_DIR})")
    safe_addnstr_inner(stdscr, 14, 2, f"(Logs archived at: {LOG})")
    draw_default_footer(stdscr)
    safe_addnstr_inner(stdscr, 16, 2, "Press any key to return to the silo.")
    stdscr.refresh()
    stdscr.getch()

# ---------- Wi-Fi (Custom: Connect to the Wastes) ----------
def _read_input_curses(stdscr, prompt: str, hidden: bool = False) -> str:
    """Read line input from curses; optionally mask characters."""
    # Print prompt at current cursor using inner-safe write to avoid spill
    y, x = stdscr.getyx()
    safe_addnstr_inner(stdscr, y, max(2, x), prompt)
    stdscr.refresh()
    buf = []
    while True:
        ch = stdscr.getch()
        if ch in (10, 13):  # Enter
            break
        if ch in (27,):  # ESC cancels
            return ""
        if ch in (curses.KEY_BACKSPACE, 127, 8):
            if buf:
                buf.pop()
                y, x = stdscr.getyx()
                stdscr.move(y, max(0, x - 1))
                stdscr.delch()
                stdscr.refresh()
            continue
        if 32 <= ch <= 126:
            buf.append(chr(ch))
            stdscr.addch(ord("*") if hidden else ch)
            stdscr.refresh()
    return "".join(buf)

def run_custom_wifi(stdscr):
    """Scan for networks and connect using wpa_cli."""
    if IS_MACOS or shutil.which("wpa_cli") is None:
        _macos_block(stdscr, "Wi-Fi", "System Settings → Wi-Fi")
        return
    try:
        draw_silo_hud(stdscr, "WIFI // SCAN & LINK")
    except Exception:
        stdscr.clear()
    safe_addnstr_inner(stdscr, 3, 2, "📡 Scanning the ether for access points…")
    stdscr.refresh()

    def _safe_run(cmd):
        return subprocess.run(cmd, capture_output=True, text=True)

    _safe_run(["sudo", "wpa_cli", "scan"])
    time.sleep(3)
    result = _safe_run(["sudo", "wpa_cli", "scan_results"])
    lines = result.stdout.strip().split("\n")

    if len(lines) <= 1:
        draw_centered_inner(stdscr, 6, "❌ No networks detected. Press any key to return.")
        stdscr.refresh()
        stdscr.getch()
        return

    # Parse scan results
    entries = []
    for line in lines[1:]:
        cols = line.split("\t")
        if len(cols) >= 5 and cols[4].strip():
            entries.append((cols[4], cols[2], cols[3], cols[0]))
    try:
        entries.sort(key=lambda x: int(x[1]), reverse=True)
    except ValueError:
        pass
    entries = entries[:10]

    try:
        draw_silo_hud(stdscr, "WIFI // NETWORKS")
    except Exception:
        stdscr.clear()
    safe_addnstr_inner(stdscr, 3, 2, "📶 Available Networks (strongest first):")
    base_y = 4
    for i, (ssid, signal, flags, _bssid) in enumerate(entries, start=1):
        sec = "🔒" if "WPA" in flags or "WEP" in flags else "🔓"
        safe_addnstr_inner(stdscr, base_y + i, 2, f"{i}. {ssid}  ({signal} dBm) {sec}")
    safe_addnstr_inner(stdscr, base_y + len(entries) + 2, 2, "Choose a network number (ESC to cancel): ")
    stdscr.refresh()

    choice_str = _read_input_curses(stdscr, "", hidden=False).strip()
    if not choice_str:
        return

    try:
        choice = int(choice_str)
        if choice < 1 or choice > len(entries):
            raise ValueError
    except ValueError:
        draw_centered_inner(stdscr, base_y + len(entries) + 4, "⛔ Invalid selection. Press any key to return.")
        stdscr.refresh()
        stdscr.getch()
        return

    ssid, _signal, flags, _bssid = entries[choice - 1]
    psk = ""
    if ("WPA" in flags) or ("WEP" in flags):
        safe_addnstr_inner(stdscr, base_y + len(entries) + 4, 2, f"🔑 Passphrase for '{ssid}': ")
        stdscr.refresh()
        psk = _read_input_curses(stdscr, "", hidden=True)
        if not psk:
            draw_centered_inner(stdscr, base_y + len(entries) + 6, "Canceled. Press any key to return.")
            stdscr.refresh()
            stdscr.getch()
            return

    safe_addnstr_inner(stdscr, base_y + len(entries) + 6, 2, "⚙️  Configuring link…")
    stdscr.refresh()

    add = _safe_run(["sudo", "wpa_cli", "add_network"])
    if add.returncode != 0 or not add.stdout.strip().isdigit():
        draw_centered_inner(stdscr, base_y + len(entries) + 8, "❌ Failed to add network. Press any key to return.")
        stdscr.refresh()
        stdscr.getch()
        return

    net_id = add.stdout.strip()
    _safe_run(["sudo", "wpa_cli", "set_network", net_id, "ssid", f"\"{ssid}\""])
    if psk:
        _safe_run(["sudo", "wpa_cli", "set_network", net_id, "psk", f"\"{psk}\""])
    else:
        _safe_run(["sudo", "wpa_cli", "set_network", net_id, "key_mgmt", "NONE"])

    _safe_run(["sudo", "wpa_cli", "select_network", net_id])
    _safe_run(["sudo", "wpa_cli", "enable_network", net_id])
    _safe_run(["sudo", "wpa_cli", "save_config"])

    safe_addnstr_inner(stdscr, base_y + len(entries) + 8, 2, "📡 Attempting link-up… (this may take a few seconds)")
    stdscr.refresh()
    time.sleep(4)

    status = _safe_run(["sudo", "wpa_cli", "status"]).stdout
    if "wpa_state=COMPLETED" in status:
        safe_addnstr_inner(stdscr, base_y + len(entries) + 10, 2, "✅ Link established. Press any key to return.")
    else:
        safe_addnstr_inner(stdscr, base_y + len(entries) + 10, 2, "⚠️  Link not confirmed yet. Press any key to return.")
    stdscr.refresh()
    stdscr.getch()

# ---------- Bluetooth (Custom: Hardware Linker) ----------
def launch_custom_bluetooth(stdscr, seconds: int = 10):
    """Kick off the pairing shell script and show timer feedback in curses."""
    script = "/usr/local/bin/bt-autopair-trust-connect.sh"
    try:
        subprocess.Popen([script])
    except FileNotFoundError:
        try:
            draw_silo_hud(stdscr, "BLUETOOTH // PAIR/TRUST/CONNECT")
        except Exception:
            stdscr.clear()
        draw_centered_inner(stdscr, 4, f"⛔ Pairing script not found: {script}")
        stdscr.refresh()
        stdscr.getch()
        return

    try:
        draw_silo_hud(stdscr, "BLUETOOTH // PAIR/TRUST/CONNECT")
    except Exception:
        stdscr.clear()
    safe_addnstr_inner(stdscr, 4, 2, f"🛰️  Beacon open — discoverable/pairable for {seconds} seconds…")
    stdscr.refresh()
    for i in range(seconds, 0, -1):
        safe_addnstr_inner(stdscr, 5, 2, f"⌛ Time remaining: {i:2d}s   ")
        stdscr.refresh()
        time.sleep(1)
    safe_addnstr_inner(stdscr, 7, 2, "🔒 Beacon sealed. Press any key to return.")
    stdscr.refresh()
    stdscr.getch()
