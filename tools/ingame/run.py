#!/usr/bin/env python3
"""Launch OpenTTD under Xvfb with the test GRFs, let the MaxTest AI build an aircraft and a train,
then take 4x-zoom screenshots of both vehicles via the in-game console (driven with xdotool).

    make test-grf                       # badge-free GRFs for OpenTTD 13/14 in build/test/
    python3 tools/ingame/run.py          # screenshots land in build/qa/

Requirements: openttd (apt: openttd openttd-opengfx), Xvfb, xdotool.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
DISPLAY = ":99"
RES = (1280, 960)


def console(cmd: str) -> None:
    """Type a console command into the focused OpenTTD window."""
    env = dict(os.environ, DISPLAY=DISPLAY)
    run = lambda *a: subprocess.run(["xdotool", *a], env=env, check=False)  # noqa: E731
    run("mousemove", str(RES[0] // 2), str(RES[1] // 2))
    if not console_is_open():
        run("key", "grave")
        time.sleep(0.4)
    run("type", "--delay", "15", cmd)
    run("key", "Return")
    time.sleep(0.3)
    run("key", "grave")
    time.sleep(0.4)
    if console_is_open():          # toggled the wrong way: try once more
        run("key", "grave")
        time.sleep(0.4)


def zoom_in(clicks: int) -> None:
    env = dict(os.environ, DISPLAY=DISPLAY)
    subprocess.run(["xdotool", "mousemove", str(RES[0] // 2), str(RES[1] // 2)], env=env, check=False)
    for _ in range(clicks):
        subprocess.run(["xdotool", "click", "4"], env=env, check=False)
        time.sleep(0.4)


def latest_positions(log: Path) -> dict[str, int]:
    pos = {}
    for line in log.read_text(errors="replace").splitlines():
        m = re.search(r"MAXTEST pos (\w+) (\d+)", line)
        if m:
            pos[m.group(1)] = int(m.group(2))
    return pos


def vehicle_names(log: Path) -> dict[str, str]:
    names = {}
    for line in log.read_text(errors="replace").splitlines():
        m = re.search(r"MAXTEST vehicle (\w+) (?:aircraft|train) (.+?)(?: length .*)?$", line)
        if m:
            names[m.group(1)] = m.group(2)
    return names


def wait_for(log: Path, pattern: str, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if log.exists() and re.search(pattern, log.read_text(errors="replace")):
            return True
        time.sleep(1.0)
    return False


def capture(dst: Path) -> None:
    """Grab the whole Xvfb screen (what a player would see) with ImageMagick."""
    subprocess.run(["import", "-display", DISPLAY, "-window", "root", str(dst)], check=True)


def console_is_open() -> bool:
    """The console covers the top half of the screen with a dark overlay; sample one row of it."""
    from PIL import Image
    tmp = ROOT / "build" / "ingame" / "probe.png"
    capture(tmp)
    img = Image.open(tmp).convert("L")
    row = [img.getpixel((x, 150)) for x in range(0, img.size[0], 16)]
    return sum(row) / len(row) < 48


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--grf-dir", default=str(ROOT / "build" / "test"))
    ap.add_argument("--out", default=str(ROOT / "build" / "qa"))
    ap.add_argument("--shots", type=int, default=4, help="screenshot rounds per vehicle")
    ap.add_argument("--interval", type=float, default=12.0, help="seconds between rounds")
    ap.add_argument("--openttd", default=shutil.which("openttd") or "/usr/games/openttd")
    ap.add_argument("--hold", type=float, default=0.0,
                    help="keep the game running this many seconds after the screenshots (drive it with xdotool)")
    args = ap.parse_args()

    home = ROOT / "build" / "ingame" / "home"
    if home.exists():
        shutil.rmtree(home)
    data = home / ".local" / "share" / "openttd"
    for sub in ("newgrf", "ai", "scripts", "screenshot", "save"):
        (data / sub).mkdir(parents=True)
    for grf in ("max-air.grf", "max-rail.grf"):
        shutil.copy(Path(args.grf_dir) / grf, data / "newgrf" / grf)
    # A self-built OpenTTD does not look in the distro base set directory; give it OpenGFX.
    ogfx = Path("/usr/share/games/openttd/baseset/opengfx")
    if ogfx.exists():
        (data / "baseset" / "opengfx").mkdir(parents=True)
        for f in ogfx.iterdir():
            if f.suffix in (".grf", ".obg") and f.exists():
                shutil.copy(f, data / "baseset" / "opengfx" / f.name)
    shutil.copytree(HERE / "ai" / "MaxTest", data / "ai" / "MaxTest")
    for scr in (HERE / "scripts").glob("*.scr"):
        shutil.copy(scr, data / "scripts" / scr.name)
    cfg = home / "openttd.cfg"
    cfg.write_text((HERE / "openttd.cfg.in").read_text())
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    log = out / "openttd.log"

    xvfb = subprocess.Popen(["Xvfb", DISPLAY, "-screen", "0", f"{RES[0]}x{RES[1]}x24", "-nolisten", "tcp"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)
    env = dict(os.environ, HOME=str(home), DISPLAY=DISPLAY, XDG_DATA_HOME=str(home / ".local" / "share"),
               XDG_CONFIG_HOME=str(home / ".config"))
    cmd = [args.openttd, "-c", str(cfg), "-x", "-v", "sdl", "-b", "32bpp-anim", "-s", "null", "-m", "null",
           "-r", f"{RES[0]}x{RES[1]}", "-d", "script=4,grf=2"]
    print("launching:", " ".join(cmd), flush=True)
    with open(log, "wb") as lf:
        game = subprocess.Popen(cmd, env=env, cwd=str(home), stdout=lf, stderr=subprocess.STDOUT)
        try:
            if not wait_for(log, r"MAXTEST ready", 150):
                raise SystemExit("the MaxTest AI did not report ready; see " + str(log))
            print("AI ready; waiting for vehicles to leave their depots", flush=True)
            time.sleep(8.0)
            env_x = dict(os.environ, DISPLAY=DISPLAY)
            wid = subprocess.run(["xdotool", "search", "--name", "OpenTTD"], env=env_x, capture_output=True,
                                 text=True).stdout.split()
            if wid:
                subprocess.run(["xdotool", "windowfocus", "--sync", wid[0]], env=env_x, check=False)
            zoom_in(3)                           # viewport to 4x
            names = vehicle_names(log)
            (out / "vehicles.txt").write_text("\n".join(f"{k}\t{v}" for k, v in sorted(names.items())) + "\n")
            for i in range(args.shots):
                # Pause first so fast vehicles are still where the AI last saw them.
                console("pause")
                time.sleep(0.5)
                pos = latest_positions(log)
                for key in sorted(pos):
                    console(f"scrollto {pos[key]}")
                    time.sleep(0.6)
                    dst = out / f"{key}_{i:02d}.png"
                    capture(dst)
                    print(f"saved {dst.relative_to(ROOT)} ({names.get(key, key)}, tile {pos[key]})", flush=True)
                console("unpause")
                time.sleep(args.interval)
            if args.hold > 0:
                print(f"holding for {args.hold:.0f} s on DISPLAY={DISPLAY}", flush=True)
                time.sleep(args.hold)
        finally:
            game.terminate()
            try:
                game.wait(10)
            except subprocess.TimeoutExpired:
                game.kill()
            xvfb.terminate()
    print("done; log at", log.relative_to(ROOT))


if __name__ == "__main__":
    main()
