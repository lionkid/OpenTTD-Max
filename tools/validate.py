#!/usr/bin/env python3
"""Sanity-check data/*.csv and gfx/ before building. Exit code 1 on any error."""
from __future__ import annotations

import csv
import json
import re
import sys
from datetime import date
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ottd_palette import DOS  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
AIRCRAFT_SPEED_MAX_KMH = 255 * 8 * 1.609  # property is one byte in units of 8 mph
TRAIN_SPEED_MAX_KMH = 1000                # practical sanity limit, property allows far more
REQUIRED = {
    "aircraft.csv": ["id", "name_en", "manufacturer", "role", "priority", "variant_of", "intro_date", "model_life",
                     "vehicle_life", "speed_kmh", "pax", "mail", "cost_factor", "running_cost_factor", "sound",
                     "length_m", "wingspan_m", "art"],
    "trains.csv": ["id", "name_en", "manufacturer", "kind", "priority", "variant_of", "intro_date", "model_life",
                   "vehicle_life", "cars", "speed_kmh", "power_kw", "weight_t", "te_coeff", "pax_per_car", "tilt",
                   "track", "cost_factor", "running_cost_factor", "car_length_m", "art"],
}
errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def check_common(name: str, r: dict) -> None:
    rid = r["id"]
    if not re.fullmatch(r"[a-z][a-z0-9_]*", rid):
        err(f"{name}: bad id {rid!r}")
    if r["priority"] not in ("P0", "P1", "P2"):
        err(f"{name}:{rid}: priority must be P0/P1/P2")
    try:
        y, m, d = (int(x) for x in r["intro_date"].split("-"))
        date(y, m, d)
    except Exception:
        err(f"{name}:{rid}: bad intro_date {r['intro_date']!r}")
    for col in ("model_life", "vehicle_life"):
        if not r[col].isdigit() or not 0 <= int(r[col]) <= 255:
            err(f"{name}:{rid}: {col} must be 0..255")
    if r.get("game_model_life") and (not r["game_model_life"].isdigit() or not 0 <= int(r["game_model_life"]) <= 255):
        err(f"{name}:{rid}: game_model_life must be empty or 0..255")
    for col in ("cost_factor", "running_cost_factor"):
        try:
            v = float(r[col])
            if not 1 <= round(v * 0.6) <= 255:
                err(f"{name}:{rid}: {col} out of range after scaling")
        except ValueError:
            err(f"{name}:{rid}: {col} not a number")


