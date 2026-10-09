#!/usr/bin/env python3
"""Turn raw 4x renders into OpenTTD sprite sheets (4x / 2x / 1x 32bpp + masks + 8bpp fallback).

Input layout (written by tools/render.py or tools/make_placeholder_gfx.py):
    build/render/<category>/<vehicle>/<part>/view{0..7}_color.png   RGBA, 4x
    build/render/<category>/<vehicle>/<part>/view{0..7}_id.png      RGB(A) material-id pass:
                                                                     red = company colour 1,
                                                                     green = company colour 2
    build/render/<category>/<vehicle>/<part>/render.json             {"zoom": 4, "anchor": [cx, cy]}

Output layout (committed to the repository, consumed by tools/gen_nml.py):
    gfx/<category>/<vehicle>/<part>_{4x,2x,1x}.png        32bpp RGBA sheets, 8 views left-to-right
    gfx/<category>/<vehicle>/<part>_{4x,2x,1x}_mask.png   8bpp company-colour masks, same layout
    gfx/<category>/<vehicle>/<part>_1x_8bpp.png           8bpp DOS-palette fallback
    gfx/<category>/<vehicle>/manifest.json                sprite coordinates and offsets per zoom

View order is OpenTTD's direction order: N, NE, E, SE, S, SW, W, NW.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ottd_palette import CC1_MASK_INDEX, CC2_MASK_INDEX, DOS_FLAT, quantize_8bpp  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
RENDER_DIR = ROOT / "build" / "render"
GFX_DIR = ROOT / "gfx"
VIEWS = 8
ZOOMS = {"4x": 4, "2x": 2, "1x": 1}
CC_TARGET = 128.0
ALIGN = 4  # crop boxes are aligned to 4 px at 4x so 2x and 1x offsets stay integral


def load_rgba(path: Path) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGBA"), dtype=np.uint8)


def id_to_mask(id_img: np.ndarray) -> np.ndarray:
    """Material-id pass -> mask indices (H, W) uint8."""
    r = id_img[..., 0].astype(np.int32)
    g = id_img[..., 1].astype(np.int32)
    mask = np.zeros(id_img.shape[:2], dtype=np.uint8)
    mask[(r > 128) & (r > g)] = CC1_MASK_INDEX
    mask[(g > 128) & (g >= r)] = CC2_MASK_INDEX
    return mask


def aligned_bbox(alpha: np.ndarray, cx: int, cy: int) -> tuple[int, int, int, int]:
    """Bounding box of non-transparent pixels, expanded so that edges are 4-aligned relative to the anchor."""
    ys, xs = np.nonzero(alpha > 0)
    if len(xs) == 0:
        raise ValueError("empty view")
    l, r, t, b = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    l = cx + ((l - cx) // ALIGN) * ALIGN
    t = cy + ((t - cy) // ALIGN) * ALIGN
    r = cx + (-((cx - r) // ALIGN)) * ALIGN
    b = cy + (-((cy - b) // ALIGN)) * ALIGN
    return int(l), int(t), int(r), int(b)


def downscale_rgba(rgba: np.ndarray, factor: int) -> np.ndarray:
    """Premultiplied-alpha Lanczos downscale (avoids dark fringes on transparent edges)."""
    f = rgba.astype(np.float32) / 255.0
    pre = f.copy()
    pre[..., :3] *= pre[..., 3:4]
    img = Image.fromarray((pre * 255.0 + 0.5).astype(np.uint8), "RGBA")
    w, h = img.size
    small = np.asarray(img.resize((w // factor, h // factor), Image.LANCZOS), dtype=np.float32) / 255.0
    a = small[..., 3:4]
    rgb = np.where(a > 0, small[..., :3] / np.maximum(a, 1e-6), 0.0)
    out = np.concatenate([np.clip(rgb, 0, 1), a], axis=2)
    return (out * 255.0 + 0.5).astype(np.uint8)


def downscale_mask(mask: np.ndarray, factor: int) -> np.ndarray:
    """Block-majority downscale of a mask: a block is CC if at least half of its pixels are."""
    h, w = mask.shape
    blocks = mask.reshape(h // factor, factor, w // factor, factor)
    out = np.zeros((h // factor, w // factor), dtype=np.uint8)
    for idx in (CC1_MASK_INDEX, CC2_MASK_INDEX):
        frac = (blocks == idx).mean(axis=(1, 3))
        out[frac >= 0.5] = idx
    return out


def save_8bpp(path: Path, idx: np.ndarray) -> None:
    img = Image.fromarray(idx.astype(np.uint8), "P")
    img.putpalette(DOS_FLAT)
    img.save(path)


def process_part(src: Path, dst: Path, part: str) -> dict:
    meta = json.loads((src / "render.json").read_text())
    if meta.get("zoom") != 4:
        raise ValueError(f"{src}: renders must be 4x")
    cx, cy = meta["anchor"]
    shifts = [int(v) * 4 for v in meta.get("view_x_shift_1x", [0] * VIEWS)]   # 1x px -> 4x px
    gap4 = 8

    crops = []  # per view: (rgba4, mask4, dx4, dy4)
    for k in range(VIEWS):
        rgba = load_rgba(src / f"view{k}_color.png")
        mask = id_to_mask(load_rgba(src / f"view{k}_id.png"))
        l, t, r, b = aligned_bbox(rgba[..., 3], cx, cy)
        dx4, dy4 = l - cx + shifts[k], t - cy
        if meta.get("center_views"):
            dx4 = -((r - l) // 8) * 4
            dy4 = -((b - t) // 8) * 4 + 4      # OpenGFX aircraft sit 1 px (1x) below centre
        crops.append((rgba[t:b, l:r].copy(), mask[t:b, l:r], dx4, dy4))

    # OpenTTD shades a masked pixel by its brightness relative to 128, so scale each company colour
    # region to a mean of 128 (keeping its shading) whatever the lighting or material.
    cc_factors = {}
    for name, idx in (("cc1", CC1_MASK_INDEX), ("cc2", CC2_MASK_INDEX)):
        vals = np.concatenate([c[0][..., :3].max(axis=2)[(c[1] == idx) & (c[0][..., 3] > 0)] for c in crops])
        if vals.size == 0:
            continue
        f = float(np.clip(CC_TARGET / max(float(vals.mean()), 1.0), 0.5, 2.0))
        cc_factors[name] = round(f, 3)
        for rgba4, mask4, _dx, _dy in crops:
            sel = mask4 == idx
            rgba4[..., :3][sel] = np.clip(rgba4[..., :3][sel].astype(np.float32) * f, 0, 255).astype(np.uint8)
    cc_brightness = None

    result = {}
    for zname, z in ZOOMS.items():
        f = 4 // z
        views = []
        sheets_rgba, sheets_mask = [], []
        for rgba4, mask4, dx4, dy4 in crops:
            rgba = rgba4 if f == 1 else downscale_rgba(rgba4, f)
            mask = mask4 if f == 1 else downscale_mask(mask4, f)
            sheets_rgba.append(rgba)
            sheets_mask.append(mask)
            views.append([int(rgba.shape[1]), int(rgba.shape[0]), int(dx4 // f), int(dy4 // f)])
        gap = gap4 // f
        H = max(v.shape[0] for v in sheets_rgba) + 2 * gap
        W = sum(v.shape[1] for v in sheets_rgba) + gap * (VIEWS + 1)
        sheet = np.zeros((H, W, 4), dtype=np.uint8)
        msheet = np.zeros((H, W), dtype=np.uint8)
        x = gap
        coords = []
        for (w, h, dx, dy), rgba, mask in zip(views, sheets_rgba, sheets_mask):
            sheet[gap:gap + h, x:x + w] = rgba
            msheet[gap:gap + h, x:x + w] = mask
            coords.append([int(x), int(gap), int(w), int(h), int(dx), int(dy)])
            x += w + gap
        sheet_name = f"{part}_{zname}.png"
        mask_name = f"{part}_{zname}_mask.png"
        Image.fromarray(sheet, "RGBA").save(dst / sheet_name)
        save_8bpp(dst / mask_name, msheet)
        entry = {"sheet": sheet_name, "mask": mask_name, "views": coords}
        if z == 1:
            fallback = f"{part}_1x_8bpp.png"
            save_8bpp(dst / fallback, quantize_8bpp(sheet, msheet))
            entry["fallback_8bpp"] = fallback
        result[zname] = entry

    return {"zooms": result, "cc_brightness_factor": cc_factors}


def process_vehicle(category: str, vehicle: str) -> Path:
    src = RENDER_DIR / category / vehicle
    dst = GFX_DIR / category / vehicle
    dst.mkdir(parents=True, exist_ok=True)
    parts = sorted(p.name for p in src.iterdir() if p.is_dir() and (p / "render.json").exists())
    if not parts:
        raise SystemExit(f"no rendered parts under {src}")
    manifest = {"category": category, "vehicle": vehicle, "parts": {}}
    for part in parts:
        manifest["parts"][part] = process_part(src / part, dst, part)
    (dst / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return dst


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("targets", nargs="*", help="category/vehicle pairs, e.g. aircraft/b737_800")
    ap.add_argument("--all", action="store_true", help="process every vehicle under build/render")
    args = ap.parse_args()

    targets = list(args.targets)
    if args.all:
        for cat in sorted(p for p in RENDER_DIR.iterdir() if p.is_dir()):
            for veh in sorted(p for p in cat.iterdir() if p.is_dir()):
                targets.append(f"{cat.name}/{veh.name}")
    if not targets:
        ap.error("nothing to do: give category/vehicle targets or --all")
    for t in targets:
        category, vehicle = t.split("/", 1)
        out = process_vehicle(category, vehicle)
        print(f"wrote {out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
