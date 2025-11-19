"""
tui package: Rusted-silo themed text UI system.

Modules:
- menu: main curses-driven menu loop
- actions: system side-effects (WordGrinder, Wi-Fi, rotation, etc.)
- layout: drawing primitives (patina, riveted frame, hazard bar, etc.)
- theme: color pairs, glyphs, environment-driven style knobs
- widgets: reusable UI composites (status footer, dialogs, confirm prompts)
"""

__all__ = [
    "menu",
    "actions",
    "layout",
    "theme",
    "widgets",
]
