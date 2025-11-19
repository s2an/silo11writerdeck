#!/usr/bin/env python3
# File: menu.py
# Description: curses TUI (design split into theme/layout/widgets)

import curses
import time
import subprocess

from .actions import (
    # ---------- Writing Suite ----------
    run_diary,
    run_emacs,
    run_gedit,
    run_nano,
    run_obsidian,
    run_vim,
    run_wordgrinder,
    # helper
    get_last_used,

    # ---------- File Operations ----------
    # run_import_files
    run_builtin_http_server,

    # ---------- Network Tools ----------
    run_bluetoothctl_shell,
    run_nmtui_wifi,

    # ---------- Display & Themes ----------
    get_current_rotation,
    rotation_label, # used in actions
    set_rotation,
    launch_theme_switcher_action,

    # ---------System Maintenance -----------
    launch_healthcheck_action,
    launch_update_action,
    launch_uninstall_action,

    # ---------- Power Controls ----------
    bt_power,
    wifi_power,
    reboot_pi,
    shutdown_pi,

    # ---------- Unauthorized Zone ----------
    launch_custom_bluetooth,
    run_custom_http_server,
    run_custom_wifi,
    exit_to_console,
)

from .view import draw_silo_hud, select_loop
from .theme import init_theme
from .widgets import wide_kerning, error_dialog, confirm_action, confirm_reboot_dialog

TITLE = "silo11writerdeck"

# ======================================================================
#  Writing Suite
# ======================================================================

def launch_diary_action(stdscr):
    return run_diary(stdscr)

def launch_emacs_action(stdscr):
    return run_emacs(stdscr)

def launch_gedit_action(stdscr):
    return run_gedit(stdscr)

def launch_nano_action(stdscr):
    return run_nano(stdscr)

def launch_obsidian_action(stdscr):
    return run_obsidian(stdscr)

def launch_vim_action(stdscr):
    return run_vim(stdscr)

def launch_wordgrinder_action(stdscr):
    return run_wordgrinder(stdscr)

import platform

IS_MACOS = (platform.system() == "Darwin")
IS_LINUX = (platform.system() == "Linux")

def writing_suite_menu(stdscr):
    if IS_LINUX:
        MENU = [
          ("Emacs",        "∞",  launch_emacs_action),        # infinite extensibility
          ("Nano",         "•",  launch_nano_action),         # quick edit
          ("Vim",          "✍",  launch_vim_action),          # modal cycles / edit loop
          ("WordGrinder",  "⌨", launch_wordgrinder_action),   # keyboard-driven writing
          ("Back",         "◀",  None),
        ]
    elif IS_MACOS:
        MENU = [
          ("Diary",        "✎", launch_diary_action),         # personal log / journal
          ("Emacs",        "∞",  launch_emacs_action),        # infinite extensibility
          ("Gedit",        "⌗", launch_gedit_action),         # GUI text editor
          ("Nano",         "•",  launch_nano_action),         # quick edit
          ("Obsidian",     "🜛", launch_obsidian_action),      # vault / alchemy symbol vibe
          ("Vim",          "✍",  launch_vim_action),          # modal cycles / edit loop
          ("WordGrinder",  "⌨", launch_wordgrinder_action),   # keyboard-driven writing
          ("Back",         "◀",  None),
        ]
        
    labels  = [label for label, _, _ in MENU]
    icons   = [icon  for _, icon, _ in MENU]
    actions = [func  for _, _, func in MENU]

    while True:
        choice = select_loop(stdscr, "WRITING SUITE", labels, icons=icons, current=0)
        action = actions[choice]
        if action is None:
            return
        action(stdscr)

LAST_USED_LAUNCHERS = {
    "diary": launch_diary_action,
    "emacs": launch_emacs_action,
    "gedit": launch_gedit_action,
    "nano": launch_nano_action,
    "obsidian": launch_obsidian_action,
    "vim": launch_vim_action,
    "wordgrinder": launch_wordgrinder_action,
}

def last_used_menu_item():
    """
    Returns (label, icon, handler) tuple for Main Menu or None if not available.
    Handler will be a small thunk that dispatches to the proper launcher.
    """
    app_id = get_last_used()
    if not app_id:
        return None
    launcher = LAST_USED_LAUNCHERS.get(app_id)
    if not launcher:
        return None

    label = f"Last Used: {app_id.title()}"
    icon = "↻"

    def _handler(stdscr):
        # delegate to the real launcher
        return launcher(stdscr)

    return (label, icon, _handler)

# ======================================================================
#  File Operations
# ======================================================================

def launch_export_files_action(stdscr):
    run_builtin_http_server(stdscr)

def file_ops_menu(stdscr):
    MENU = [
        ("Export File(s)", "⇪", launch_export_files_action),
        # ("Import File(s)", "down arrow", launch_import_files_action), # placeholder for future feature
        ("Back",           "◀", None),
    ]
    labels  = [label for label, _, _ in MENU]
    icons   = [icon  for _, icon, _ in MENU]
    actions = [func  for _, _, func in MENU]
    while True:
        choice = select_loop(stdscr, "FILE OPERATIONS", labels, icons=icons, current=0)
        action = actions[choice]
        if action is None:
            return
        action(stdscr)
 
