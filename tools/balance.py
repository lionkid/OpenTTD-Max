#!/usr/bin/env python3
"""Cost balance for OpenTTD-Max: target purchase price and running cost per vehicle, converted to the
one-byte NewGRF properties. tools/gen_nml.py calls aircraft_props() / train_props(); run this file to
write docs/BALANCE.md, which compares every vehicle with the original OpenTTD vehicles.

    python3 tools/balance.py [--engines build/qa_bal/engines.txt]

Money is in-game pounds at default base costs with inflation off. The conversion constants were
measured in OpenTTD 15.3 (tools/ingame/run.py --never-expire dump): property value x constant = price.

Design (M4):
* Aircraft are priced like the original jets per seat (original 1960-2040 jets: about 150-350 GBP per
  seat and 17-40 GBP per seat per year), with economies of scale for large aircraft, a small premium for
  newer designs and better fuel efficiency for them. Supersonic aircraft cost 4.5x to buy and 2.5x to run.
* Trains carry their real seating (about twice an original carriage per tile), so the price per seat is
  set below the original high-speed sets while the running cost per train sits at the level of an
  original electric locomotive with its carriages. Maglev costs up to 1.6x (scaled by speed).
* Freighters count 3.2 seats per tonne of payload.
* The CSV columns price_adj / running_adj (default 1.0) fine-tune individual vehicles.
"""
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Measured conversion: GBP per unit of the one-byte property (OpenTTD 15.3, default base costs).
AIR_PRICE_UNIT = 2050.8      # cost_factor
AIR_RUN_UNIT = 28.12         # running_cost_factor
TRAIN_PRICE_UNIT = 1171.9    # cost_factor
TRAIN_RUN_UNIT = 14.05       # running_cost_factor with running_cost_base RUNNING_COST_ELECTRIC

SEATS_PER_TONNE = 3.2


def _year(r: dict) -> int:
    return int(r["intro_date"][:4])


def _f(r: dict, col: str, default: float = 1.0) -> float:
    v = (r.get(col) or "").strip()
    return float(v) if v else default


def _clamp_prop(value: float, unit: float) -> int:
    return int(max(1, min(255, round(value / unit))))


# ---------------------------------------------------------------------------------------------
# Aircraft
# ---------------------------------------------------------------------------------------------
def aircraft_seats(r: dict) -> float:
    if "freighter" in r["role"].split("+"):
        return float(r["payload_t"]) * SEATS_PER_TONNE
    return float(r["pax"])


def aircraft_targets(r: dict) -> tuple[float, float]:
    seats = aircraft_seats(r)
    year = _year(r)
    supersonic = "supersonic" in r["role"].split("+")
    era_price = 0.9 + 0.005 * (year - 1960)
    efficiency = min(1.3, max(0.8, 1.25 - 0.008 * (year - 1960)))
    price = 520.0 * seats ** 0.85 * era_price * (4.5 if supersonic else 1.0)
    running = (900.0 + 11.5 * seats) * efficiency * (2.5 if supersonic else 1.0)
    return price * _f(r, "price_adj"), running * _f(r, "running_adj")


def aircraft_props(r: dict) -> tuple[int, int]:
    price, running = aircraft_targets(r)
    return _clamp_prop(price, AIR_PRICE_UNIT), _clamp_prop(running, AIR_RUN_UNIT)


# ---------------------------------------------------------------------------------------------
# Trains
# ---------------------------------------------------------------------------------------------
def train_seats(r: dict) -> float:
    return float(r["pax_per_car"]) * int(r["cars"])


def train_targets(r: dict) -> tuple[float, float]:
    seats = train_seats(r)
    year = _year(r)
    speed_factor = (float(r["speed_kmh"]) / 250.0) ** 0.5
    maglev = r["track"].upper() == "MGLV"
    era = min(1.15, max(0.9, 0.9 + 0.004 * (year - 1964)))
    # Maglev premium grows with speed: low-speed urban maglevs (Linimo) are barely dearer than rail.
    mag = 1.0 + 0.6 * min(1.0, float(r["speed_kmh"]) / 400.0) if maglev else 1.0
    price = 95.0 * seats * speed_factor * era * mag
    running = (1200.0 + 1.4 * seats * speed_factor) * mag
    return price * _f(r, "price_adj"), running * _f(r, "running_adj")


def train_props(r: dict) -> tuple[int, int]:
    price, running = train_targets(r)
    return _clamp_prop(price, TRAIN_PRICE_UNIT), _clamp_prop(running, TRAIN_RUN_UNIT)


# Free formations: the two head cars are one dual-headed engine priced at HEAD_PRICE_SHARE of the full
# formation; intermediate cars are wagons, whose price OpenTTD caps at 255 wagon units (base price 2,000,
# i.e. about 1,500 GBP at the default "low" vehicle costs), so they are cheap like every wagon in the game.
HEAD_PRICE_SHARE = 0.6
WAGON_PRICE_UNIT = 2000 * 0.75 / 256   # cost_factor unit of a wagon


