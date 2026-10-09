#!/usr/bin/env python3
"""Stitch rendered views (build/preview/<cat>/<vehicle>/<part>/view*_color.png) into one contact sheet
with optional OpenGFX reference sprites for scale comparison.

    BPY=/opt/bpyvenv/bin/python
    $BPY tools/render.py models/aircraft/b737_800.py --samples 8 --views 1 2 5 --out build/preview
    python3 tools/preview.py build/preview/aircraft/b737_800 -o build/preview/b737_800.png
"""
import argparse
from pathlib import Path

from PIL import Image


def crop_alpha(im):
    bbox = im.getchannel("A").getbbox()
    return im.crop(bbox) if bbox else im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="+", help="vehicle render dirs (containing part subdirs)")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--bg", default="88,120,72")
    ap.add_argument("--scale", type=float, default=1.0)
    args = ap.parse_args()
    bg = tuple(int(c) for c in args.bg.split(",")) + (255,)
    rows = []
    for d in args.dirs:
        for part in sorted(p for p in Path(d).iterdir() if p.is_dir()):
            ims = [crop_alpha(Image.open(f).convert("RGBA")) for f in sorted(part.glob("view*_color.png"))]
            if ims:
                rows.append(ims)
    pad = 12
    W = max(sum(i.size[0] + pad for i in r) for r in rows) + pad
    H = sum(max(i.size[1] for i in r) + pad for r in rows) + pad
    sheet = Image.new("RGBA", (W, H), bg)
    y = pad
    for r in rows:
        x = pad
        rh = max(i.size[1] for i in r)
        for im in r:
            sheet.alpha_composite(im, (x, y + (rh - im.size[1]) // 2))
            x += im.size[0] + pad
        y += rh + pad
    if args.scale != 1.0:
        sheet = sheet.resize((int(W * args.scale), int(H * args.scale)), Image.LANCZOS)
    sheet.save(args.out)
    print(args.out, sheet.size)


if __name__ == "__main__":
    main()
