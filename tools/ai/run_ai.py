#!/usr/bin/env python3
"""Run the MaxTransit AI headless (null video, sound and music drivers) for a number of game years and
summarise its log: construction, CargoDist reports, safety incidents and script errors.

    python3 tools/ai/run_ai.py --years 10                         # vanilla vehicles, CargoDist symmetric
    python3 tools/ai/run_ai.py --years 10 --grf --start-year 2016 # with max-air.grf and max-rail.grf
    python3 tools/ai/run_ai.py --cargodist manual --crashes 2 --breakdowns 2

Needs an OpenTTD binary (tools/ingame/build_openttd.sh) and OpenGFX (apt: openttd-opengfx). The game runs
as fast as the machine allows; the AI keeps the default opcode budget unless --opcodes is given.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TICKS_PER_YEAR = 74 * 365

CFG = """[misc]
language = english.lng

[gui]
autosave = off
autosave_on_exit = {save}

[game_creation]
landscape = {landscape}
starting_year = {start_year}
map_x = {map}
map_y = {map}
land_generator = 1
terrain_type = {terrain}
quantity_sea_lakes = {sea}
variety = 0
tree_placer = 1
town_name = english

[difficulty]
max_no_competitors = 1
number_towns = {towns}
industry_density = 2
max_loan = {loan}
vehicle_breakdowns = {breakdowns}
disasters = {disasters}
economy = 0

[linkgraph]
distribution_pax = {dist}
distribution_mail = {dist}

[script]
script_max_opcode_till_suspend = {opcodes}
script_max_memory_megabytes = 1024

[vehicle]
max_train_length = {train_length}
plane_speed = {plane_speed}
plane_crashes = {crashes}
train_acceleration_model = 1
roadveh_acceleration_model = 1

[economy]
inflation = false
allow_town_level_crossings = {town_crossings}

[news_display]
arrival_player = off
arrival_other = off
accident = off
accident_other = off
company_info = off
open = off
close = off
economy = off
production_player = off
production_other = off
production_nobody = off
advice = off
new_vehicles = off
acceptance = off
subsidies = off
general = off

