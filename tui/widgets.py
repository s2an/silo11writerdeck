#!/usr/bin/env python3
# File: tui/widgets.py
# Purpose: reusable, styled widgets (dialogs, footer, helpers). No screen composition.
# Responsibilities:
#   - Small, reusable UI primitives: footer, dialogs, helpers
#   - NO HUD fallback: a HUD renderer must be injected by view via set_hud_renderer()

from __future__ import annotations

import curses
import os
import random
from typing import Callable, Optional

from .theme import (
    PAIR_HIGHLIGHT, PAIR_RUST, PAIR_BODY, PAIR_DANGER,
    PAIR_OK, PAIR_WARN, PAIR_LABEL, PAIR_HINTS,
)
from .layout import (
    safe_addnstr, draw_centered, draw_bottom_bolt_rail,
)

DEFAULT_HINTS = " Navigation = ↑ ↓  Select = Enter "

# ----- HUD injection point (required) -----
_HUD_FN: Optional[Callable[[curses.window, str, str], None]] = None

def set_hud_renderer(fn: Callable[[curses.window, str, str], None]) -> None:
    """Called by view after defining draw_silo_hud. Avoids circular dependency."""
    global _HUD_FN
    _HUD_FN = fn

def _hud(stdscr, title: str, hints: str = DEFAULT_HINTS):
    """Use the injected HUD. No fallback for brevity/clarity."""
    if _HUD_FN is None:
        raise RuntimeError("HUD renderer not set. Call set_hud_renderer() from view first.")
    _HUD_FN(stdscr, title, hints)


# ----- Helpers -----
def wide_kerning(text: str, spaces: int = 1) -> str:
    spacer = " " * spaces
    return spacer.join(list(text or ""))


# ----- Status plumbing (env or random) -----
SYSTEM_CHOICES = [
    ("Stable",   PAIR_OK),
    ("Critical", PAIR_WARN),
    ("Failure",  PAIR_DANGER),
]
SEALS_CHOICES = [
    ("Intact",   PAIR_OK),
    ("Worn",     PAIR_WARN),
    ("Breached", PAIR_DANGER),
]
AIR_CHOICES = [
    ("Clean",     PAIR_OK),
    ("Poor",      PAIR_WARN),
    ("Hazardous", PAIR_DANGER),
]

SYSTEM_MAP = {"stable": SYSTEM_CHOICES[0], "critical": SYSTEM_CHOICES[1], "failure": SYSTEM_CHOICES[2]}
SEALS_MAP  = {"intact": SEALS_CHOICES[0], "worn": SEALS_CHOICES[1], "breached": SEALS_CHOICES[2]}
AIR_MAP    = {"clean": AIR_CHOICES[0], "poor": AIR_CHOICES[1], "hazardous": AIR_CHOICES[2]}

CURRENT_STATUS = None  # (system_tuple, seals_tuple, air_tuple)

def _env_or_random():
    def choose(env_name: str, mapping: dict, choices: list[tuple[str, int]]):
        val = os.environ.get(env_name, "").strip().lower()
        if val in mapping:
            return mapping[val]
        return random.choice(choices)
    system = choose("WD_SYSTEM", SYSTEM_MAP, SYSTEM_CHOICES)
    seals  = choose("WD_SEALS",  SEALS_MAP,  SEALS_CHOICES)
    air    = choose("WD_AIR",    AIR_MAP,    AIR_CHOICES)
    return system, seals, air

def get_status():
    global CURRENT_STATUS
    if CURRENT_STATUS is None:
        CURRENT_STATUS = _env_or_random()
    return CURRENT_STATUS

def set_status_for_session(system_tuple, seals_tuple, air_tuple):
    global CURRENT_STATUS
    CURRENT_STATUS = (system_tuple, seals_tuple, air_tuple)


