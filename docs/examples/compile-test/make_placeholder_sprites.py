#!/usr/bin/env python3
"""Generate placeholder sprite sheets for the compile test.

Produces, for each vehicle, a 9-sprite sheet (8 directional views + 1 purchase sprite):
  gfx/<name>_1x.png        8bpp, OpenTTD DOS palette (mandatory 1x fallback)
  gfx/<name>_1x32.png      32bpp RGBA at 1x        + <name>_1x32_mask.png (company-colour mask)
  gfx/<name>_2x.png        32bpp RGBA at 2x        + <name>_2x_mask.png
  gfx/<name>_4x.png        32bpp RGBA at 4x        + <name>_4x_mask.png
The artwork is a flat box; only the file layout and palettes matter here.
"""
from pathlib import Path

from PIL import Image, ImageDraw
from nml import palette  # nml ships the OpenTTD palettes

PAL = list(palette.palette_data[0])  # DEFAULT (DOS) palette, 768 bytes
CC = 0xC9                            # one of the 1CC indices (0xC6..0xCD)
OUT = Path(__file__).resolve().parent / "gfx"
VEHICLES = ["concorde", "b737", "b737_800", "n700", "l0"]
SHEET = 9                            # 8 views + purchase sprite


def sheet_8bpp(path, w, h):
    img = Image.new("P", (SHEET * w, h), 0)
    img.putpalette(PAL)
    d = ImageDraw.Draw(img)
    for i in range(SHEET):
        d.rectangle([i * w + 4, 8, i * w + w - 5, h - 9], fill=0x0F)
        d.rectangle([i * w + w // 3, h // 3, i * w + 2 * w // 3, 2 * h // 3], fill=CC)
    img.save(path)


def sheet_32bpp(path, mask_path, w, h):
    img = Image.new("RGBA", (SHEET * w, h), (0, 0, 0, 0))
    msk = Image.new("P", (SHEET * w, h), 0)
    msk.putpalette(PAL)
    d, dm = ImageDraw.Draw(img), ImageDraw.Draw(msk)
    for i in range(SHEET):
        d.rectangle([i * w + 4, 8, i * w + w - 5, h - 9], fill=(220, 220, 230, 255))
        box = [i * w + w // 3, h // 3, i * w + 2 * w // 3, 2 * h // 3]
        d.rectangle(box, fill=(128, 128, 128, 255))  # grey area is recoloured by the mask
        dm.rectangle(box, fill=CC)
    img.save(path)
    msk.save(mask_path)


def main():
    OUT.mkdir(exist_ok=True)
    for name in VEHICLES:
        sheet_8bpp(OUT / f"{name}_1x.png", 64, 48)
        sheet_32bpp(OUT / f"{name}_4x.png", OUT / f"{name}_4x_mask.png", 256, 192)
    # Extra zoom levels are only wired up for the Concorde in the test.
    sheet_32bpp(OUT / "concorde_1x32.png", OUT / "concorde_1x32_mask.png", 64, 48)
    sheet_32bpp(OUT / "concorde_2x.png", OUT / "concorde_2x_mask.png", 128, 96)
    print(f"placeholder sprites written to {OUT}")


if __name__ == "__main__":
    main()
