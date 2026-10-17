#!/usr/bin/env python3
"""Top-down picture of what MaxTransit2 built, from the last map dump in an OpenTTD log
(AI setting dump_map=1, see ai/MaxTransit2/lib/dump.nut). The null video driver used by run_ai.py cannot
take screenshots, so the AI writes the map into its log and this script draws it.

    python3 tools/ai/run_ai.py --ai MaxTransit2 --years 10 --ai-settings "dump_map=1" --out build/ai2-test
    python3 tools/ai/render_map.py build/ai2-test/openttd.log -o build/ai2-map.png --scale 4
    python3 tools/ai/render_map.py build/ai2-test/openttd.log -o crop.png --scale 8 --crop 100,40,180,120

Colours: land by height (greens to browns), water blue, houses grey, industries purple, other roads light
grey; our track black (each piece drawn as a line), our bridges and tunnels dark red, our roads dark grey,
our stations and depots red, signals yellow dots; other companies' stations orange with a ring and their
track orange.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# OpenTTD track bits (ScriptRail::RailTrack): which tile edges each piece joins.
TRACKS = {1: ("NE", "SW"), 2: ("NW", "SE"), 4: ("NW", "NE"), 8: ("SW", "SE"), 16: ("NW", "SW"), 32: ("NE", "SE")}
# Edge midpoints in a tile of size 1 seen from above with x to the right and y down (north at the top left):
# the NE edge is the x-min side, SW the x-max side, NW the y-min side, SE the y-max side.
EDGE = {"NE": (0.0, 0.5), "SW": (1.0, 0.5), "NW": (0.5, 0.0), "SE": (0.5, 1.0)}


def parse(path: Path):
    size, rows, items = None, {}, {}
    for line in path.read_text(errors="replace").splitlines():
        m = re.search(r"MAPDUMP (\w+) (.*)$", line)
        if not m:
            continue
        kind, rest = m.group(1), m.group(2)
        if kind == "size":   # a new dump starts: keep the last network (the terrain is written once)
            parts = rest.split()
            size, items = (int(parts[0]), int(parts[1]), parts[2] if len(parts) > 2 else ""), {}
        elif kind == "row":
            y, _, data = rest.partition(" ")
            rows[int(y)] = data
        else:
            items.setdefault(kind, []).extend(e for e in rest.split(";") if e)
    return size, rows, items


def land_colour(h: int) -> tuple[int, int, int]:
    shades = [(152, 196, 120), (140, 186, 110), (128, 176, 100), (120, 162, 92), (128, 150, 90), (140, 138, 92),
              (150, 128, 96), (160, 122, 100), (170, 120, 106), (180, 122, 112)]
    return shades[min(h, len(shades) - 1)]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log")
    ap.add_argument("-o", "--out", default="map.png")
    ap.add_argument("--scale", type=int, default=4, help="pixels per tile")
    ap.add_argument("--crop", default="", help="x0,y0,x1,y1 in tiles")
    ap.add_argument("--labels", action="store_true", help="write town names")
    args = ap.parse_args()

    size, rows, items = parse(Path(args.log))
    if size is None:
        print("no MAPDUMP in the log (run the AI with dump_map=1)", file=sys.stderr)
        return 1
    mx, my, date = size
    x0, y0, x1, y1 = 0, 0, mx, my
    if args.crop:
        x0, y0, x1, y1 = (int(v) for v in args.crop.split(","))
    s = args.scale
    img = Image.new("RGB", ((x1 - x0) * s, (y1 - y0) * s), (0, 0, 0))
    dr = ImageDraw.Draw(img)

    def box(x, y):
        return [(x - x0) * s, (y - y0) * s, (x - x0 + 1) * s - 1, (y - y0 + 1) * s - 1]

    for y in range(y0, y1):
        row = rows.get(y, "")
        for x in range(x0, x1):
            c = row[x] if x < len(row) else "0"
            if c == "~":
                col = (70, 110, 190)
            elif c == "h":
                col = (150, 150, 150)
            elif c == "i":
                col = (150, 90, 160)
            elif c == "r":
                col = (205, 205, 205)
            else:
                col = land_colour(int(c, 36))
            dr.rectangle(box(x, y), fill=col)

    def tile(e):
        parts = e.split(",")
        return int(parts[0]), int(parts[1]), parts[2] if len(parts) > 2 else ""

    for e in items.get("road", []):
        x, y, _ = tile(e)
        if x0 <= x < x1 and y0 <= y < y1:
            dr.rectangle(box(x, y), fill=(95, 95, 95))
    width = max(1, s // 4)

    def track(kind, colour):
        for e in items.get(kind, []):
            x, y, t = tile(e)
            if not (x0 <= x < x1 and y0 <= y < y1):
                continue
            if t in ("b", "B"):
                dr.rectangle(box(x, y), fill=(130, 30, 30))
                continue
            bits = int(t)
            for bit, (a, b) in TRACKS.items():
                if bits & bit:
                    ax, ay = EDGE[a]
                    bx, by = EDGE[b]
                    dr.line([((x - x0 + ax) * s, (y - y0 + ay) * s), ((x - x0 + bx) * s, (y - y0 + by) * s)], fill=colour, width=width)

    track("theirrail", (235, 130, 20))
    track("rail", (20, 20, 20))
    for e in items.get("station", []):
        x, y, t = tile(e)
        if x0 <= x < x1 and y0 <= y < y1:
            dr.rectangle(box(x, y), fill=(120, 0, 0) if t == "d" else (220, 30, 30))
    for e in items.get("signal", []):
        x, y, _ = tile(e)
        if x0 <= x < x1 and y0 <= y < y1:
            cx, cy = (x - x0 + 0.5) * s, (y - y0 + 0.5) * s
            r = max(1, s // 5)
            dr.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(250, 220, 40))
    for e in items.get("theirs", []):
        x, y, _ = tile(e)
        if x0 <= x < x1 and y0 <= y < y1:
            dr.rectangle(box(x, y), fill=(255, 150, 20), outline=(90, 40, 0))
    if args.labels:
        for e in items.get("town", []):
            x, y, name = tile(e)
            if x0 <= x < x1 and y0 <= y < y1:
                dr.text(((x - x0) * s + 2, (y - y0) * s + 2), name, fill=(0, 0, 0))
    img.save(args.out)
    print(f"wrote {args.out} ({img.size[0]}x{img.size[1]}) from the dump of {date}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
