#!/usr/bin/env python3
"""Render simple procedural placeholder sprites (no Blender needed) in the same raw format
that tools/render.py produces, then run the normal post-processing on them.

Used for vehicles that have data but no artwork yet, so the whole set compiles and can be
balance-tested before the art is finished. Output: gfx/_placeholder/{aircraft,trains}/.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import postprocess  # noqa: E402
from ottd_scale import PX_PER_M_1X  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
ZOOM = 4
CANVAS = (160, 120)          # 1x canvas; scaled by ZOOM


def project(x: float, y: float, z: float, scale: float) -> tuple[float, float]:
    """Dimetric projection matching the Blender camera: elevation 30 deg, screen-up = +Y."""
    sx = x * scale
    sy = -(y * math.sin(math.radians(30)) + z * math.cos(math.radians(30))) * scale
    return sx, sy


def draw_polys(polys, heading_deg: float, size, anchor, scale, id_pass: bool):
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    a = math.radians(heading_deg)
    ca, sa = math.cos(a), math.sin(a)
    for pts, z, colour, cc in polys:
        screen = []
        for (x, y) in pts:
            rx, ry = x * ca - y * sa, x * sa + y * ca
            sx, sy = project(rx, ry, z, scale)
            screen.append((anchor[0] + sx, anchor[1] + sy))
        fill = ((255, 0, 0, 255) if cc else (0, 0, 0, 255)) if id_pass else colour
        d.polygon(screen, fill=fill)
    return img


def aircraft_polys():
    """Top-down 737-sized silhouette in metres, nose along +X."""
    fus = [(-19, -1.9), (17, -1.9), (20, 0), (17, 1.9), (-19, 1.9)]
    wing = [(-2, 1.9), (-9, 17), (-12, 17), (-9, 1.9)]
    wing_m = [(x, -y) for x, y in wing]
    tail = [(-16, 1.5), (-19, 6.5), (-21, 6.5), (-19, 1.5)]
    tail_m = [(x, -y) for x, y in tail]
    fin = [(-15, 0), (-19.5, 0), (-21, 0)]  # drawn as a thin vertical slab below
    body = (225, 225, 232, 255)
    return [
        (wing, 2.0, (200, 200, 208, 255), False),
        (wing_m, 2.0, (200, 200, 208, 255), False),
        (tail, 3.5, (200, 200, 208, 255), False),
        (tail_m, 3.5, (200, 200, 208, 255), False),
        (fus, 3.0, body, False),
        ([(-17, -1.9), (12, -1.9), (12, -1.2), (-17, -1.2)], 3.0, (128, 128, 128, 255), True),  # cheat line (CC)
        ([(-15, -0.3), (-20, -0.3), (-20, 0.3), (-15, 0.3)], 9.0, (128, 128, 128, 255), True),   # fin top (CC)
    ]


def train_polys():
    """Top-down 25 m car in metres, front along +X."""
    roof = [(-12.5, -1.6), (12.5, -1.6), (12.5, 1.6), (-12.5, 1.6)]
    return [
        (roof, 3.6, (235, 235, 240, 255), False),
        ([(-12.5, -1.7), (12.5, -1.7), (12.5, -1.3), (-12.5, -1.3)], 2.4, (128, 128, 128, 255), True),  # CC stripe
        ([(-12.5, 1.3), (12.5, 1.3), (12.5, 1.7), (-12.5, 1.7)], 2.4, (128, 128, 128, 255), True),
        ([(10, -1.6), (12.5, -1.6), (12.5, 1.6), (10, 1.6)], 3.6, (40, 40, 60, 255), False),         # cab window
    ]


def write_part(category: str, polys, part: str = "body") -> None:
    out = ROOT / "build" / "render" / "_placeholder" / category / part
    out.mkdir(parents=True, exist_ok=True)
    size = (CANVAS[0] * ZOOM, CANVAS[1] * ZOOM)
    anchor = (size[0] // 2, size[1] // 2)
    scale = PX_PER_M_1X * ZOOM
    for k in range(8):
        heading = 90 - 45 * k  # N, NE, E, SE, S, SW, W, NW
        draw_polys(polys, heading, size, anchor, scale, False).save(out / f"view{k}_color.png")
        draw_polys(polys, heading, size, anchor, scale, True).save(out / f"view{k}_id.png")
    (out / "render.json").write_text(json.dumps({"zoom": ZOOM, "anchor": list(anchor)}) + "\n")


def main() -> None:
    write_part("aircraft", aircraft_polys())
    write_part("trains", train_polys())
    for category in ("aircraft", "trains"):
        dst = postprocess.process_vehicle("_placeholder", category)
        print(f"wrote {dst.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