def free_train_props(r: dict) -> dict[str, int]:
    """cost / running_cost factors for the head-car engine and the intermediate-car wagon of a series."""
    price, running = train_targets(r)
    cars = int(r["cars"])
    return {
        "head_cost": _clamp_prop(price * HEAD_PRICE_SHARE, TRAIN_PRICE_UNIT),
        "head_run": _clamp_prop(running * 2 / cars, TRAIN_RUN_UNIT),
        "car_cost": _clamp_prop(price / cars, WAGON_PRICE_UNIT),
        "car_run": _clamp_prop(running / cars, TRAIN_RUN_UNIT),
    }


# ---------------------------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------------------------
def read_originals(path: Path) -> list[dict]:
    """Original vehicles from an engine dump (tools/ingame AI 'engine' lines)."""
    out = []
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 9:
            continue
        kind, name = parts[0], parts[1]
        if re.search(r"Boeing|Airbus|Aerospatiale|Shinkansen|Maglev|Transrapid|Linimo|Beijing|Doctor|L0 Series|SCMaglev|CRRC|Max", name):
            continue
        vals = {k: v for k, v in (p.split(" ", 1) for p in parts[2:] if " " in p)}
        cap = vals.get("capacity", "-1").split()[0]
        out.append({"kind": kind, "name": name, "speed": int(vals["speed"]), "capacity": int(cap),
                    "price": int(vals["price"]), "running": int(vals["running"]), "intro": int(vals["intro"])})
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--engines", default=str(ROOT / "build" / "qa_bal" / "engines.txt"))
    ap.add_argument("--out", default=str(ROOT / "docs" / "BALANCE.md"))
    args = ap.parse_args()
    air = list(csv.DictReader(open(ROOT / "data" / "aircraft.csv", encoding="utf-8")))
    rail = list(csv.DictReader(open(ROOT / "data" / "trains.csv", encoding="utf-8")))
    lines = ["# Balance (generated by tools/balance.py)", "",
             "In-game pounds, default base costs, inflation off. Price and running cost are the values the",
             "one-byte NewGRF properties produce after rounding.", ""]

    lines += ["## Aircraft", "", "| Vehicle | Year | Seats | km/h | Price | per seat | Running / yr | per seat |",
              "|---|---|---|---|---|---|---|---|"]
    for r in sorted(air, key=_year):
        cp, rp = aircraft_props(r)
        seats = aircraft_seats(r)
        price, run = cp * AIR_PRICE_UNIT, rp * AIR_RUN_UNIT
        tag = " (t x 3.2)" if "freighter" in r["role"] else ""
        lines.append(f"| {r['name_en']} | {_year(r)} | {seats:.0f}{tag} | {r['speed_kmh']} | {price:,.0f} | {price / seats:,.0f} "
                     f"| {run:,.0f} | {run / seats:,.1f} |")

    lines += ["", "## Trains", "", "| Vehicle | Year | Seats | km/h | Price | per seat | Running / yr | per seat |",
              "|---|---|---|---|---|---|---|---|"]
    for r in sorted(rail, key=_year):
        cp, rp = train_props(r)
        seats = train_seats(r)
        price, run = cp * TRAIN_PRICE_UNIT, rp * TRAIN_RUN_UNIT
        lines.append(f"| {r['name_en']} | {_year(r)} | {seats:.0f} | {r['speed_kmh']} | {price:,.0f} | {price / seats:,.0f} "
                     f"| {run:,.0f} | {run / seats:,.2f} |")

    orig = read_originals(Path(args.engines))
    if orig:
        lines += ["", "## Original vehicles for comparison (measured)", "",
                  "| Vehicle | Type | Year | Capacity | km/h | Price | per seat | Running / yr | per seat |",
                  "|---|---|---|---|---|---|---|---|---|"]
        for o in sorted(orig, key=lambda o: (o["kind"], o["intro"])):
            if o["kind"] == "rail" and o["speed"] < 150:
                continue
            per = f"{o['price'] / o['capacity']:,.0f}" if o["capacity"] > 0 else "–"
            rper = f"{o['running'] / o['capacity']:,.1f}" if o["capacity"] > 0 else "–"
            cap = o["capacity"] if o["capacity"] > 0 else "loco"
            lines.append(f"| {o['name']} | {o['kind']} | {o['intro']} | {cap} | {o['speed']} | {o['price']:,} | {per} "
                         f"| {o['running']:,} | {rper} |")
        lines += ["", "Original passenger carriages: 40-47 seats for about 1,450 GBP each, so an original high-speed",
                  "train of one electric locomotive and 8 carriages (about 360 seats) costs 60,000-82,000 GBP and runs",
                  "for about 3,400 GBP a year plus the carriages."]
    Path(args.out).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {Path(args.out).relative_to(ROOT)}")


if __name__ == "__main__":
    main()
