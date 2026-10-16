#!/usr/bin/env python3
"""Pictures of what the MaxTransit AI built: load a savegame under Xvfb, take a giant screenshot of the
whole map at normal zoom and crop it around the given tiles.

    python3 tools/ai/run_ai.py --years 13 --save --out build/ai-shot1      # a game to photograph
    python3 tools/ai/station_shots.py build/ai-shot1/home/save/autosave/exit.sav \\
        terminus-closeup=146,139:640x360@2 sufingpool=42,44:1280x800 --out docs/ai

Each crop is name=x,y[:WxH][@N] with x, y the tile to centre on (default size 960x600) and N an optional
whole-number enlargement (nearest neighbour, for close-ups of the pixel art). Needs Xvfb and the
OpenTTD build that run_ai.py uses; add --grf when the savegame uses max-air.grf / max-rail.grf.
Only maps of 256x256 tiles are supported (the crop offsets follow the giant screenshot of that size).
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
Image.MAX_IMAGE_PIXELS = None   # a 256x256 map at normal zoom is about 16384 x 8500 pixels

CFG = """[misc]
language = english.lng
screenshot_format = png

[gui]
autosave = off
autosave_on_exit = false

[newgrf]
{newgrf}
"""


def tile_pixel(x: int, y: int) -> tuple[int, int]:
    """Screen position of a tile's north corner in the giant screenshot of a 256x256 map at height 0."""
    return (y - x) * 32 + 8128, (x + y) * 16 + 134


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("save")
    ap.add_argument("crops", nargs="+", help="name=x,y[:WxH][@N]")
    ap.add_argument("--out", default=str(ROOT / "build" / "shots"))
    ap.add_argument("--grf", action="store_true")
    ap.add_argument("--openttd", default="/opt/src/openttd-15.3/build/openttd")
    args = ap.parse_args()

    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    home = ROOT / "build" / "shots-home"
    if home.exists():
        shutil.rmtree(home)
    data = home / ".local" / "share" / "openttd"
    for sub in ("baseset", "newgrf", "scripts", "save", "screenshot"):
        (data / sub).mkdir(parents=True)
    ogfx = Path("/usr/share/games/openttd/baseset/opengfx")
    (data / "baseset" / "opengfx").mkdir()
    for f in ogfx.iterdir():
        if f.suffix in (".grf", ".obg") and f.exists():
            shutil.copy(f, data / "baseset" / "opengfx" / f.name)
    newgrf = ""
    if args.grf:
        for grf in ("max-air.grf", "max-rail.grf"):
            shutil.copy(ROOT / grf, data / "newgrf" / grf)
            newgrf += f"{grf} =\n"
    shutil.copy(args.save, data / "save" / "shot.sav")
    (data / "scripts" / "game_start.scr").write_text("screenshot giant map\nquit\n")
    cfg = home / "openttd.cfg"
    cfg.write_text(CFG.format(newgrf=newgrf))
    env = {"HOME": str(home), "XDG_DATA_HOME": str(home / ".local" / "share"), "XDG_CONFIG_HOME": str(home / ".config"),
           "PATH": "/usr/bin:/bin"}
    cmd = ["xvfb-run", "-a", "-s", "-screen 0 1024x768x24", args.openttd, "-c", str(cfg), "-vsdl", "-snull", "-mnull",
           "-g", str(data / "save" / "shot.sav")]
    subprocess.run(cmd, env=env, cwd=str(home), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900)
    shots = sorted(home.rglob("map*.png"))   # OpenTTD may pick the working directory as its personal dir
    if not shots:
        print("no screenshot was written", file=sys.stderr)
        return 1
    giant = Image.open(shots[-1])
    print(f"giant screenshot {giant.size[0]}x{giant.size[1]}")
    for spec in args.crops:
        name, rest = spec.split("=", 1)
        rest, _, scale = rest.partition("@")
        where, _, size = rest.partition(":")
        x, y = (int(v) for v in where.split(","))
        w, h = (int(v) for v in size.split("x")) if size else (960, 600)
        px, py = tile_pixel(x, y)
        box = (px - w // 2, py - h // 2, px + w - w // 2, py + h - h // 2)
        img = giant.crop(box).convert("RGB")
        if scale:
            img = img.resize((w * int(scale), h * int(scale)), Image.Resampling.NEAREST)
        path = out / f"{name}.png"
        img.quantize(colors=256, method=Image.Quantize.MEDIANCUT).save(path, optimize=True)
        print(f"wrote {path} ({path.stat().st_size // 1024} KiB) around tile {x},{y}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
