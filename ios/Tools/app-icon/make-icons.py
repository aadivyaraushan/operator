#!/usr/bin/env python3
"""Draws the app icon from the brand kit's numbers (operator-icon.svg).

On a 1000 grid: near-black tile, vermilion disc at (585, 415) radius 258,
rust disc at (292, 708) radius 108 with a fine vermilion edge (3 wide).
Small sizes leave the edge out, as operator-icon-small.svg does. The tile is
square: iOS rounds the corners itself.

Run: python3 ios/Tools/app-icon/make-icons.py
"""
from pathlib import Path
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parents[2] / "OperatorApp/Assets.xcassets/AppIcon.appiconset"
SIZES = {"20@2x": 40, "20@3x": 60, "29@2x": 58, "29@3x": 87, "40@2x": 80, "40@3x": 120, "60@2x": 120, "60@3x": 180, "": 1024}
EDGE_FROM = 120  # pixels; below this the edge is thinner than a pixel


def draw(pixels: int) -> Image.Image:
    over = 4
    s = pixels * over / 1000
    image = Image.new("RGB", (pixels * over, pixels * over), "#0B0B0B")
    pen = ImageDraw.Draw(image)

    def disc(cx, cy, r, fill):
        pen.ellipse([(cx - r) * s, (cy - r) * s, (cx + r) * s, (cy + r) * s], fill=fill)

    if pixels >= EDGE_FROM:
        disc(292, 708, 109.5, "#FF5934")
        disc(292, 708, 106.5, "#9E3924")
    else:
        disc(292, 708, 108, "#9E3924")
    disc(585, 415, 258, "#FF5934")
    return image.resize((pixels, pixels), Image.LANCZOS)


for name, pixels in SIZES.items():
    file = OUT / (f"Operator-AppIcon-{name}.png" if name else "Operator-AppIcon.png")
    draw(pixels).save(file)
    print(file.name, pixels)
