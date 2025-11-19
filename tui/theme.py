#!/usr/bin/env python3
# File: theme.py
# Purpose: centralize all *visual* concerns (palette, pair IDs, env-driven knobs)
# SRP Slices:
#   [CONFIG]  Data-only: color names, presets, env knob names (no curses)
#   [ENGINE]  Resolution: env overrides + names → ints (no curses.init_pair here)
#   [PALETTE] Pair Registry: owns curses pair IDs & init_pair mapping
#   [WIRING]  Composition: one public init_theme()/switch_theme() with persistence

import curses
import os
from pathlib import Path

# ════════════════════════════════════════════════════════════════════════════
# [CONFIG] Data (no curses, no side-effects)
# ════════════════════════════════════════════════════════════════════════════

# Stable color indices (ncurses 8-color baseline)
COLOR_BY_NAME = {
    "black":   getattr(curses, "COLOR_BLACK",   0),
    "red":     getattr(curses, "COLOR_RED",     1),
    "green":   getattr(curses, "COLOR_GREEN",   2),
    "yellow":  getattr(curses, "COLOR_YELLOW",  3),
    "blue":    getattr(curses, "COLOR_BLUE",    4),
    "magenta": getattr(curses, "COLOR_MAGENTA", 5),
    "cyan":    getattr(curses, "COLOR_CYAN",    6),
    "white":   getattr(curses, "COLOR_WHITE",   7),
}

# Logical slots (semantics)
# - Banner (big stripe): banner_bg, banner_fg  (title text on the stripe)
# - Hazard edges (chevrons): hazard_fg (on banner_bg)
# - Headers elsewhere: header_fg  (NOT the banner)
# - Body/selection: body_fg, highlight_fg, highlight_bg
# - Frame/accents/noise: border_fg, bolt_fg, rust_fg, rivet_fg (= rust_fg), static_fg, patina_fg
# - Footer/status: label_fg, ok_fg, warn_fg, danger_fg, hint_fg

THEME_PRESETS = {
    # Day — bright & friendly
    "day": {
        # Banner & hazard
        "banner_bg": "yellow",
        "banner_fg": "black",   # title text on the banner
        "hazard_fg": "black",   # chevrons/edges
        # Frame/accents
        "border_fg": "white",
        "rust_fg":   "yellow",
        "bolt_fg":   "yellow",
        # Noise
        "static_fg": "yellow",
        "patina_fg": "yellow",
        # Headers elsewhere & body
        "header_fg": "white",
        "body_fg":   "white",
        # Selection
        "highlight_fg": "black",
        "highlight_bg": "yellow",
        # Footer/status
        "label_fg":  "blue",
        "ok_fg":     "green",
        "warn_fg":   "magenta",
        "danger_fg": "red",
        "hint_fg":   "cyan",
    },

    # Night — cool neon vibe
    "night": {
        # Banner & hazard
        "banner_bg": "magenta",
        "banner_fg": "black",
        "hazard_fg": "black",
        # Frame/accents
        "border_fg": "blue",
        "rust_fg":   "magenta",
        "bolt_fg":   "magenta",
        # Noise
        "static_fg": "blue",
        "patina_fg": "blue",
        # Headers elsewhere & body
        "header_fg": "blue",
        "body_fg":   "blue",
        # Selection
        "highlight_fg": "black",
        "highlight_bg": "cyan",
        # Footer/status
        "label_fg":  "cyan",
        "ok_fg":     "green",
        "warn_fg":   "magenta",
        "danger_fg": "red",
        "hint_fg":   "cyan",
    },

    # Toxic — loud hazard palette
    "toxic": {
        # Banner & hazard
        "banner_bg": "red",
        "banner_fg": "yellow",
        "hazard_fg": "yellow",
        # Frame/accents
        "border_fg": "magenta",
        "rust_fg":   "green",
        "bolt_fg":   "green",
        # Noise
        "static_fg": "green",
        "patina_fg": "green",
        # Headers elsewhere & body
        "header_fg": "green",
        "body_fg":   "green",
        # Selection
        "highlight_fg": "yellow",
        "highlight_bg": "red",
        # Footer/status
        "label_fg":  "cyan",
        "ok_fg":     "green",
        "warn_fg":   "yellow",
        "danger_fg": "red",
        "hint_fg":   "cyan",
    },
}

# Glyphs / patterns (stable names)
BOLT   = "•"
RIVET  = "⟆"
SLASH  = "/"
BSLASH = "\\"
HAZ_CHARS = [SLASH, BSLASH, "|", SLASH + BSLASH, BSLASH + SLASH]
PATINA = ["·", "·", "·", "·", "·", " ", " ", " "]

