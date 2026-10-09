#!/usr/bin/env python3
"""Package each NewGRF the way BaNaNaS expects: a tar with the .grf, readme.txt, changelog.txt
and license.txt. Output: build/bundle/<name>-<version>.tar

    python3 tools/bundle.py [--version 0.1.0-alpha]
"""
import argparse
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETS = {"max-air": "docs/bananas/readme_air.txt", "max-rail": "docs/bananas/readme_rail.txt"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=None, help="label for the file names (default: VERSION file)")
    args = ap.parse_args()
    version = args.version or (ROOT / "VERSION").read_text().strip()
    out = ROOT / "build" / "bundle"
    out.mkdir(parents=True, exist_ok=True)
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