[newgrf]
{newgrf}
"""

DIST = {"manual": 0, "asymmetric": 1, "symmetric": 2}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--openttd", default="/opt/src/openttd-15.3/build/openttd")
    ap.add_argument("--years", type=float, default=5.0)
    ap.add_argument("--start-year", type=int, default=1990)
    ap.add_argument("--map", type=int, default=8, help="map size exponent (8 = 256 tiles)")
    ap.add_argument("--towns", type=int, default=2, help="0 very low .. 3 high")
    ap.add_argument("--terrain", type=int, default=1, help="0 very flat .. 4 mountainous")
    ap.add_argument("--sea", type=int, default=1, help="0 very low .. 4 high")
    ap.add_argument("--landscape", default="temperate")
    ap.add_argument("--loan", type=int, default=500000)
    ap.add_argument("--cargodist", choices=DIST, default="symmetric")
    ap.add_argument("--crashes", type=int, default=2)
    ap.add_argument("--breakdowns", type=int, default=1)
    ap.add_argument("--disasters", action="store_true")
    ap.add_argument("--plane-speed", type=int, default=4)
    ap.add_argument("--train-length", type=int, default=7)
    ap.add_argument("--no-town-crossings", action="store_true")
    ap.add_argument("--opcodes", type=int, default=10000)
    ap.add_argument("--seed", type=int, default=20261016)
    ap.add_argument("--grf", action="store_true", help="load max-air.grf and max-rail.grf from the repo root")
    ap.add_argument("--ai-settings", default="", help="e.g. 'use_air=0 frequency=2'")
    ap.add_argument("--save", action="store_true", help="save the game at the end (save/autosave/exit.sav)")
    ap.add_argument("--load", default="", help="start from this savegame instead of a new game")
    ap.add_argument("--out", default=str(ROOT / "build" / "ai-test"))
    ap.add_argument("--timeout", type=float, default=3600)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    out = Path(args.out).resolve()
    home = out / "home"
    if home.exists():
        shutil.rmtree(home)
    data = home / ".local" / "share" / "openttd"
    for sub in ("ai", "baseset", "newgrf", "scripts", "save"):
        (data / sub).mkdir(parents=True)
    ogfx = Path("/usr/share/games/openttd/baseset/opengfx")
    if not ogfx.exists():
        print("OpenGFX not found (apt install openttd-opengfx)", file=sys.stderr)
        return 2
    (data / "baseset" / "opengfx").mkdir()
    for f in ogfx.iterdir():
        if f.suffix in (".grf", ".obg") and f.exists():
            shutil.copy(f, data / "baseset" / "opengfx" / f.name)
    shutil.copytree(ROOT / "ai" / "MaxTransit", data / "ai" / "MaxTransit")
    newgrf = ""
    if args.grf:
        for i, grf in enumerate(("max-air.grf", "max-rail.grf")):
            src = ROOT / grf
            if not src.exists():
                print(f"{grf} missing: run make first", file=sys.stderr)
                return 2
            shutil.copy(src, data / "newgrf" / grf)
            newgrf += f"{grf} =\n"
    ticks = int(args.years * TICKS_PER_YEAR)
    (data / "scripts" / "game_start.scr").write_text(f"start_ai MaxTransit {args.ai_settings}\n".rstrip() + "\n")
    if args.load:
        shutil.copy(args.load, data / "save" / "start.sav")
    else:
        (data / "scripts" / "autoexec.scr").write_text(f"newgame {args.seed}\n")
    cfg = home / "openttd.cfg"
    cfg.write_text(CFG.format(
        landscape=args.landscape, start_year=args.start_year, map=args.map, terrain=args.terrain, sea=args.sea,
        towns=args.towns, loan=args.loan, breakdowns=args.breakdowns, disasters="true" if args.disasters else "false",
        dist=DIST[args.cargodist], opcodes=args.opcodes, train_length=args.train_length, plane_speed=args.plane_speed,
        crashes=args.crashes, town_crossings="false" if args.no_town_crossings else "true", newgrf=newgrf,
        save="true" if args.save else "false"))
    log = out / "openttd.log"
    env = {"HOME": str(home), "XDG_DATA_HOME": str(home / ".local" / "share"), "XDG_CONFIG_HOME": str(home / ".config"),
           "PATH": "/usr/bin:/bin"}
    cmd = [args.openttd, "-x", "-c", str(cfg), "-snull", "-mnull", f"-vnull:ticks={ticks}", "-d", "script=4"]
    if args.load:
        cmd += ["-g", str(data / "save" / "start.sav")]
    print("running:", " ".join(cmd), flush=True)
    t0 = time.time()
    with open(log, "wb") as lf:
        try:
            proc = subprocess.run(cmd, env=env, cwd=str(home), stdout=lf, stderr=subprocess.STDOUT, timeout=args.timeout)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            code = -1
    dt = time.time() - t0
    text = log.read_text(errors="replace")
    print(f"exit {code} after {dt:.0f} s, {args.years} game years; log {log}")
    return summarise(text, args.quiet)


def summarise(text: str, quiet: bool) -> int:
    lines = text.splitlines()
    errors = [l for l in lines if "Your script made an error" in l or "*FUNCTION" in l or "died unexpectedly" in l]
    logged = [l for l in lines if "[E]" in l]
    crash = [l for l in lines if "INCIDENT" in l]
    keep = re.compile(r"\[(REPORT|BUILD|SAFETY|CDIST|PLAN|BANK|MAIN)\]")
    if not quiet:
        for l in lines:
            if keep.search(l):
                print(re.sub(r"^\[[^\]]*\] dbg: \[script:\d\] \[\d+\] ", "", l))
    print(f"--- script errors: {len(errors)}, error-level log lines: {len(logged)}, incidents: {len(crash)}")
    for l in logged[:20]:
        print(l)
    for l in errors[:40]:
        print(l)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
