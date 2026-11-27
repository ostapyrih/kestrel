"""Builds the system-tray icons from the app icon sources in assets/icon/.

  app/assets/tray/tray.png            colour icon (Linux, Windows fallback)
  app/assets/tray/tray.ico            Windows tray icon (16/24/32/48)
  app/assets/tray/tray_template.png   macOS menu-bar template image: black
                                      silhouette on transparent (the system
                                      tints it for light/dark menu bars)

Requires Pillow. Run from the repo root: python tools/make_tray_icons.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "icon"
OUT = ROOT / "app" / "assets" / "tray"
OUT.mkdir(parents=True, exist_ok=True)

full = Image.open(SRC / "kestrel-1024.png").convert("RGBA")
full.resize((64, 64), Image.LANCZOS).save(OUT / "tray.png")
full.save(OUT / "tray.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48)])

fg = Image.open(SRC / "kestrel-foreground-1024.png").convert("RGBA")
bird = fg.crop(fg.getbbox())
side = max(bird.size)
canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
canvas.paste(bird, ((side - bird.width) // 2, (side - bird.height) // 2))
alpha = canvas.getchannel("A")
mask = Image.new("RGBA", canvas.size, (0, 0, 0, 255))
mask.putalpha(alpha)
mask.resize((44, 44), Image.LANCZOS).save(OUT / "tray_template.png")
