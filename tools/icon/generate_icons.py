#!/usr/bin/env python3
"""Draws the Kilonova app icon and writes the Android, Linux and Windows sizes.

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


def draw_foreground(size: int) -> Image.Image:
    """The mark alone, scaled into the adaptive icon's safe zone (the
    central 66%), on a transparent canvas; Android adds the background."""
    s = size * SUPERSAMPLE
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = s / 2
    r = s * 0.27 * 0.66
    w = round(s * 0.045 * 0.66)
    box = (c - r, c - r, c + r, c + r)
    d.ellipse(box, outline=TRACK, width=w)
    d.arc(box, start=-90, end=180, fill=GOLD, width=w)
    dot = s * 0.05 * 0.66
    d.ellipse((c - r - dot, c - dot, c - r + dot, c + dot), fill=GOLD)
    core = s * 0.075 * 0.66
    d.ellipse((c - core, c - core, c + core, c + core), fill=GOLD)
    return img.resize((size, size), Image.LANCZOS)


def draw_monochrome(size: int) -> Image.Image:
    """Themed-icon layer: the mark in white alpha, same geometry."""
    fg = draw_foreground(size)
    alpha = fg.getchannel("A")
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def main() -> None:
    app = Path("app")
    master = draw(MASTER)
    master.save("tools/icon/kilonova-icon-1024.png")

    android = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, px in android.items():
        out = app / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png"
        draw(px).convert("RGB").save(out)

    # Adaptive icon layers (Android 8+), legacy PNGs stay for older devices.
    for density, px in {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}.items():
        out = app / f"android/app/src/main/res/mipmap-{density}"
        draw_foreground(px).save(out / "ic_launcher_foreground.png")
        draw_monochrome(px).save(out / "ic_launcher_monochrome.png")

    # The window icon the Linux runner loads at startup, and the About screen.
    icon_asset = app / "assets/icon"
    icon_asset.mkdir(parents=True, exist_ok=True)
    draw(256).save(icon_asset / "kilonova-256.png")

    linux = Path("packaging/linux/icons")
    for px in (64, 128, 256, 512):
        out = linux / f"{px}x{px}" / "com.dhivalabs.kilonova.png"
        out.parent.mkdir(parents=True, exist_ok=True)
        draw(px).save(out)

    master.save(
        app / "windows/runner/resources/app_icon.ico",
        sizes=[(n, n) for n in (16, 24, 32, 48, 64, 128, 256)],
    )


if __name__ == "__main__":
    main()
