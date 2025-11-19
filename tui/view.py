#!/usr/bin/env python3
# File: tui/view.py
# Responsibilities:
#   - Compose/draw the screen-level HUD (patina, static, frame, banner, rail, footer)
#   - Provide selection loop screens that respect the inner frame (no border spill)
# Notes:
#   - Pure rendering: uses pair IDs from theme; does not compute colors.

from __future__ import annotations

import curses

from .theme import (
    init_theme,  # wiring
    PAIR_HIGHLIGHT, PAIR_BODY,
)
from .layout import (
    draw_patina, draw_static, draw_riveted_frame,
    draw_hazard_header, draw_bottom_bolt_rail,
    draw_centered,
)
from .widgets import (
    wide_kerning,
    draw_footer_integrated_mainmenu,
    set_hud_renderer,  # register this module as the HUD provider
)

DEFAULT_HINTS = " Navigation = ↑ ↓  Select = Enter "

# Theme init happens lazily after curses is ready.
_THEME_READY = False

# ----- HUD (single source of truth) -----
def draw_silo_hud(stdscr, title: str, hints: str = DEFAULT_HINTS):
    """
    HUD = patina → static → frame → header/banner → bottom bolt rail → integrated footer.
    """
    global _THEME_READY
    if not _THEME_READY:
        # Now curses has been initialized by curses.wrapper(...), it's safe to init colors.
        init_theme()
        _THEME_READY = True

    title = wide_kerning(title)
    stdscr.clear()
    draw_patina(stdscr)
    draw_static(stdscr)
    draw_riveted_frame(stdscr)
    draw_hazard_header(stdscr, title)          # uses PAIR_HAZARD (edges) + PAIR_HEADER (banner text)
    draw_bottom_bolt_rail(stdscr)
    draw_footer_integrated_mainmenu(stdscr, hints=hints)


# Register HUD so widgets can call back without importing view (avoids circular imports).
set_hud_renderer(draw_silo_hud)


# ----- Inner-frame safety helpers -----
def _inner_width(w: int, margin: int = 1) -> int:
    # Assume the riveted frame/padding eats 1 char on each side by default.
    return max(0, w - (margin * 2))

def _truncate_for_inner(text: str, w: int, margin: int = 1) -> str:
    inner_w = _inner_width(w, margin=margin)
    if inner_w <= 0:
        return ""
    return (text or "")[:inner_w]


# ----- Select screen -----
def select_loop(
    stdscr,
    title: str,
    labels: list[str],
    icons: list[str] | None = None,
    current: int = 0,
    hints: str = DEFAULT_HINTS
) -> int:
    """Generic ↑/↓ list selector with silo HUD. Returns chosen index. Esc is ignored."""
    curses.curs_set(0)
    if not labels:
        return 0
    if icons is None:
        icons = ["■"] * len(labels)

    while True:
        draw_silo_hud(stdscr, title, hints=hints)

        h, w = stdscr.getmaxyx()
        top = max(3, (h // 2) - len(labels))

        for i, label in enumerate(labels):
            y = top + i * 2
            icon = icons[i] if i < len(icons) else "■"
            pretty_raw = f" {icon}  {wide_kerning(label, 1)} "
            pretty = _truncate_for_inner(pretty_raw, w, margin=1)
            attr = (
                curses.color_pair(PAIR_HIGHLIGHT) | curses.A_BOLD
                if i == current else curses.color_pair(PAIR_BODY)
            )
            draw_centered(stdscr, y, pretty, attr)

        stdscr.refresh()
        ch = stdscr.getch()
        if ch in (curses.KEY_UP, ord('k')):
            current = (current - 1) % len(labels)
        elif ch in (curses.KEY_DOWN, ord('j')):
            current = (current + 1) % len(labels)
        elif ch in (curses.KEY_ENTER, 10, 13):
            return current
        else:
            # Esc and others are ignored by design
            pass
