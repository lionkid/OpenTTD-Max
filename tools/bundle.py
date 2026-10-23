#!/usr/bin/env python3
"""Package each NewGRF the way BaNaNaS expects: a tar with the .grf, readme.txt, changelog.txt
and license.txt. Output: build/bundle/<name>-<version>.tar

    python3 tools/bundle.py [--version 0.1.0-alpha]
    python3 tools/bundle.py --ai                  # the MaxTransit AI: build/bundle/MaxTransit-<AI version>.tar
    python3 tools/bundle.py --ai --name MaxTycoon  # the MaxTycoon AI
"""
import argparse
import re
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETS = {"max-air": "docs/bananas/readme_air.txt", "max-rail": "docs/bananas/readme_rail.txt"}


AI_READMES = {"MaxTransit": "docs/bananas/readme_ai.txt", "MaxTycoon": "docs/bananas/readme_tycoon.txt"}


def bundle_ai(out: Path, label: str | None, name: str) -> None:
    """The AI folder as OpenTTD loads it (info.nut, main.nut, lib/), plus readme, changelog and licence."""
    ai_dir = ROOT / "ai" / name
    if name not in AI_READMES or not ai_dir.is_dir():
        raise SystemExit(f"unknown AI {name}: one of {', '.join(AI_READMES)}")
    m = re.search(r"GetVersion\(\)\s*\{\s*return\s+(\d+);", (ai_dir / "info.nut").read_text())
    if not m:
        raise SystemExit(f"ai/{name}/info.nut: no GetVersion()")
    folder = f"{name}-{label or m.group(1)}"
    path = out / f"{folder}.tar"
    with tarfile.open(path, "w") as tar:
        for f in sorted(ai_dir.rglob("*.nut")):
            tar.add(f, arcname=f"{folder}/{f.relative_to(ai_dir).as_posix()}")
        tar.add(ROOT / AI_READMES[name], arcname=f"{folder}/readme.txt")
        tar.add(ROOT / "CHANGELOG.md", arcname=f"{folder}/changelog.txt")
        tar.add(ROOT / "LICENSE", arcname=f"{folder}/license.txt")
    print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size // 1024} KiB)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=None, help="label for the file names (default: VERSION file)")
    ap.add_argument("--ai", action="store_true", help="package an AI instead of the NewGRFs")
    ap.add_argument("--name", default="MaxTransit", help="the AI to package (MaxTransit or MaxTycoon)")
    args = ap.parse_args()
    out = ROOT / "build" / "bundle"
    out.mkdir(parents=True, exist_ok=True)
    if args.ai:
        bundle_ai(out, args.version, args.name)
        return
    version = args.version or (ROOT / "VERSION").read_text().strip()
    for name, readme in SETS.items():
        grf = ROOT / f"{name}.grf"
        if not grf.exists():
            raise SystemExit(f"{grf} missing: run make first")
        folder = f"{name}-{version}"
        path = out / f"{folder}.tar"
        with tarfile.open(path, "w") as tar:
            tar.add(grf, arcname=f"{folder}/{name}.grf")
            tar.add(ROOT / readme, arcname=f"{folder}/readme.txt")
            tar.add(ROOT / "CHANGELOG.md", arcname=f"{folder}/changelog.txt")
            tar.add(ROOT / "LICENSE", arcname=f"{folder}/license.txt")
        print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size // 1024} KiB)")


if __name__ == "__main__":
    main()
