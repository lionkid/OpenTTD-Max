#!/usr/bin/env python3
"""Package each NewGRF the way BaNaNaS expects: a tar with the .grf, readme.txt, changelog.txt
and license.txt. Output: build/bundle/<name>-<version>.tar

    python3 tools/bundle.py [--version 0.1.0-alpha]
    python3 tools/bundle.py --ai      # the MaxTransit AI: build/bundle/MaxTransit-<AI version>.tar
"""
import argparse
import re
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETS = {"max-air": "docs/bananas/readme_air.txt", "max-rail": "docs/bananas/readme_rail.txt"}


AI_DIR = ROOT / "ai" / "MaxTransit"


def bundle_ai(out: Path, label: str | None) -> None:
    """The AI folder as OpenTTD loads it (info.nut, main.nut, lib/), plus readme, changelog and licence."""
    m = re.search(r"GetVersion\(\)\s*\{\s*return\s+(\d+);", (AI_DIR / "info.nut").read_text())
    if not m:
        raise SystemExit("ai/MaxTransit/info.nut: no GetVersion()")
    folder = f"MaxTransit-{label or m.group(1)}"
    path = out / f"{folder}.tar"
    with tarfile.open(path, "w") as tar:
        for f in sorted(AI_DIR.rglob("*.nut")):
            tar.add(f, arcname=f"{folder}/{f.relative_to(AI_DIR).as_posix()}")
        tar.add(ROOT / "docs" / "bananas" / "readme_ai.txt", arcname=f"{folder}/readme.txt")
        tar.add(ROOT / "CHANGELOG.md", arcname=f"{folder}/changelog.txt")
        tar.add(ROOT / "LICENSE", arcname=f"{folder}/license.txt")
    print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size // 1024} KiB)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=None, help="label for the file names (default: VERSION file)")
    ap.add_argument("--ai", action="store_true", help="package the MaxTransit AI instead of the NewGRFs")
    args = ap.parse_args()
    out = ROOT / "build" / "bundle"
    out.mkdir(parents=True, exist_ok=True)
    if args.ai:
        bundle_ai(out, args.version)
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
