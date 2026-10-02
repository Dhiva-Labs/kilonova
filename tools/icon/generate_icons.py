#!/usr/bin/env python3
"""Draws the Kilonova app icon and writes the Android and Windows sizes.

The 1024px master is kept for store listings and Linux packaging.

The mark is the sync orbit from docs/DESIGN.md: a gold arc on a dim track
around a gold core, on the deep-space background. Run from the repo root:

    python3 tools/icon/generate_icons.py

Needs Pillow. Output files are committed, so only run this when the mark
changes.
"""
from pathlib import Path

from PIL import Image, ImageDraw

BG = "#0B0F17"
TRACK = "#1F2633"
GOLD = "#E8B931"
MASTER = 1024
SUPERSAMPLE = 4


def draw(size: int) -> Image.Image:
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), BG)
    d = ImageDraw.Draw(img)
    c = s / 2
    r = s * 0.27
    w = round(s * 0.045)
    box = (c - r, c - r, c + r, c + r)
    d.ellipse(box, outline=TRACK, width=w)
    # Arc from 12 o'clock, clockwise, three quarters of the way round.
    d.arc(box, start=-90, end=180, fill=GOLD, width=w)
    dot = s * 0.05
    # The dot rides the end of the arc, at 9 o'clock.
    d.ellipse((c - r - dot, c - dot, c - r + dot, c + dot), fill=GOLD)
    core = s * 0.075
    d.ellipse((c - core, c - core, c + core, c + core), fill=GOLD)
    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    app = Path("app")
    master = draw(MASTER)
    master.save("tools/icon/kilonova-icon-1024.png")

    android = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, px in android.items():
        out = app / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png"
        draw(px).convert("RGB").save(out)

    master.save(
        app / "windows/runner/resources/app_icon.ico",
        sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)],
    )


if __name__ == "__main__":
    main()
