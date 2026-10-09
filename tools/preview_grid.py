#!/usr/bin/env python3
"""Grid contact sheet of preview renders: one cell per vehicle (its first part, chosen views side by side),
labelled with the vehicle id. Usage: python3 tools/preview_grid.py -o out.png --cols 4 DIR [DIR ...]"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw


def crop_alpha(im):
    bbox = im.getchannel("A").getbbox()
    return im.crop(bbox) if bbox else im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--part", default=None)
    args = ap.parse_args()
    cells = []
    for d in args.dirs:
        d = Path(d)
        parts = sorted(p for p in d.iterdir() if p.is_dir())
        part = next((p for p in parts if p.name == args.part), parts[0])
        ims = [crop_alpha(Image.open(f).convert("RGBA")) for f in sorted(part.glob("view*_color.png"))]
        w = sum(i.size[0] for i in ims) + 8 * (len(ims) - 1)
        h = max(i.size[1] for i in ims)
        cell = Image.new("RGBA", (w, h + 16), (0, 0, 0, 0))
        x = 0
        for im in ims:
            cell.alpha_composite(im, (x, 16 + (h - im.size[1]) // 2))
            x += im.size[0] + 8
        ImageDraw.Draw(cell).text((2, 0), d.name, fill=(255, 255, 255, 255))
        cells.append(cell)
    cw = max(c.size[0] for c in cells) + 12
    ch = max(c.size[1] for c in cells) + 12
    rows = (len(cells) + args.cols - 1) // args.cols
    sheet = Image.new("RGBA", (cw * args.cols, ch * rows), (88, 120, 72, 255))
    for k, c in enumerate(cells):
        sheet.alpha_composite(c, ((k % args.cols) * cw + 6, (k // args.cols) * ch + 6))
    sheet.convert("RGB").save(args.out)
    print(args.out, sheet.size)


if __name__ == "__main__":
    main()