def check_csv(name: str) -> list[dict]:
    path = ROOT / "data" / name
    with open(path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        missing = [c for c in REQUIRED[name] if c not in (reader.fieldnames or [])]
        if missing:
            err(f"{name}: missing columns {missing}")
            return []
        rows = [r for r in reader if r.get("id")]
    ids = [r["id"] for r in rows]
    for dup in {i for i in ids if ids.count(i) > 1}:
        err(f"{name}: duplicate id {dup}")
    for r in rows:
        check_common(name, r)
        if r["variant_of"] and r["variant_of"] not in ids:
            err(f"{name}:{r['id']}: variant_of unknown id {r['variant_of']!r}")
        if r["variant_of"] == r["id"]:
            err(f"{name}:{r['id']}: variant_of itself")
    return rows


def check_aircraft(rows: list[dict]) -> None:
    for r in rows:
        rid = r["id"]
        if not 0 < float(r["speed_kmh"]) <= AIRCRAFT_SPEED_MAX_KMH:
            err(f"aircraft:{rid}: speed {r['speed_kmh']} exceeds property limit {AIRCRAFT_SPEED_MAX_KMH:.0f} km/h")
        if not 0 <= int(r["pax"]) <= 65535 or not 0 <= int(r["mail"]) <= 255:
            err(f"aircraft:{rid}: pax must be 0..65535 and mail 0..255")
        if r["sound"] not in ("jet", "jet_big", "jet_fast"):
            err(f"aircraft:{rid}: unknown sound {r['sound']!r}")
        for role in r["role"].split("+"):
            if role not in ("passenger", "freighter", "supersonic"):
                err(f"aircraft:{rid}: unknown role {role!r}")


def check_trains(rows: list[dict]) -> None:
    for r in rows:
        rid = r["id"]
        if not 1 <= int(r["cars"]) <= 64:
            err(f"trains:{rid}: cars must be 1..64")
        if not 0 < float(r["speed_kmh"]) <= TRAIN_SPEED_MAX_KMH:
            err(f"trains:{rid}: speed {r['speed_kmh']} outside 1..{TRAIN_SPEED_MAX_KMH} km/h")
        if not 0 < float(r["power_kw"]) * 1.341 <= 65535:
            err(f"trains:{rid}: power exceeds 65535 hp")
        if not 0 < float(r["weight_t"]) <= 65535:
            err(f"trains:{rid}: weight out of range")
        if not 0.05 <= float(r["te_coeff"]) <= 1.0:
            err(f"trains:{rid}: te_coeff should be 0.05..1.0")
        if not 0 <= int(r["pax_per_car"]) <= 255:
            err(f"trains:{rid}: pax_per_car must be 0..255")
        if r["tilt"] not in ("0", "1"):
            err(f"trains:{rid}: tilt must be 0 or 1")
        if r["track"].upper() not in ("HSR", "MGLV", "ELRL"):
            err(f"trains:{rid}: track must be HSR, MGLV or ELRL")
        if r["kind"] not in ("shinkansen", "maglev"):
            err(f"trains:{rid}: unknown kind {r['kind']!r}")


def check_gfx_dir(d: Path) -> None:
    mpath = d / "manifest.json"
    if not mpath.exists():
        err(f"{d}: manifest.json missing")
        return
    m = json.loads(mpath.read_text())
    for part, pdata in m.get("parts", {}).items():
        for zname in ("1x", "2x", "4x"):
            z = pdata["zooms"].get(zname)
            if not z:
                err(f"{d}:{part}: zoom {zname} missing")
                continue
            if len(z["views"]) != 8:
                err(f"{d}:{part}:{zname}: expected 8 views")
            sheet, mask = d / z["sheet"], d / z["mask"]
            if not sheet.exists() or not mask.exists():
                err(f"{d}:{part}:{zname}: sheet or mask file missing")
                continue
            si, mi = Image.open(sheet), Image.open(mask)
            if si.size != mi.size:
                err(f"{d}:{part}:{zname}: mask size {mi.size} != sheet size {si.size}")
            if si.mode != "RGBA":
                err(f"{d}:{part}:{zname}: sheet must be RGBA")
            if mi.mode != "P":
                err(f"{d}:{part}:{zname}: mask must be a paletted PNG")
            for x, y, w, h, _dx, _dy in z["views"]:
                if x + w > si.size[0] or y + h > si.size[1]:
                    err(f"{d}:{part}:{zname}: view outside the sheet")
        fb = d / pdata["zooms"]["1x"].get("fallback_8bpp", "")
        if not fb.is_file():
            err(f"{d}:{part}: 8bpp fallback missing")
        else:
            img = Image.open(fb)
            if img.mode != "P":
                err(f"{fb}: must be a paletted PNG")
            else:
                pal = np.array(img.getpalette()[:768], dtype=np.uint8).reshape(256, 3)
                if not np.array_equal(pal, DOS):
                    err(f"{fb}: palette is not the OpenTTD DOS palette")


def main() -> None:
    aircraft = check_csv("aircraft.csv")
    trains = check_csv("trains.csv")
    check_aircraft(aircraft)
    check_trains(trains)
    gfx = ROOT / "gfx"
    for cat in ("aircraft", "trains"):
        for d in sorted((gfx / cat).glob("*/")) if (gfx / cat).exists() else []:
            check_gfx_dir(d)
        if (gfx / "_placeholder" / cat).exists():
            check_gfx_dir(gfx / "_placeholder" / cat)
    for name, rows, cat in (("aircraft", aircraft, "aircraft"), ("trains", trains, "trains")):
        for r in rows:
            if r["art"] and not (gfx / cat / r["art"] / "manifest.json").exists():
                print(f"validate: note: {name}:{r['id']} has no artwork yet (placeholder will be used)")
    if errors:
        print("\n".join(f"validate: ERROR: {e}" for e in errors))
        raise SystemExit(1)
    print(f"validate: OK ({len(aircraft)} aircraft, {len(trains)} trains)")


if __name__ == "__main__":
    main()
