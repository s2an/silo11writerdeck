#!/usr/bin/env python3
# File: layout.py
# Purpose: world-building + layout primitives (DRAW ONLY).
# Notes: PAIR_HAZARD draws the chevron stripe (fg=hazard_fg on bg=banner_bg);
#        PAIR_HEADER draws the banner title text (fg=banner_fg on bg=banner_bg).

from __future__ import annotations
import curses
import random

from .theme import (
    PAIR_HAZARD, PAIR_BORDER, PAIR_RIVET, PAIR_BOLT, PAIR_PATINA, PAIR_STATIC,
    PAIR_HEADER,
    BOLT, RIVET, HAZ_CHARS, PATINA,
    BOLT_STEP, PATINA_DENSITY, STATIC_DENSITY, STATIC_WEIGHTS,
    HEADER_GUARD_ROW,
)

# --- Inner-safe helpers (no-spill text into borders) ---
def inner_width(stdscr, margin: int = 1) -> int:
    """
    Width inside the riveted frame: total width minus left/right margin.
    Use margin=1 if your frame consumes one column on each side.
    """
    _h, w = stdscr.getmaxyx()
    return max(0, w - (margin * 2))

def clip_inner(text: str, stdscr, margin: int = 1) -> str:
    """
    Hard-clip a line to the inner width so it cannot overwrite the frame.
    """
    return (text or "")[: inner_width(stdscr, margin)]

def draw_centered_inner(stdscr, y: int, text: str, attr: int = None, margin: int = 1):
    """
    Center a line after clipping it to the inner width (no spill).
    """
    s = clip_inner(text, stdscr, margin=margin)
    draw_centered(stdscr, y, s, attr)

def safe_addnstr_inner(stdscr, y: int, x: int, text: str, attr: int = None, margin: int = 1):
    """
    Left-aligned draw that caps 'n' to the inner width automatically.
    """
    n = inner_width(stdscr, margin=margin) - max(0, x - margin)
    if n <= 0:
        return
    safe_addnstr(stdscr, y, x, text, n, attr)

def safe_addnstr(stdscr, y: int, x: int, text: str, n: int | None = None, attr: int | None = None) -> None:
    try:
        if y < 0 or x < 0 or not text:
            return
        n2 = len(text) if n is None else max(0, n)
        a = 0 if attr is None else attr  # ← normalize for curses
        stdscr.addnstr(y, x, text, n2, a)
    except Exception:
        pass

# --------- Layout Logic -------------------