# Env-driven knobs (visual noise intensities)
def _int_env(name: str, default: int) -> int:
    try:
        v = os.environ.get(name, "")
        return int(v.strip()) if v else default
    except Exception:
        return default

def _float_env(name: str, default: float) -> float:
    try:
        v = os.environ.get(name, "")
        return float(v.strip()) if v else default
    except Exception:
        return default

def _tuple_env(name: str, default_csv: str):
    raw = os.environ.get(name, "")
    src = raw.strip() if raw else default_csv
    try:
        return tuple(float(x) for x in src.split(","))
    except Exception:
        return tuple(float(x) for x in default_csv.split(","))

BOLT_STEP        = _int_env("WD_BOLT_STEP", 6)
PATINA_DENSITY   = _float_env("WD_PATINA_DENSITY", 0.08)
STATIC_DENSITY   = _float_env("WD_STATIC_DENSITY", 0.004)
STATIC_WEIGHTS   = _tuple_env("WD_STATIC_WEIGHTS", "0.70,0.24,0.06")

TOP_BORDER_ROW   = 0
HAZARD_ROW       = 1
HEADER_GUARD_ROW = 1

# XDG-config for persisted theme selection (env still wins)
APP_NAME = "silo11writerdeck"
XDG_CONFIG_HOME = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
CFG_DIR = XDG_CONFIG_HOME / APP_NAME
THEME_FILE = CFG_DIR / "theme"

# ════════════════════════════════════════════════════════════════════════════
# [ENGINE] Resolution (env overrides + names → ints)  — no curses pairs here
# ════════════════════════════════════════════════════════════════════════════

def _color_from_env(name: str, default_idx: int) -> int:
    val = os.environ.get(name, "").strip().lower()
    if not val:
        return default_idx
    return COLOR_BY_NAME.get(val, default_idx)

def _read_persisted_theme() -> str | None:
    try:
        if THEME_FILE.exists():
            name = THEME_FILE.read_text(encoding="utf-8").strip().lower()
            return name or None
    except Exception:
        pass
    return None

def _resolve_theme_name() -> str:
    # 1) explicit env overrides persisted choice
    env_name = (os.environ.get("WD_THEME", "") or "").strip().lower()
    if env_name and env_name in THEME_PRESETS:
        return env_name
    # 2) persisted file (if present/valid)
    persisted = _read_persisted_theme()
    if persisted and persisted in THEME_PRESETS:
        return persisted
    # 3) default
    return "night"

_CURRENT_THEME = _resolve_theme_name()

def available_themes():
    return sorted(THEME_PRESETS.keys())

def get_theme() -> str:
    return _CURRENT_THEME

def set_theme(name: str) -> None:
    """Set current theme name (if valid) and persist to XDG config."""
    global _CURRENT_THEME
    name = (name or "").strip().lower()
    if name in THEME_PRESETS:
        _CURRENT_THEME = name
        # Persist quietly; ignore filesystem errors
        try:
            CFG_DIR.mkdir(parents=True, exist_ok=True)
            THEME_FILE.write_text(name + "\n", encoding="utf-8")
        except Exception:
            pass

