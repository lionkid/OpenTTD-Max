#!/usr/bin/env python3
"""Run one of the repository's AIs headless (null video, sound and music drivers) for a number of game years
and summarise its log: construction, CargoDist reports, safety incidents, score and script errors.

    python3 tools/ai/run_ai.py --years 10                         # MaxTransit, vanilla vehicles, CargoDist symmetric
    python3 tools/ai/run_ai.py --ai MaxTycoon --years 20 --ending-year 2010 --start-year 1990
    python3 tools/ai/run_ai.py --years 10 --grf --start-year 2016 # with max-air.grf and max-rail.grf
    python3 tools/ai/run_ai.py --cargodist manual --crashes 2 --breakdowns 2
    python3 tools/ai/run_ai.py --ai MaxTransit2 --years 10        # the second-generation AI
    python3 tools/ai/run_ai.py --ai MaxTransit2 --competitor MaxTransit   # another company starts first
    python3 tools/ai/run_ai.py --ai MaxTycoon --years 21 --ending-year 2010 --industries 4 --economy 1

Needs an OpenTTD binary (tools/ingame/build_openttd.sh) and OpenGFX (apt: openttd-opengfx). On macOS the
Steam build is used when present: it finds its own OpenGFX, and its personal folder is ~/Documents/OpenTTD
under the temporary HOME. The game runs as fast as the machine allows; the AI keeps the default opcode
budget unless --opcodes is given.
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
MACOS = sys.platform == "darwin"
STEAM_OPENTTD = Path.home() / "Library/Application Support/Steam/steamapps/common/OpenTTD/OpenTTD.app/Contents/MacOS/openttd"
DEFAULT_OPENTTD = str(STEAM_OPENTTD) if MACOS and STEAM_OPENTTD.exists() else "/opt/src/openttd-15.3/build/openttd"

CFG = """[misc]
language = english.lng

[gui]
autosave = off
autosave_on_exit = {save}

[game_creation]
landscape = {landscape}
starting_year = {start_year}
ending_year = {ending_year}
map_x = {map}
map_y = {map}
land_generator = 1
variety = 0
tree_placer = 1
town_name = english