# ======================================================================
#  Network Tools
# ======================================================================

def launch_bluetooth_action(stdscr):
    run_bluetoothctl_shell(stdscr)

def launch_wifi_action(stdscr):
    run_nmtui_wifi(stdscr)

def network_tools_menu(stdscr):
    MENU = [
        ("Bluetooth (ctl)", "☍", launch_bluetooth_action),
        ("Wi-Fi (nmtui)",   "≋", launch_wifi_action),
        ("Back",            "◀", None),
    ]
    labels  = [label for label, _, _ in MENU]
    icons   = [icon  for _, icon, _ in MENU]
    actions = [func  for _, _, func in MENU]
    while True:
        choice = select_loop(stdscr, "NETWORK TOOLS", labels, icons=icons, current=0)
        action = actions[choice]
        if action is None:
            return
        action(stdscr)

# ======================================================================
#  Display & Themes
# ======================================================================

def launch_rotation_action(stdscr):
    curses.curs_set(0)
    current_val = get_current_rotation()
    current_txt = rotation_label(current_val)
    # Ordered by physical orientation rather than alphabetically.
    MENU = [
        ("0° (normal)",                    "⤾", 0),
        ("90° (portrait clockwise)",       "⤾", 1),
        ("180° (upside down)",             "⤾", 2),
        ("270° (portrait counter-clockwise)","⤾", 3),
        ("Back",                           "◀", None),
    ]
    labels  = [label for label, _, _ in MENU]
    icons   = [icon  for _, icon, _ in MENU]
    values  = [val   for _, _, val in MENU]

    pick = select_loop(stdscr, f"DISPLAY ROTATION (current = {current_txt})", labels, icons=icons, current=0)
    label, val = labels[pick], values[pick]
    if val is None:
        return
    try:
        set_rotation(val)
        choice = confirm_reboot_dialog(stdscr, label)
        if choice == 0:
            # this might be able to be deleted
            # reboot_pi()
            reboot_pi(stdscr=stdscr)
    except Exception as e:
        error_dialog(stdscr, f"Failed to set rotation: {e}", title="ROTATION ERROR")

def display_and_themes_menu(stdscr):
    MENU = [
        ("Screen Rotation", "⤾", launch_rotation_action),
        ("Theme Switcher",  "◐", launch_theme_switcher_action),
        ("Back",            "◀", None),
    ]
    labels  = [label for label, _, _ in MENU]
    icons   = [icon  for _, icon, _ in MENU]
    actions = [func  for _, _, func in MENU]
    while True:
        choice = select_loop(stdscr, "DISPLAY & THEMES", labels, icons=icons, current=0)
        action = actions[choice]
        if action is None:
            return
        action(stdscr)

# ======================================================================
#  System Maintenance
# ======================================================================

def system_maintenance_menu(stdscr):
    MENU = [
        ("Health Check", "☑", launch_healthcheck_action),
        ("Update",       "⟳", launch_update_action),
        ("Uninstall",    "⊖", launch_uninstall_action),
        ("Back",         "◀", None),
    ]
    labels  = [label for label, _, _ in MENU]
    icons   = [icon  for _, icon, _ in MENU]
    actions = [func  for _, _, func in MENU]

    while True:
        choice = select_loop(stdscr, "SYSTEM MAINTENANCE", labels, icons=icons, current=0)
        action = actions[choice]
        label  = labels[choice]

        if action is None:
            return

        action(stdscr)

# ======================================================================
#  Power Controls
# ======================================================================

# Local toggle actions for Bluetooth & Wi-Fi
def toggle_bluetooth_action(stdscr):
    pick = select_loop(stdscr, "BLUETOOTH POWER", ["Power On", "Power Off", "Back"], icons=["⏻", "⭘", "◀"])
    if pick == 0:
        draw_silo_hud(stdscr, "BLUETOOTH — POWERING ON…")
        stdscr.refresh(); time.sleep(0.2)
        bt_power(True, stdscr=stdscr)
    elif pick == 1:
        draw_silo_hud(stdscr, "BLUETOOTH — POWERING OFF…")
        stdscr.refresh(); time.sleep(0.2)
        bt_power(False, stdscr=stdscr)

def toggle_wifi_action(stdscr):
    pick = select_loop(stdscr, "WI-FI POWER", ["Enable Wi-Fi", "Disable Wi-Fi", "Back"], icons=["⏻", "⭘", "◀"])
    if pick == 0:
        draw_silo_hud(stdscr, "WI-FI — ENABLING…")
        stdscr.refresh(); time.sleep(0.2)
        wifi_power(True, stdscr=stdscr)
    elif pick == 1:
        draw_silo_hud(stdscr, "WI-FI — DISABLING…")
        stdscr.refresh(); time.sleep(0.2)
        wifi_power(False, stdscr=stdscr)