def _resolve_palette_from_preset() -> dict:
    """Return a dict of numeric colors for the active theme, with env overrides applied."""
    preset = THEME_PRESETS[_CURRENT_THEME]

    # Start with preset → numeric
    C = {k: COLOR_BY_NAME.get(v, COLOR_BY_NAME["white"]) for k, v in preset.items()}

    # Derived defaults
    C.setdefault("rivet_fg", C.get("rust_fg", COLOR_BY_NAME["yellow"]))

    # Env overrides (new names)
    C["banner_fg"]  = _color_from_env("WD_BANNER_FG",  C["banner_fg"])
    C["banner_bg"]  = _color_from_env("WD_BANNER_BG",  C["banner_bg"])
    C["hazard_fg"]  = _color_from_env("WD_HAZARD_FG",  C["hazard_fg"])

    C["border_fg"]  = _color_from_env("WD_BORDER_FG",  C["border_fg"])
    C["rust_fg"]    = _color_from_env("WD_RUST_FG",    C["rust_fg"])
    C["rivet_fg"]   = _color_from_env("WD_RIVET_FG",   C["rivet_fg"])  # legacy-friendly

    C["static_fg"]  = _color_from_env("WD_STATIC_FG",  C["static_fg"])
    C["patina_fg"]  = _color_from_env("WD_PATINA_FG",  C["patina_fg"])

    C["header_fg"]  = _color_from_env("WD_HEADER_FG",  C["header_fg"])
    C["body_fg"]    = _color_from_env("WD_BODY_FG",    C["body_fg"])

    C["highlight_fg"] = _color_from_env("WD_HIGHLIGHT_FG", C["highlight_fg"])
    C["highlight_bg"] = _color_from_env("WD_HIGHLIGHT_BG", C["highlight_bg"])

    C["label_fg"]   = _color_from_env("WD_LABEL_FG",   C["label_fg"])
    C["ok_fg"]      = _color_from_env("WD_OK_FG",      C["ok_fg"])
    C["warn_fg"]    = _color_from_env("WD_WARN_FG",    C["warn_fg"])
    C["danger_fg"]  = _color_from_env("WD_DANGER_FG",  C["danger_fg"])
    C["hint_fg"]    = _color_from_env("WD_HINT_FG",    C["hint_fg"])

    # Legacy aliases (compat): WD_HAZARD_BG used to mean the banner background
    legacy_banner_bg = os.environ.get("WD_HAZARD_BG", "").strip().lower()
    if legacy_banner_bg:
        C["banner_bg"] = COLOR_BY_NAME.get(legacy_banner_bg, C["banner_bg"])

    return C

# ════════════════════════════════════════════════════════════════════════════
# [PALETTE] Curses Pair Registry (pair IDs + init table)
# ════════════════════════════════════════════════════════════════════════════

# Stable pair IDs
PAIR_HIGHLIGHT = 1
PAIR_RUST      = 2
PAIR_HAZARD    = 3     # chevrons/edges (fg=hazard_fg on bg=banner_bg)
PAIR_BODY      = 4
PAIR_DANGER    = 6
PAIR_OK        = 7
PAIR_WARN      = 8
PAIR_LABEL     = 9
PAIR_HINTS     = 10
PAIR_PATINA    = 11
PAIR_BORDER    = 12
PAIR_BOLT      = 13
PAIR_RIVET     = 14
PAIR_STATIC    = 15
PAIR_HEADER    = 16    # banner title text (fg=banner_fg on bg=banner_bg)

def _init_pair(pid: int, fg: int, bg: int = -1):
    curses.init_pair(pid, fg, bg)

def _register_pairs(C: dict):
    """
    C: numeric palette
    Registers all pairs.
    """
    # Order doesn’t matter for curses, but keep it readable
    _init_pair(PAIR_HIGHLIGHT, C["highlight_fg"], C["highlight_bg"])
    _init_pair(PAIR_RUST,      C["rust_fg"],      -1)
    _init_pair(PAIR_HAZARD,    C["hazard_fg"],    C["banner_bg"])
    _init_pair(PAIR_BODY,      C["body_fg"],      -1)
    _init_pair(PAIR_STATIC,    C["static_fg"],    -1)
    _init_pair(PAIR_DANGER,    C["danger_fg"],    COLOR_BY_NAME["black"])
    _init_pair(PAIR_OK,        C["ok_fg"],        -1)
    _init_pair(PAIR_WARN,      C["warn_fg"],      -1)
    _init_pair(PAIR_LABEL,     C["label_fg"],     -1)
    _init_pair(PAIR_HINTS,     C["hint_fg"],      -1)
    _init_pair(PAIR_PATINA,    C["patina_fg"],    -1)
    _init_pair(PAIR_BORDER,    C["border_fg"],    -1)
    _init_pair(PAIR_BOLT,      C["bolt_fg"],      -1)
    _init_pair(PAIR_RIVET,     C["rivet_fg"],     -1)

    # Banner title text on banner background
    _init_pair(PAIR_HEADER,    C["banner_fg"],    C["banner_bg"])

# ════════════════════════════════════════════════════════════════════════════
# [WIRING] Composition (single public entry point)
# ════════════════════════════════════════════════════════════════════════════

def init_theme(theme_name: str | None = None) -> dict:
    """
    Public: initialize curses colors for the selected theme.
    Returns a light context dict: {"name": <theme>, "palette": <numeric palette>}
    NOTE: Must be called after curses is initialized (inside curses.wrapper(...) or equivalent).
    """
    if theme_name:
        set_theme(theme_name)

    curses.start_color()
    try:
        curses.use_default_colors()
    except Exception:
        pass

    numeric_palette = _resolve_palette_from_preset()
    _register_pairs(numeric_palette)

    return {"name": get_theme(), "palette": numeric_palette}