def draw_centered(stdscr, y: int, text: str, attr: int = 0) -> None:
    """
    Center *inside the inner frame* (left=1, right=w-2). Prevents writing under borders.
    """
    h, w = stdscr.getmaxyx()
    if h <= 0 or w <= 0 or y < 0 or y >= h:
        return
    inner_w = max(0, w - 2)
    s = (text or "")[:inner_w]
    # left edge of inner box is x=1
    x = 1 + max(0, (inner_w - len(s)) // 2)
    safe_addnstr(stdscr, y, x, s, len(s), attr)

def draw_patina(stdscr, density: float | None = None) -> None:
    if density is None:
        density = PATINA_DENSITY
    h, w = stdscr.getmaxyx()
    samples = int((h * w) * (density * (0.4 if h * w > 15000 else 1.0)))
    y_min = min(HEADER_GUARD_ROW + 1, h - 1)
    y_max = max(y_min, h - 2)
    x_min, x_max = 1, max(1, w - 2)
    for _ in range(samples):
        y = random.randrange(y_min, y_max + 1) if y_max >= y_min else y_min
        x = random.randrange(x_min, x_max + 1) if x_max >= x_min else x_min
        ch = random.choice(PATINA)
        safe_addnstr(stdscr, y, x, ch, 1, curses.color_pair(PAIR_PATINA))

def draw_static(stdscr, density: float | None = None, weights: tuple[float, float, float] | None = None) -> None:
    if density is None:
        density = STATIC_DENSITY
    if weights is None:
        weights = STATIC_WEIGHTS

    h, w = stdscr.getmaxyx()
    count = max(0, int((h * w) * density))

    y_min = min(HEADER_GUARD_ROW + 1, h - 1)
    x_min = 2

    for _ in range(count):
        r = random.random()
        if r < weights[0]:
            sh, sw = 1, 1
        elif r < weights[0] + weights[1]:
            sh, sw = 2, 2
        else:
            sh, sw = 2, 3

        y_max = max(y_min, h - 1 - sh)
        x_max = max(x_min, w - 1 - sw)
        if y_min > y_max or x_min > x_max:
            break

        y = random.randrange(y_min, y_max + 1)
        x = random.randrange(x_min, x_max + 1)

        for dy in range(sh):
            yy = y + dy
            if yy <= HEADER_GUARD_ROW:
                continue
            for dx in range(sw):
                xx = x + dx
                safe_addnstr(stdscr, yy, xx, "▒", 1, curses.color_pair(PAIR_STATIC))

def draw_riveted_frame(stdscr) -> None:
    h, w = stdscr.getmaxyx()
    if h < 3 or w < 8:
        return

    safe_addnstr(stdscr, 0,     0,     "┌", 1, curses.color_pair(PAIR_BORDER))
    safe_addnstr(stdscr, 0,     w - 1, "┐", 1, curses.color_pair(PAIR_BORDER))
    safe_addnstr(stdscr, h - 1, 0,     "└", 1, curses.color_pair(PAIR_BORDER))
    safe_addnstr(stdscr, h - 1, w - 1, "┘", 1, curses.color_pair(PAIR_BORDER))

    if w > 2:
        safe_addnstr(stdscr, 0,     1, "─" * (w - 2), w - 2, curses.color_pair(PAIR_BORDER))
        safe_addnstr(stdscr, h - 1, 1, "─" * (w - 2), w - 2, curses.color_pair(PAIR_BORDER))

    for y in range(1, h - 1):
        safe_addnstr(stdscr, y, 0,     "│", 1, curses.color_pair(PAIR_BORDER))
        safe_addnstr(stdscr, y, w - 1, "│", 1, curses.color_pair(PAIR_BORDER))

    for y in range(2, h - 2, 3):
        safe_addnstr(stdscr, y, 0,     RIVET, 1, curses.color_pair(PAIR_RIVET))
        safe_addnstr(stdscr, y, w - 1, RIVET, 1, curses.color_pair(PAIR_RIVET))

    for x in range(1, w - 1):
        if (x % BOLT_STEP == 1) or x in (1, w - 2):
            safe_addnstr(stdscr, 0, x, BOLT, 1, curses.color_pair(PAIR_BOLT))

def draw_hazard_header(stdscr, title: str) -> None:
    h, w = stdscr.getmaxyx()
    if w < 12:
        return
    inner_w = max(0, w - 2)
    pattern = "".join(HAZ_CHARS[(x // 2) % len(HAZ_CHARS)] for x in range(inner_w))
    safe_addnstr(stdscr, 1, 1, pattern, inner_w, curses.color_pair(PAIR_HAZARD))
    # Clip the title to the inner width so we never overrun the frame on tiny terminals.
    raw = f"[ {title} ]"
    t = raw[:inner_w]
    tx = 1 + max(0, (inner_w - len(t)) // 2)
    safe_addnstr(stdscr, 1, tx, t, len(t),
                 curses.color_pair(PAIR_HEADER))

def draw_bottom_bolt_rail(stdscr) -> None:
    h, w = stdscr.getmaxyx()
    y = h - 1
    if y < 0:
        return
    for x in range(1, w - 1):
        if (x % BOLT_STEP == 1) or x in (1, w - 2):
            safe_addnstr(stdscr, y, x, BOLT, 1, curses.color_pair(PAIR_BOLT))

__all__ = [
    # low-level drawing
    "safe_addnstr", "draw_centered",
    # inner-safe helpers
    "inner_width", "clip_inner", "draw_centered_inner", "safe_addnstr_inner",
    # world-building layers
    "draw_patina", "draw_static", "draw_riveted_frame",
    "draw_hazard_header", "draw_bottom_bolt_rail",
]