[difficulty]
max_no_competitors = {competitors}
number_towns = {towns}
industry_density = {industries}{terrain_sea}
max_loan = {loan}
vehicle_breakdowns = {breakdowns}
disasters = {disasters}
economy = {economy}
{ai_speed_line}
[linkgraph]
distribution_pax = {dist}
distribution_mail = {dist}
distribution_default = {dist_freight}

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
    ap.add_argument("--openttd", default=DEFAULT_OPENTTD)
    ap.add_argument("--ai", default="MaxTransit", help="AI folder under ai/ to run (MaxTransit, MaxTransit2 or MaxTycoon)")
    ap.add_argument("--competitor", action="append", default=[],
                    help="AI started before ours as another company (ai/<name> if it is one of ours, else installed)")
    ap.add_argument("--industries", type=int, default=2, help="industry density 0 (fund only) .. 5 (high)")
    ap.add_argument("--years", type=float, default=5.0)
    ap.add_argument("--start-year", type=int, default=1990)
    ap.add_argument("--map", type=int, default=8, help="map size exponent (8 = 256 tiles)")
    ap.add_argument("--towns", type=int, default=2, help="0 very low .. 3 high")
    ap.add_argument("--terrain", type=int, default=None, help="0 very flat .. 4 mountainous (default: the game's)")
    ap.add_argument("--sea", type=int, default=None, help="sea level 0 very low .. 4 high (default: the game's)")
    ap.add_argument("--landscape", default="temperate")
    ap.add_argument("--ending-year", type=int, default=2050, help="game_creation.ending_year (the high score year)")
    ap.add_argument("--economy", type=int, default=0, help="difficulty.economy: 0 original, 1 smooth, 2 frozen")
    ap.add_argument("--cargodist-freight", choices=DIST, default="manual")
    ap.add_argument("--loan", type=int, default=500000)
    ap.add_argument("--cargodist", choices=DIST, default="symmetric")
    ap.add_argument("--crashes", type=int, default=2)
    ap.add_argument("--breakdowns", type=int, default=1)
    ap.add_argument("--disasters", action="store_true")
    ap.add_argument("--plane-speed", type=int, default=4)
    ap.add_argument("--train-length", type=int, default=7)
    ap.add_argument("--no-town-crossings", action="store_true")
    ap.add_argument("--opcodes", type=int, default=10000)
    ap.add_argument("--ai-speed", type=int, default=-1, choices=range(-1, 5),
                    help="difficulty.competitor_speed: the AI runs every 2^(4-n) ticks (2 = every 4th, the game's default; "
                         "4 = every tick); -1 leaves the setting out of the config")
    ap.add_argument("--seed", type=int, default=20261016)
    ap.add_argument("--grf", action="store_true", help="load max-air.grf and max-rail.grf from the repo root")
    ap.add_argument("--ai-settings", default="", help="e.g. 'use_air=0 frequency=2' (passed to start_ai comma-separated)")
    ap.add_argument("--save", action="store_true", help="save the game at the end (save/autosave/exit.sav)")
    ap.add_argument("--load", default="", help="start from this savegame instead of a new game")
    ap.add_argument("--ai-tar", default="", help="install this AI tar (make ai-bundle) instead of the ai/ directory")
    ap.add_argument("--out", default=str(ROOT / "build" / "ai-test"))
    ap.add_argument("--timeout", type=float, default=3600)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    out = Path(args.out).resolve()
    home = out / "home"
    if home.exists():
        shutil.rmtree(home)
    data = home / "Documents" / "OpenTTD" if MACOS else home / ".local" / "share" / "openttd"
    for sub in ("ai", "baseset", "newgrf", "scripts", "save"):
        (data / sub).mkdir(parents=True)
    ogfx = Path("/usr/share/games/openttd/baseset/opengfx")
    if ogfx.exists():
        (data / "baseset" / "opengfx").mkdir()
        for f in ogfx.iterdir():
            if f.suffix in (".grf", ".obg") and f.exists():
                shutil.copy(f, data / "baseset" / "opengfx" / f.name)
    elif not MACOS:   # the macOS (Steam) build ships its own base graphics next to the app
        print("OpenGFX not found (apt install openttd-opengfx)", file=sys.stderr)
        return 2
    if args.ai_tar:
        shutil.copy(args.ai_tar, data / "ai" / Path(args.ai_tar).name)   # the packaged AI, as BaNaNaS ships it
    else:
        shutil.copytree(ROOT / "ai" / args.ai, data / "ai" / args.ai)
    for comp in args.competitor:
        if (ROOT / "ai" / comp).is_dir() and not (data / "ai" / comp).exists():
            shutil.copytree(ROOT / "ai" / comp, data / "ai" / comp)
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
    if not args.load:   # a loaded game resumes its own AI company; start_ai would add a second one
        script = "".join(f"start_ai {comp}\n" for comp in args.competitor)
        # start_ai takes the settings as one argument, name=value pairs separated by commas
        settings = ",".join(args.ai_settings.replace(",", " ").split())
        script += f"start_ai {args.ai} {settings}".rstrip() + "\n"
        (data / "scripts" / "game_start.scr").write_text(script)
    if args.load:
        shutil.copy(args.load, data / "save" / "start.sav")
    else:
        (data / "scripts" / "autoexec.scr").write_text(f"newgame {args.seed}\n")
    cfg = home / "openttd.cfg"
    cfg.write_text(CFG.format(
        landscape=args.landscape, start_year=args.start_year, ending_year=args.ending_year, map=args.map,
        # both are difficulty settings; only written when asked for, so default maps stay as they were
        terrain_sea=("" if args.terrain is None else f"\nterrain_type = {args.terrain}") +
                    ("" if args.sea is None else f"\nquantity_sea_lakes = {args.sea}"),
        towns=args.towns, industries=args.industries, competitors=1 + len(args.competitor),
        economy=args.economy, dist_freight=DIST[args.cargodist_freight],
        loan=args.loan, breakdowns=args.breakdowns, disasters="true" if args.disasters else "false",
        dist=DIST[args.cargodist], opcodes=args.opcodes, train_length=args.train_length, plane_speed=args.plane_speed,
        crashes=args.crashes, town_crossings="false" if args.no_town_crossings else "true", newgrf=newgrf,
        ai_speed_line=f"competitor_speed = {args.ai_speed}\n" if args.ai_speed >= 0 else "",
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
    return summarise(text, args.quiet, bool(args.competitor))


def summarise(text: str, quiet: bool, companies: bool = False) -> int:
    lines = text.splitlines()
    errors = [l for l in lines if "Your script made an error" in l or "*FUNCTION" in l or "died unexpectedly" in l or
              "Failed to load the specified AI" in l]
    logged = [l for l in lines if "[E]" in l]
    crash = [l for l in lines if "INCIDENT" in l]
    keep = re.compile(r"\[(REPORT|BUILD|SAFETY|CDIST|PLAN|BANK|MAIN|COURTESY|SCORE|TOWN|INDUSTRY)\]")
    if not quiet:
        for l in lines:
            if keep.search(l):
                # with several AI companies the company number stays in front of each line
                print(re.sub(r"^\[[^\]]*\] dbg: \[script:\d\] (\[\d+\]) ", r"\1 " if companies else "", l))
    print(f"--- script errors: {len(errors)}, error-level log lines: {len(logged)}, incidents: {len(crash)}")
    for l in logged[:20]:
        print(l)
    for l in errors[:40]:
        print(l)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
