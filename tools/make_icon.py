#!/usr/bin/env python3
"""Generate the Kestrel app icon (flat falcon silhouette on teal).

Writes assets/icon/kestrel.svg and kestrel-{1024,512}.png plus
kestrel-foreground-1024.png (transparent, for Android adaptive icons).
Requires Pillow: pip install pillow
"""
from pathlib import Path

from PIL import Image, ImageDraw

BG = "#0F766E"
FG = "#F8FAFC"
ACCENT = "#99F6E4"

# Right half of a falcon seen from above, in a 1024 box, head to tail.
RIGHT = [
    (512, 210), (540, 250), (556, 320), (640, 372), (800, 456),
    (930, 560), (968, 640), (760, 586), (640, 566), (578, 640),
    (572, 760), (548, 800), (512, 870),
]
# Mirror it (head and tail lie on the axis and are not repeated).
POLY = RIGHT + [(1024 - x, y) for x, y in reversed(RIGHT[1:-1])]
STRIPE = [(512, 330), (534, 560), (512, 700), (490, 560)]


def scaled(points, s, c=512):
    return [(c + (x - c) * s, c + (y - c) * s) for x, y in points]


def render(size, fg_scale=1.0, background=True):
    ss = 4
    n = size * ss
    img = Image.new("RGBA", (n, n), BG if background else (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = n / 1024
    d.polygon([(x * k, y * k) for x, y in scaled(POLY, fg_scale)], fill=FG)
    d.polygon([(x * k, y * k) for x, y in scaled(STRIPE, fg_scale)], fill=ACCENT)
    return img.resize((size, size), Image.LANCZOS)


def svg():
    pts = " ".join(f"{x},{y}" for x, y in POLY)
    stripe = " ".join(f"{x},{y}" for x, y in STRIPE)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">'
        f'<rect width="1024" height="1024" fill="{BG}"/>'
        f'<polygon points="{pts}" fill="{FG}"/>'
        f'<polygon points="{stripe}" fill="{ACCENT}"/></svg>\n'
    )


def main():
    out = Path(__file__).resolve().parent.parent / "assets" / "icon"
    out.mkdir(parents=True, exist_ok=True)
    (out / "kestrel.svg").write_text(svg(), encoding="utf-8")
    render(1024).convert("RGB").save(out / "kestrel-1024.png", optimize=True)
    render(512).convert("RGB").save(out / "kestrel-512.png", optimize=True)
    render(1024, 0.62, background=False).save(
        out / "kestrel-foreground-1024.png", optimize=True
    )


if __name__ == "__main__":
    main()