# ----- Footer (main menu) -----
def draw_footer_integrated_mainmenu(stdscr, hints: str):
    (sys_name, sys_pair), (seal_name, seal_pair), (air_name, air_pair) = get_status()

    h, w = stdscr.getmaxyx()
    y = h - 1
    if y < 1:
        return

    draw_bottom_bolt_rail(stdscr)

    inner_w = max(0, w - 2)
    left_start = 1
    left_w = max(1, inner_w // 2)
    left_center = left_start + (left_w // 2)

    right_q_start = 1 + (inner_w * 3) // 4
    right_q_w = max(1, inner_w - ((inner_w * 3) // 4))
    right_q_center = right_q_start + (right_q_w // 2)

    gap = "   "
    L1, L2, L3 = "SYSTEM: ", "SEALS: ", "AIR: "
    left_len = (
        len(L1) + len(sys_name) + len(gap) +
        len(L2) + len(seal_name) + len(gap) +
        len(L3) + len(air_name)
    )

    left_x = max(
        left_start,
        min(left_start + left_w - left_len, left_center - (left_len // 2))
    )

    x = left_x
    safe_addnstr(stdscr, y, x, L1, None, curses.color_pair(PAIR_LABEL)); x += len(L1)
    safe_addnstr(stdscr, y, x, sys_name, None, curses.color_pair(sys_pair) | curses.A_BOLD); x += len(sys_name)
    safe_addnstr(stdscr, y, x, gap, None, curses.color_pair(PAIR_BODY)); x += len(gap)

    safe_addnstr(stdscr, y, x, L2, None, curses.color_pair(PAIR_LABEL)); x += len(L2)
    safe_addnstr(stdscr, y, x, seal_name, None, curses.color_pair(seal_pair) | curses.A_BOLD); x += len(seal_name)
    safe_addnstr(stdscr, y, x, gap, None, curses.color_pair(PAIR_BODY)); x += len(gap)

    safe_addnstr(stdscr, y, x, L3, None, curses.color_pair(PAIR_LABEL)); x += len(L3)
    safe_addnstr(stdscr, y, x, air_name, None, curses.color_pair(air_pair) | curses.A_BOLD)

    hint_len = len(hints or "")
    hx = max(
        right_q_start,
        min(right_q_start + right_q_w - hint_len, right_q_center - (hint_len // 2))
    )
    safe_addnstr(stdscr, y, hx, hints or "", None, curses.color_pair(PAIR_HINTS) | curses.A_BOLD)


# ----- Dialogs (use injected HUD) -----
def confirm_action(stdscr, action_name: str) -> bool:
    _hud(stdscr, "CONFIRM // OPERATION", hints=DEFAULT_HINTS)
    draw_centered(
        stdscr,
        4,
        wide_kerning(f"Proceed to {action_name}?  (y/n)", 1),
        curses.color_pair(PAIR_RUST) | curses.A_BOLD,
    )
    stdscr.refresh()

    while True:
        key = stdscr.getch()
        if key in (ord('y'), ord('Y')):
            return True
        if key in (ord('n'), ord('N')):
            return False

def success_dialog(stdscr, message: str, *, title: str = "FAULT // OPERATION"):
    curses.curs_set(0)
    _hud(stdscr, title, hints=DEFAULT_HINTS)

    h, w = stdscr.getmaxyx()
    draw_centered(stdscr, max(5, h // 2 - 2), "Success", curses.color_pair(PAIR_OK) | curses.A_BOLD)
    draw_centered(stdscr, max(7, h // 2), (message or "")[: max(0, w - 4)], curses.color_pair(PAIR_BODY))
    draw_centered(stdscr, max(9, h // 2 + 2), "Press any key…", curses.color_pair(PAIR_HINTS) | curses.A_BOLD)
    stdscr.refresh()
    stdscr.getch()

def error_dialog(stdscr, message: str, *, title: str = "FAULT // OPERATION"):
    curses.curs_set(0)
    _hud(stdscr, title, hints=DEFAULT_HINTS)

    h, w = stdscr.getmaxyx()
    draw_centered(stdscr, max(5, h // 2 - 2), "Error", curses.color_pair(PAIR_DANGER) | curses.A_BOLD)
    draw_centered(stdscr, max(7, h // 2), (message or "")[: max(0, w - 4)], curses.color_pair(PAIR_BODY))
    draw_centered(stdscr, max(9, h // 2 + 2), "Press any key…", curses.color_pair(PAIR_HINTS) | curses.A_BOLD)
    stdscr.refresh()
    stdscr.getch()

def confirm_reboot_dialog(stdscr, new_label: str) -> int:
    """
    Two-option dialog for rotation flow.
    Returns: 0 = Reboot now, 1 = Later (ESC also returns 1).
    """
    curses.curs_set(0)
    choices = ["Reboot now", "Later"]
    idx = 0
    while True:
        _hud(stdscr, "DISPLAY // ROTATION", hints=DEFAULT_HINTS)

        msg = f"Rotation set to {new_label}. Reboot now to apply?"
        draw_centered(stdscr, 5, msg, curses.color_pair(PAIR_LABEL) | curses.A_BOLD)

        h, _ = stdscr.getmaxyx()
        top = max(8, h // 2 - len(choices))
        for i, c in enumerate(choices):
            y = top + i * 2
            attr = curses.color_pair(PAIR_HIGHLIGHT) | curses.A_BOLD if i == idx else curses.color_pair(PAIR_BODY)
            draw_centered(stdscr, y, f" {wide_kerning(c, 1)} ", attr)

        stdscr.refresh()

        ch = stdscr.getch()
        if ch in (curses.KEY_UP, ord('k')):
            idx = (idx - 1) % len(choices)
        elif ch in (curses.KEY_DOWN, ord('j')):
            idx = (idx + 1) % len(choices)
        elif ch in (27,):  # ESC
            return 1
        elif ch in (curses.KEY_ENTER, 10, 13):
            return idx


__all__ = [
    # helpers
    "wide_kerning",
    "draw_footer_integrated_mainmenu",
    "get_status",
    "set_status_for_session",
    # dialogs
    "confirm_action",
    "error_dialog",
    "confirm_reboot_dialog",
    # DI hook
    "set_hud_renderer",
]