def restart_pi_action(stdscr):
    pick = select_loop(stdscr, "CONFIRM RESTART", ["Restart now", "Back"], icons=["↻", "◀"])
    if pick == 0:
        draw_silo_hud(stdscr, "RESTARTING — HOLD FAST…")
        stdscr.refresh(); time.sleep(0.3)
        reboot_pi(stdscr=stdscr)

def shutdown_pi_action(stdscr):
    pick = select_loop(stdscr, "CONFIRM SHUTDOWN", ["Shut down", "Back"], icons=["⭘", "◀"])
    if pick == 0:
        draw_silo_hud(stdscr, "POWERING DOWN — VENTS SEAL…")
        stdscr.refresh(); time.sleep(0.3)
        shutdown_pi(stdscr=stdscr)

def power_controls_menu(stdscr):
    MENU = [
        ("Bluetooth Power", "⌁", toggle_bluetooth_action),
        ("Wi-Fi Power",     "↯", toggle_wifi_action),
        ("Reboot",   "↻", restart_pi_action),
        ("Shutdown", "⭘", shutdown_pi_action),
        ("Back",     "◀", None),
    ]
    labels  = [label for label, _, _ in MENU]
    icons   = [icon  for _, icon, _ in MENU]
    actions = [func  for _, _, func in MENU]
    while True:
        choice = select_loop(stdscr, "POWER CONTROLS", labels, icons=icons, current=0)
        action = actions[choice]
        if action is None:
            return
        action(stdscr)

# ======================================================================
#  Unauthorized Zone
# ======================================================================

def launch_custom_bluetooth_action(stdscr):
    launch_custom_bluetooth(stdscr)

def launch_run_custom_http_server_action(stdscr):
    run_custom_http_server(stdscr)

def launch_run_custom_wifi_action(stdscr):
    run_custom_wifi(stdscr)

def launch_exit_to_console_action(stdscr):
    curses.endwin()
    exit_to_console()

def unauthorized_zone_menu(stdscr):
    MENU = [
        ("Salvage Peripherals (custom Bluetooth)",     "☍", launch_custom_bluetooth_action),
        ("Transmit to the Wastes (custom http_server)","▤", launch_run_custom_http_server_action),
        ("Connect to the Wastes (custom Wi-Fi)",       "≋", launch_run_custom_wifi_action),
        ("Exit to Console",                            "⚙", launch_exit_to_console_action), # stays last in list
        ("Back",                                       "◀", None),
    ]

    labels  = [label for label, _, _ in MENU]
    icons   = [icon  for _, icon, _ in MENU]
    actions = [func  for _, _, func in MENU]

    while True:
        choice = select_loop(stdscr, "UNAUTHORIZED ZONE", labels, icons=icons, current=0)
        action = actions[choice]
        if action is None:
            return
        action(stdscr)

# ======================================================================
#  Main Menu (needs to stay down here to call the methods)
# ======================================================================

def build_main_menu():
    MAIN_MENU = [
        ("Writing Suite",       "⌨", writing_suite_menu),
        ("File Operations",     "⇪", file_ops_menu),
        ("Network Tools",       "≋", network_tools_menu),
        ("Display & Themes",    "◐", display_and_themes_menu),
        ("System Maintenance",  "⚙", system_maintenance_menu),
        ("Power Controls",      "↻", power_controls_menu),
        ("Unauthorized Zone",   "⚠", unauthorized_zone_menu),
    ]
    lu = last_used_menu_item()
    if lu:
        # Put "Last Used" at the very top for fast access
        MAIN_MENU.insert(0, lu)
    return MAIN_MENU

def draw_main_menu(stdscr, current):
    draw_silo_hud(stdscr, TITLE, 1)

def main_menu_loop(stdscr):
    curses.curs_set(0)
    init_theme()
    current = 0
    MAIN_MENU = build_main_menu()
    labels  = [label for label, _, _ in MAIN_MENU]
    icons   = [icon  for _, icon, _ in MAIN_MENU]
    actions = [func  for _, _, func in MAIN_MENU]

    while True:
        choice = select_loop(
            stdscr,
            wide_kerning(TITLE, 1),
            labels,
            icons=icons,
            current=current,
        )
        actions[choice](stdscr)
        current = choice
        # Rebuild to surface updated "Last Used" on return
        MAIN_MENU = build_main_menu()
        labels  = [label for label, _, _ in MAIN_MENU]
        icons   = [icon  for _, icon, _ in MAIN_MENU]
        actions = [func  for _, _, func in MAIN_MENU]

def main(stdscr):
    try:
        main_menu_loop(stdscr)
    except KeyboardInterrupt:
        # Exit quietly back to shell
        return

if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        print(f"\n👋 Back in the shell.\nFrom the repo root, relaunch with:\n  python3 -m tui.menu\n")
        print("You've strayed beyond the wastes. Relaunch with: silo11writerdeck")
        print("If you never set a PATH, relaunch with:  python3 -m tui")