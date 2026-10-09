#!/usr/bin/env python3
"""Labelled gallery of every vehicle with artwork, cut from the final sprite sheets.

    python3 tools/gallery.py aircraft -o docs/qa/gallery_aircraft.png --zoom 2x --view 5
    python3 tools/gallery.py trains   -o docs/qa/gallery_trains.png   --zoom 4x --view 5

Rows follow data/<category>.csv order; one cell per art directory (variants sharing art appear once).
Trains show head + two intermediate cars + tail, coupled as in game, in the chosen view.
"""
import argparse
import csv
import json
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
CSV = {"aircraft": "aircraft.csv", "trains": "trains.csv"}
TAIL = [4, 5, 6, 7, 0, 1, 2, 3]


def view_image(gfx: Path, part: dict, zoom: str, view: int):
    z = part["zooms"][zoom]
    x, y, w, h, dx, dy = z["views"][view]
    return Image.open(gfx / z["sheet"]).convert("RGBA").crop((x, y, x + w, y + h)), dx, dy


def compose(items):
    """items: [(image, dx, dy, ox, oy)] placed relative to a common origin."""
    l = min(dx + ox for _, dx, _, ox, _ in items)
    t = min(dy + oy for _, _, dy, _, oy in items)
    r = max(dx + ox + im.size[0] for im, dx, _, ox, _ in items)
    b = max(dy + oy + im.size[1] for im, _, dy, _, oy in items)
    canvas = Image.new("RGBA", (r - l, b - t), (0, 0, 0, 0))
    for im, dx, dy, ox, oy in items:
        canvas.alpha_composite(im, (dx + ox - l, dy + oy - t))
    return canvas


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("category", choices=CSV)
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--zoom", default="2x")
    ap.add_argument("--view", type=int, default=5)
    ap.add_argument("--cols", type=int, default=6)
    args = ap.parse_args()
    rows = list(csv.DictReader(open(ROOT / "data" / CSV[args.category], encoding="utf-8")))
    seen, cells = set(), []
    scale = {"1x": 1, "2x": 2, "4x": 4}[args.zoom]
    for r in rows:
        art = r.get("art")
        gfx = ROOT / "gfx" / args.category / art
        if not art or art in seen or not (gfx / "manifest.json").exists():
            continue
        seen.add(art)
        m = json.loads((gfx / "manifest.json").read_text())
        if args.category == "trains":
            parts = m["parts"]
            # Consecutive cars are spaced by the car length along the track; in the NE/SW views that is
            # 16 px per 8 units at 1x horizontally and 8 px vertically (diagonal track: 32 px horizontally).
            units = parts["head"].get("units") or 8
            step = {0: (0, -16), 1: (16, -8), 2: (32, 0), 3: (16, 8), 4: (0, 16), 5: (-16, 8), 6: (-32, 0), 7: (-16, -8)}[args.view]
            sx, sy = (step[0] * units // 8) * scale, (step[1] * units // 8) * scale
            mid = parts.get("mid_p", parts["mid"])
            seq = [view_image(gfx, parts["head"], args.zoom, args.view), view_image(gfx, parts["mid"], args.zoom, args.view),
                   view_image(gfx, mid, args.zoom, args.view), view_image(gfx, parts["head"], args.zoom, TAIL[args.view])]
            # Draw back to front so nearer cars overlap correctly (cars further "down" the screen are nearer).
            items = [(im, dx, dy, -k * sx, -k * sy) for k, (im, dx, dy) in enumerate(seq)]
            items.sort(key=lambda it: it[4])
            img = compose(items)
        else:
            part = m["parts"].get("body") or next(iter(m["parts"].values()))
            img, _, _ = view_image(gfx, part, args.zoom, args.view)
        label = r["name_en"].split(" (")[0]
        tw = int(ImageDraw.Draw(img).textlength(label)) + 2
        cell = Image.new("RGBA", (max(img.size[0], tw), img.size[1] + 16), (0, 0, 0, 0))
        cell.alpha_composite(img, (0, 16))
        ImageDraw.Draw(cell).text((0, 0), label, fill=(255, 255, 255, 255))
        cells.append(cell)
    cw = max(c.size[0] for c in cells) + 16
    ch = max(c.size[1] for c in cells) + 16
    nrows = (len(cells) + args.cols - 1) // args.cols
    sheet = Image.new("RGB", (cw * args.cols, ch * nrows), (88, 120, 72))
    for k, c in enumerate(cells):
        sheet.paste(c, ((k % args.cols) * cw + 8, (k // args.cols) * ch + 8), c)
    sheet.save(args.out, optimize=True)
    print(args.out, sheet.size, len(cells), "vehicles")


if __name__ == "__main__":
    main()
