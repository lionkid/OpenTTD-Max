#!/usr/bin/env python3
"""Compare our 1x sprite sizes and offsets with OpenGFX reference vehicles, per view.

    python3 tools/calibrate.py trains/n700:mid=2953 aircraft/b747_400:body=3749

Each argument is <category>/<vehicle>:<part>=<first OpenGFX sprite number of an 8-view set>.
OpenGFX is decoded once with grfcodec into build/ogfx/ (apt: grfcodec, openttd-opengfx).
Reference sets used in M1: 2953 (passenger coach), 2985 (streamlined maglev), 3749 (747-class jet).
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OGFX_GRF = Path("/usr/share/games/openttd/baseset/opengfx/ogfx1_base.grf")
NAMES = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]


def ogfx_table() -> dict[int, tuple[int, int, int, int]]:
    out = ROOT / "build" / "ogfx"
    nfo = out / "sprites" / "ogfx1_base.nfo"
    if not nfo.exists():
        out.mkdir(parents=True, exist_ok=True)
        shutil.copy(OGFX_GRF, out / OGFX_GRF.name)
        subprocess.run(["grfcodec", "-d", "-p", "2", "-x", OGFX_GRF.name], cwd=out, check=True, capture_output=True)
    table = {}
    for line in nfo.read_text(encoding="latin-1").splitlines():
        m = re.match(r"\s*(\d+)\s+\S+\s+8bpp\s+\d+\s+\d+\s+(\d+)\s+(\d+)\s+(-?\d+)\s+(-?\d+)", line)
        if m:
            n, w, h, dx, dy = (int(v) for v in m.groups())
            table[n] = (w, h, dx, dy)
    return table


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pairs", nargs="+")
    args = ap.parse_args()
    ref = ogfx_table()
    for pair in args.pairs:
        target, base = pair.split("=")
        veh, part = target.split(":")
        man = json.loads((ROOT / "gfx" / veh / "manifest.json").read_text())
        views = man["parts"][part]["zooms"]["1x"]["views"]
        base = int(base)
        print(f"\n{veh}:{part} vs OpenGFX {base}   (w x h @ dx,dy ; 1x)")
        rw = rh = 0.0
        for k in range(8):
            _, _, w, h, dx, dy = views[k]
            ow, oh, odx, ody = ref[base + k]
            rw += w / ow
            rh += h / oh
            print(f"  {NAMES[k]:>2}: ours {w:3d}x{h:<3d} @{dx:4d},{dy:<4d}  ogfx {ow:3d}x{oh:<3d} @{odx:4d},{ody:<4d}"
                  f"  ratio {w / ow:4.2f} x {h / oh:4.2f}  centre dy {dy + h / 2 - (ody + oh / 2):+5.1f}")
        print(f"  mean ratio  w {rw / 8:.2f}  h {rh / 8:.2f}")


if __name__ == "__main__":
    main()
