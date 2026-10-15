#!/usr/bin/env python3
"""Generate NML for every vehicle in data/*.csv and assemble the final .nml files.

    python3 tools/gen_nml.py [--no-badges] [--strict] [--version N]

Outputs:
    build/generated/air_items.pnml, build/generated/rail_items.pnml   per-vehicle NML
    build/max-air.nml, build/max-rail.nml                             assembled sources for nmlc
    build/lang/*.lng                                                  static strings + generated names

The assembler understands three directives in src/*.pnml:
    #include "path"     relative to src/ (or build/ for "generated/...")
    #if BADGES ... #endif
    @VERSION@
Sprite paths are written relative to the repository root; run nmlc from there.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import balance  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
DATA, SRC, GFX, LANG, BUILD = ROOT / "data", ROOT / "src", ROOT / "gfx", ROOT / "lang", ROOT / "build"
LANGS = {"english": "name_en", "traditional_chinese": "name_zh_tw", "japanese": "name_ja"}
ZOOM_CONST = {"1x": "ZOOM_LEVEL_NORMAL", "2x": "ZOOM_LEVEL_IN_2X", "4x": "ZOOM_LEVEL_IN_4X"}
TAIL_ORDER = [4, 5, 6, 7, 0, 1, 2, 3]   # a tail car shows the head car facing the other way
SOUND = {"jet": "SOUND_TAKEOFF_JET", "jet_big": "SOUND_TAKEOFF_JET_BIG", "jet_fast": "SOUND_TAKEOFF_JET_FAST"}
FREIGHT_CLASSES = "bitmask(CC_MAIL, CC_EXPRESS, CC_ARMOURED, CC_PIECE_GOODS, CC_REFRIGERATED)"

# This set's own sounds (sounds/*.wav, synthesised by tools/make_sounds.py) per CSV sound class / train
# kind. They play through the sound_effect callback unless the "sounds" parameter selects the original
# game sounds; then the callback fails and the sound_effect property (an original sound) is used.
TAKEOFF_WAV = {"jet": "jet_takeoff.wav", "jet_big": "jet_takeoff_big.wav", "jet_fast": "concorde_takeoff.wav"}
DEPART_WAV = {"shinkansen": "shinkansen_depart.wav", "maglev": "maglev_depart.wav"}

# Takeoff field length (runway_m) -> airport advice. OpenTTD only distinguishes "small" aircraft (safe at
# every airport) from "large" ones (may crash when landing at the short-strip Small and Commuter airports);
# the tiers above "small" are advice shown in the purchase window, not simulated.
AIRPORT_TIERS = [(2100, "small"), (2700, "city"), (3100, "intl"), (1 << 30, "interc")]
LOAD_STEPS = 8   # a full load takes this many loading steps at the "Standard" loading-speed parameter
ORIGINAL_LOAD = {"air": 20, "rail": 5}   # fixed units per step of the original vehicles ("Original" value)

# Free formations: one dual-headed "head cars" engine and one "intermediate car" wagon per series (per
# artwork). Names, purchase-window text and the attach refusal per language; {name} is the series name.
FREE_TEXT = {
    "english": {
        "head": "{name} head cars", "car": "{name} intermediate car",
        "head_extra": "Two head cars, {seats} seats each. Couple {name} intermediate cars between them "
                      "(full formation: {cars} cars, {tiles} tiles).",
        "car_extra": "Intermediate car, {seats} seats, {power} kW. Couple it between the {name} head cars.",
        "attach": "Only {name} intermediate cars can be coupled",
    },
    "traditional_chinese": {
        "head": "{name}（先頭車 ×2）", "car": "{name}（中間車）",
        "head_extra": "兩節先頭車，各 {seats} 座。在兩節之間加掛{name}中間車（實際編組 {cars} 輛、{tiles} 格）。",
        "car_extra": "中間車，{seats} 座、{power} kW。掛在{name}兩節先頭車之間。",
        "attach": "只能加掛{name}中間車",
    },
    "japanese": {
        "head": "{name}（先頭車×2）", "car": "{name}（中間車）",
        "head_extra": "先頭車2両、各{seats}席。{name}の中間車を2両の間に連結（実際の編成：{cars}両、{tiles}タイル）。",
        "car_extra": "中間車、{seats}席、{power} kW。{name}の先頭車の間に連結します。",
        "attach": "{name}の中間車のみ連結できます",
    },
}

# Purchase-window text (additional_text callback) per language. {} is a newline in NML strings; only the
# "aircraft" and "train" templates go through str.format.
EXTRA_TEXT = {
    "english": {
        "aircraft": "Takeoff runway approx. {runway:,} m. Airports: {tier}.",
        "large": "{}Large aircraft: may crash when landing at Small or Commuter airports.",
        "tiers": {"small": "any, including Small and Commuter", "city": "City or larger",
                  "intl": "International or larger", "interc": "Intercontinental"},
        "train": "{cars} cars, {length_m} m: platform of {tiles} tiles.",
        "tilt": "{}Tilting train: faster through curves.",
    },
    "traditional_chinese": {
        "aircraft": "起飛跑道約 {runway:,} 公尺。適用機場：{tier}。",
        "large": "{}大型機：在小機場、通勤機場降落有墜機風險。",
        "tiers": {"small": "全部（含小機場、通勤機場）", "city": "城市機場以上",
                  "intl": "國際機場以上", "interc": "洲際機場"},
        "train": "{cars} 輛編組，全長 {length_m} 公尺，月台需 {tiles} 格。",
        "tilt": "{}傾斜列車：過彎更快。",
    },
    "japanese": {
        "aircraft": "離陸滑走路 約{runway:,} m。対応空港：{tier}。",
        "large": "{}大型機：小空港・コミューター空港への着陸は墜落の危険があります。",
        "tiers": {"small": "すべて（小空港・コミューター空港を含む）", "city": "都市空港以上",
                  "intl": "国際空港以上", "interc": "大陸間空港"},
        "train": "{cars}両編成、全長 {length_m} m、ホーム {tiles} タイル。",
        "tilt": "{}振り子式：カーブを高速で通過。",
    },
}


def die(msg: str) -> None:
    raise SystemExit(f"gen_nml: {msg}")


def read_csv(name: str) -> list[dict]:
    with open(DATA / name, newline="", encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f) if r.get("id")]
    ids = [r["id"] for r in rows]
    if len(ids) != len(set(ids)):
        die(f"duplicate ids in {name}")
    for r in rows:
        if not re.fullmatch(r"[a-z][a-z0-9_]*", r["id"]):
            die(f"{name}: bad id {r['id']!r}")
        if r.get("variant_of") and r["variant_of"] not in ids:
            die(f"{name}: {r['id']} variant_of unknown id {r['variant_of']!r}")
    return rows


def manifest_for(category: str, art: str, strict: bool, missing: list[str]) -> tuple[dict, str]:
    """Return (manifest, gfx dir relative to repo root), falling back to the placeholder art."""
    if art:
        d = GFX / category / art
        if (d / "manifest.json").exists():
            return json.loads((d / "manifest.json").read_text()), f"gfx/{category}/{art}"
        if strict:
            die(f"missing artwork {d}")
        missing.append(art)
    d = GFX / "_placeholder" / category
    if not (d / "manifest.json").exists():
        die("placeholder art missing: run tools/make_placeholder_gfx.py")
    return json.loads((d / "manifest.json").read_text()), f"gfx/_placeholder/{category}"


def spriteset_blocks(name: str, part: dict, gfx_rel: str, order: list[int] | None = None) -> list[str]:
    order = order or list(range(8))
    out = []
    z1 = part["zooms"]["1x"]

    def views(z: dict) -> list[str]:
        return [f"    [{', '.join(str(n) for n in z['views'][k])}]" for k in order]

    out.append(f'spriteset({name}, "{gfx_rel}/{z1["fallback_8bpp"]}") {{')
    out += views(z1)
    out.append("}")
    for zname, const in ZOOM_CONST.items():
        z = part["zooms"][zname]
        out.append(f'alternative_sprites({name}, {const}, BIT_DEPTH_32BPP, "{gfx_rel}/{z["sheet"]}", "{gfx_rel}/{z["mask"]}") {{')
        out += views(z)
        out.append("}")
    return out


def nml_date(s: str) -> str:
    y, m, d = (int(x) for x in s.split("-"))
    return f"date({y}, {m}, {d})"


MIN_MODEL_LIFE = 8   # years a model stays on sale in game at least, even if it was built for less (Concorde: 3)


def life(v: str) -> str:
    return "VEHICLE_NEVER_EXPIRES" if int(v) == 0 else str(max(int(v), MIN_MODEL_LIFE))


# OpenTTD keeps an engine on sale for model_life + phase 1 (0.6-3.2 y) + phase 3 (10-20.6 y). Retiring
# 8 years "early" (negative = after the end of phase 2) cuts most of phase 3, so the on-sale window is
# model_life + about 0.6-4.4 years, close to the real production span (see docs/TIMELINE.md).
RETIRE_EARLY = -8


def model_life(r: dict) -> str:
    """In-game model life: the optional game_model_life override, else the real production years."""
    return life(r.get("game_model_life") or r["model_life"])




def car_units(r: dict) -> int:
    """In-game length of one car (1..8 units); 25 m = 8/8."""
    return max(1, min(8, round(float(r["car_length_m"]) / 25.0 * 8)))


def badge_list(*labels: str) -> str:
    return "[" + ", ".join(f'"{x}"' for x in labels if x) + "]"


def load_units(capacity: int) -> int:
    """loading_speed property: units per loading step so that a full load takes LOAD_STEPS steps."""
    return max(1, min(255, math.ceil(capacity / LOAD_STEPS)))


def airport_tier(r: dict) -> str:
    """Airport advice tier of an aircraft: from runway_m, unless airport_class overrides small / large."""
    runway = int(r["runway_m"])
    tier = next(t for limit, t in AIRPORT_TIERS if runway <= limit)
    cls = r.get("airport_class") or ""
    if cls == "small":
        return "small"
    if cls == "large":
        return "city" if tier == "small" else tier
    if cls:
        die(f"{r['id']}: airport_class must be small or large, not {cls!r}")
    return tier


def train_tiles(r: dict) -> int:
    """Platform tiles a formation needs: a tile is 16 length units, a 25 m car takes 8 of them."""
    return math.ceil(int(r["cars"]) * car_units(r) / 16)


def extra_text(lang: str, r: dict, category: str) -> str:
    """Purchase-window text for one vehicle in one language."""
    t = EXTRA_TEXT[lang]
    if category == "aircraft":
        tier = airport_tier(r)
        text = t["aircraft"].format(runway=round(int(r["runway_m"]) / 50) * 50, tier=t["tiers"][tier])
        return text + (t["large"] if tier != "small" else "")
    cars = int(r["cars"])
    text = t["train"].format(cars=cars, length_m=round(cars * float(r["car_length_m"])), tiles=train_tiles(r))
    return text + (t["tilt"] if r.get("tilt") == "1" else "")


def series(rows: list[dict]) -> list[dict]:
    """The first formation of each series (one per artwork): the basis of its free-formation items."""
    seen: set[str] = set()
    out = []
    for r in rows:
        key = r.get("art") or r["id"]
        if key not in seen:
            seen.add(key)
            out.append(r)
    return out


def per_car(r: dict) -> tuple[int, int]:
    """Power (kW) and weight (t) of one car of a formation."""
    cars = int(r["cars"])
    return max(1, round(int(r["power_kw"]) / cars)), max(1, round(int(r["weight_t"]) / cars))


def free_text(lang: str, r: dict, key: str) -> str:
    name = r.get(LANGS[lang]) or r["name_en"]
    power, _ = per_car(r)
    return FREE_TEXT[lang][key].format(name=name, seats=int(r["pax_per_car"]), power=power,
                                       cars=int(r["cars"]), tiles=train_tiles(r))


def loading_switch(feature: str, prefix: str, original: int) -> list[str]:
    """Callback 36 for loading_speed: units per loading step, chosen by the loading-speed parameter."""
    return [
        "// Loading speed per loading step (callback 36) from the GRF parameter; 0 = Standard.",
        f"switch ({feature}, SELF, sw_{prefix}_loading_speed, param_loading) {{",
        "    1: return min(255, (cargo_capacity + 3) / 4);",
        "    2: return min(255, (cargo_capacity + 1) / 2);",
        f"    3: return {original};",
        f"    return min(255, (cargo_capacity + {LOAD_STEPS - 1}) / {LOAD_STEPS});",
        "}",
    ]


def sound_switch(feature: str, name: str, events: dict[str, tuple[str, int]]) -> list[str]:
    """sound_effect callback: this set's sounds unless the sounds parameter asks for the original ones.

    Parameter value 0 selects this set's sounds so that savegames made before the parameter existed
    (where it reads as 0) get them too."""
    out = [f"switch ({feature}, SELF, {name}_events, extra_callback_info1) {{"]
    out += [f'    {event}: return sound("sounds/{wav}", {volume});' for event, (wav, volume) in events.items()]
    out += ["    CB_FAILED;", "}",
            f"switch ({feature}, SELF, {name}, param_sounds) {{", f"    0: {name}_events;", "    CB_FAILED;", "}"]
    return out


# ---------------------------------------------------------------------------------------------
# Aircraft
# ---------------------------------------------------------------------------------------------
def gen_aircraft(rows: list[dict], badges: bool, strict: bool, missing: list[str]) -> str:
    out = ["// Generated by tools/gen_nml.py from data/aircraft.csv. Do not edit.", ""]
    out += loading_switch("FEAT_AIRCRAFT", "air", ORIGINAL_LOAD["air"])
    for cls, wav in TAKEOFF_WAV.items():
        out += sound_switch("FEAT_AIRCRAFT", f"sw_air_sound_{cls}",
                            {"SOUND_EVENT_START": (wav, 100), "SOUND_EVENT_TOUCHDOWN": ("touchdown.wav", 80)})
    for r in rows:
        rid = r["id"]
        manifest, gfx_rel = manifest_for("aircraft", r.get("art", ""), strict, missing)
        tier = airport_tier(r)
        part = manifest["parts"].get("body") or next(iter(manifest["parts"].values()))
        roles = r["role"].split("+")
        freighter = "freighter" in roles
        supersonic = "supersonic" in roles
        out.append(f"\n// ---- {r['name_en']} ----")
        out += spriteset_blocks(f"ss_{rid}", part, gfx_rel)
        payload = float(r.get("payload_t") or 0)
        capacity = round(payload * 4) if freighter else int(r["pax"])   # freighters: mail bags of 1/4 t
        if freighter:
            if payload <= 0:
                die(f"{rid}: freighter without payload_t")
            # Capacity in cargo units = tonnes / unit weight (cargo_unit_weight is in 1/16 t).
            out += [f"switch (FEAT_AIRCRAFT, SELF, sw_{rid}_capacity, {round(payload * 16)} / max(cargo_unit_weight, 1)) {{",
                    "    return;", "}"]
        props = [
            f"name: string(STR_NAME_{rid.upper()});",
            "climates_available: ALL_CLIMATES;",
            f"introduction_date: {nml_date(r['intro_date'])};",
            f"model_life: {model_life(r)};",
            f"retire_early: {RETIRE_EARLY if model_life(r) != 'VEHICLE_NEVER_EXPIRES' else 0};",
            f"vehicle_life: {int(r['vehicle_life'])};",
            "reliability_decay: 20;",
            "sprite_id: SPRITE_ID_NEW_AIRCRAFT;",
            f"aircraft_type: {'AIRCRAFT_TYPE_SMALL' if tier == 'small' else 'AIRCRAFT_TYPE_LARGE'};",
            f"cost_factor: {balance.aircraft_props(r)[0]};",
            f"running_cost_factor: {balance.aircraft_props(r)[1]};",
            f"speed: {int(r['speed_kmh'])} km/h;",
            f"acceleration: {90 if supersonic else 60};",
            f"passenger_capacity: {capacity};",
            f"mail_capacity: {0 if freighter else int(r['mail'])};",
            f"loading_speed: {load_units(capacity)};",   # fallback when the loading-speed callback is not used
            f"sound_effect: {SOUND[r['sound']]};",
            "range: 0;",
        ]
        if freighter:
            # Capacity for non-passenger cargo derives from passenger_capacity via the cargo
            # multipliers; the CSV stores tonnes. Balanced in M1.
            props += [
                f"refittable_cargo_classes: {FREIGHT_CLASSES};",
                "non_refittable_cargo_classes: bitmask(CC_PASSENGERS);",
            ]  # OpenTTD falls back to the first refittable cargo when passengers are excluded
        else:
            props += [
                "refittable_cargo_classes: bitmask(CC_PASSENGERS, CC_MAIL);",
                "non_refittable_cargo_classes: NO_CARGO_CLASS;",
            ]
        props.append("misc_flags: bitmask(AIRCRAFT_FLAG_2CC);")
        if r.get("variant_of"):
            # Purchase-list grouping only. Do not sync reliability: that makes a variant age with its
            # parent, so a 1998 737-800 would retire together with the 1968 737-200.
            props.append(f"variant_group: {r['variant_of']};")
        if badges:
            props.append("badges: " + badge_list(f"manufacturer/{r['manufacturer']}", *[f"role/{x}" for x in roles]) + ";")
        out.append(f"item(FEAT_AIRCRAFT, {rid}) {{")
        out.append("    property {")
        out += [f"        {p}" for p in props]
        out.append("    }")
        gfx = ["loading_speed: sw_air_loading_speed;", f"sound_effect: sw_air_sound_{r['sound']};",
               f"additional_text: string(STR_EXTRA_{rid.upper()});"]
        if freighter:
            gfx.append(f"passenger_capacity: sw_{rid}_capacity;")
        gfx.append(f"ss_{rid};")
        out.append("    graphics { " + " ".join(gfx) + " }")
        out.append("}")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------------------------
# Trains
# ---------------------------------------------------------------------------------------------
def gen_trains(rows: list[dict], badges: bool, strict: bool, missing: list[str]) -> str:
    out = ["// Generated by tools/gen_nml.py from data/trains.csv. Do not edit.", ""]
    out += loading_switch("FEAT_TRAINS", "rail", ORIGINAL_LOAD["rail"])
    for kind, wav in DEPART_WAV.items():
        out += sound_switch("FEAT_TRAINS", f"sw_rail_sound_{kind}", {"SOUND_EVENT_START": (wav, 100)})
    fixed: list[str] = []    # complete formations, one purchase each (articulated)
    free: list[str] = []     # head cars + intermediate cars per series
    links: list[str] = []    # head cars as a purchase-list variant of the fixed formation
    free_series = {r["id"] for r in series(rows)}
    for r in rows:
        rid = r["id"]
        if r["kind"] not in DEPART_WAV:
            die(f"{rid}: unknown kind {r['kind']!r}")
        manifest, gfx_rel = manifest_for("trains", r.get("art", ""), strict, missing)
        parts = manifest["parts"]
        cars = int(r["cars"])
        maglev = r["track"].upper() == "MGLV"
        units = car_units(r)
        for pname, pdata in parts.items():
            if pdata.get("units") not in (None, units) and "_placeholder" not in gfx_rel:
                die(f"{rid}: art part {pname} rendered for length {pdata['units']}/8 but car_length_m gives {units}/8")
        out.append(f"\n// ---- {r['name_en']} ({cars} cars) ----")
        if "head" in parts:
            head = parts["head"]
            mid = parts.get("mid", head)
            out += spriteset_blocks(f"ss_{rid}_head", head, gfx_rel)
            out += spriteset_blocks(f"ss_{rid}_mid", mid, gfx_rel)
            out += spriteset_blocks(f"ss_{rid}_tail", head, gfx_rel, TAIL_ORDER)
            mid_ref = f"ss_{rid}_mid"
            if "mid_p" in parts:
                # Pantograph on every other intermediate car.
                out += spriteset_blocks(f"ss_{rid}_mid_p", parts["mid_p"], gfx_rel)
                out += [f"switch (FEAT_TRAINS, SELF, sw_{rid}_gfx_mid, position_in_articulated_veh % 2) {{",
                        f"    1: ss_{rid}_mid_p;", f"    ss_{rid}_mid;", "}"]
                mid_ref = f"sw_{rid}_gfx_mid"
            out += [
                f"switch (FEAT_TRAINS, SELF, sw_{rid}_gfx_rear, position_in_articulated_veh_from_end) {{",
                f"    0: ss_{rid}_tail;",
                f"    {mid_ref};",
                "}",
                f"switch (FEAT_TRAINS, SELF, sw_{rid}_gfx, position_in_articulated_veh) {{",
                f"    0: ss_{rid}_head;",
                f"    sw_{rid}_gfx_rear;",
                "}",
            ]
            gfx_ref = f"sw_{rid}_gfx"
            head_ref, car_ref, car_p_ref = f"ss_{rid}_head", f"ss_{rid}_mid", (f"ss_{rid}_mid_p" if "mid_p" in parts else "")
        else:
            body = parts.get("body") or next(iter(parts.values()))
            out += spriteset_blocks(f"ss_{rid}", body, gfx_rel)
            gfx_ref = f"ss_{rid}"
            head_ref, car_ref, car_p_ref = f"ss_{rid}", f"ss_{rid}", ""
        if cars > 1:
            out += [
                f"switch (FEAT_TRAINS, SELF, sw_{rid}_artic, extra_callback_info1) {{",
                f"    1..{cars - 1}: return {rid};",
                "    return CB_RESULT_NO_MORE_ARTICULATED_PARTS;",
                "}",
            ]
        flags = ["TRAIN_FLAG_MU", "TRAIN_FLAG_2CC"] + (["TRAIN_FLAG_TILT"] if r.get("tilt") == "1" else [])
        props = [
            f"name: string(STR_NAME_{rid.upper()});",
            "climates_available: ALL_CLIMATES;",
            f"introduction_date: {nml_date(r['intro_date'])};",
            f"model_life: {model_life(r)};",
            f"retire_early: {RETIRE_EARLY if model_life(r) != 'VEHICLE_NEVER_EXPIRES' else 0};",
            f"vehicle_life: {int(r['vehicle_life'])};",
            "reliability_decay: 20;",
            "sprite_id: SPRITE_ID_NEW_TRAIN;",
            f"track_type: {r['track'].upper()};",
            f"engine_class: {'ENGINE_CLASS_MAGLEV' if maglev else 'ENGINE_CLASS_ELECTRIC'};",
            "running_cost_base: RUNNING_COST_ELECTRIC;",
            f"speed: {int(r['speed_kmh'])} km/h;",
            f"power: {int(r['power_kw'])} kW;",
            f"weight: {int(r['weight_t'])} ton;",           # whole consist: only the lead part adds vehicle weight
            f"tractive_effort_coefficient: {float(r['te_coeff'])};",
            f"length: {units};",
            "dual_headed: 0;",
            f"cargo_capacity: {int(r['pax_per_car'])};",     # per car: every articulated part gets this
            f"loading_speed: {load_units(int(r['pax_per_car']))};",   # per car; fallback for the callback
            f"cost_factor: {balance.train_props(r)[0]};",
            f"running_cost_factor: {balance.train_props(r)[1]};",
            "refittable_cargo_classes: bitmask(CC_PASSENGERS);",
            "non_refittable_cargo_classes: NO_CARGO_CLASS;",
            f"misc_flags: bitmask({', '.join(flags)});",
            "visual_effect_and_powered: visual_effect_and_powered(VISUAL_EFFECT_DISABLE, 0, DISABLE_WAGON_POWER);",
        ]
        if r.get("variant_of"):
            # Purchase-list grouping only. Do not sync reliability: that makes a variant age with its
            # parent, so a 1998 737-800 would retire together with the 1968 737-200.
            props.append(f"variant_group: {r['variant_of']};")
        if badges:
            props.append("badges: " + badge_list(f"manufacturer/{r['manufacturer']}", f"kind/{r['kind']}") + ";")
        fixed.append(f"\n// ---- {r['name_en']} ({cars} cars) ----")
        fixed.append(f"item(FEAT_TRAINS, {rid}) {{")
        fixed.append("    property {")
        fixed += [f"        {p}" for p in props]
        fixed.append("    }")
        gfx = [f"articulated_part: sw_{rid}_artic;"] if cars > 1 else []
        gfx += ["loading_speed: sw_rail_loading_speed;", f"sound_effect: sw_rail_sound_{r['kind']};",
                f"additional_text: string(STR_EXTRA_{rid.upper()});", f"{gfx_ref};"]
        fixed.append("    graphics { " + " ".join(gfx) + " }")
        fixed.append("}")
        if rid in free_series:
            switches, items = gen_free_train(r, badges, flags, head_ref, car_ref, car_p_ref)
            out += switches
            free += items
            links += [f"item(FEAT_TRAINS, {rid}_head) {{ property {{ variant_group: {rid}; }} }}"]
    out += ["", "// Fixed formations: one purchase buys the whole articulated train (parameter: formations).",
            "if (param_formation != 2) {"] + fixed + ["}", "",
            "// Free formations: dual-headed head cars plus intermediate cars as wagons (parameter: formations).",
            "if (param_formation != 1) {"] + free + ["}", "",
            "// With both kinds on sale, the head cars are listed as a variant of the fixed formation.",
            "if (param_formation == 0) {"] + links + ["}"]
    return "\n".join(out) + "\n"


def gen_free_train(r: dict, badges: bool, flags: list[str], head_ref: str, car_ref: str,
                   car_p_ref: str) -> tuple[list[str], list[str]]:
    """Head cars (dual-headed engine, both ends drawn from the head sprites) and the intermediate car
    (a powered wagon: the livery override marks it powered, extra_power_per_wagon adds its power).
    Returns (switch blocks, item blocks): NML allows no switch inside a conditional block."""
    rid = r["id"]
    units = car_units(r)
    power, weight = per_car(r)
    costs = balance.free_train_props(r)
    common = [
        "climates_available: ALL_CLIMATES;",
        f"introduction_date: {nml_date(r['intro_date'])};",
        f"model_life: {model_life(r)};",
        f"retire_early: {RETIRE_EARLY if model_life(r) != 'VEHICLE_NEVER_EXPIRES' else 0};",
        f"vehicle_life: {int(r['vehicle_life'])};",
        "reliability_decay: 20;",
        "sprite_id: SPRITE_ID_NEW_TRAIN;",
        f"track_type: {r['track'].upper()};",
        "running_cost_base: RUNNING_COST_ELECTRIC;",
        f"speed: {int(r['speed_kmh'])} km/h;",
        f"weight: {weight} ton;",
        f"tractive_effort_coefficient: {float(r['te_coeff'])};",
        f"length: {units};",
        f"cargo_capacity: {int(r['pax_per_car'])};",
        f"loading_speed: {load_units(int(r['pax_per_car']))};",
        "refittable_cargo_classes: bitmask(CC_PASSENGERS);",
        "non_refittable_cargo_classes: NO_CARGO_CLASS;",
        f"misc_flags: bitmask({', '.join(flags)});",
    ]
    badge = ["badges: " + badge_list(f"manufacturer/{r['manufacturer']}", f"kind/{r['kind']}") + ";"] if badges else []
    switches: list[str] = []
    if car_p_ref:
        # Pantograph on every other car, counted from the front head car.
        switches += [f"switch (FEAT_TRAINS, SELF, sw_{rid}_car_gfx, position_in_consist % 2) {{",
                     f"    1: {car_p_ref};", f"    {car_ref};", "}"]
        car_ref = f"sw_{rid}_car_gfx"
    switches += [f"switch (FEAT_TRAINS, SELF, sw_{rid}_attach, vehicle_type_id) {{",
                 f"    {rid}_car: return CB_RESULT_ATTACH_ALLOW;",
                 f"    return string(STR_ATTACH_{rid.upper()});", "}"]
    out = [f"\n// ---- {r['name_en']}: head cars + intermediate car ----"]
    out += [f"item(FEAT_TRAINS, {rid}_car) {{", "    property {"]
    out += [f"        {p}" for p in [f"name: string(STR_NAME_{rid.upper()}_CAR);"] + common + [
        "power: 0 kW;",
        f"cost_factor: {costs['car_cost']};",
        f"running_cost_factor: {costs['car_run']};",
        "visual_effect_and_powered: visual_effect_and_powered(VISUAL_EFFECT_DISABLE, 0, ENABLE_WAGON_POWER);",
    ] + badge]
    out += ["    }", "    graphics { loading_speed: sw_rail_loading_speed; "
            f"additional_text: string(STR_EXTRA_{rid.upper()}_CAR); {car_ref}; }}", "}"]
    out += [f"item(FEAT_TRAINS, {rid}_head) {{", "    property {"]
    out += [f"        {p}" for p in [f"name: string(STR_NAME_{rid.upper()}_HEAD);"] + common + [
        f"engine_class: {'ENGINE_CLASS_MAGLEV' if r['track'].upper() == 'MGLV' else 'ENGINE_CLASS_ELECTRIC'};",
        f"power: {2 * power} kW;",                  # both head cars: the rear part of a dual-headed engine adds none
        f"extra_power_per_wagon: {power} kW;",
        "dual_headed: 1;",
        f"cost_factor: {costs['head_cost']};",
        f"running_cost_factor: {costs['head_run']};",
        "visual_effect_and_powered: visual_effect_and_powered(VISUAL_EFFECT_DISABLE, 0, DISABLE_WAGON_POWER);",
    ] + badge]
    out += ["    }",
            f"    graphics {{ can_attach_wagon: sw_{rid}_attach; loading_speed: sw_rail_loading_speed; "
            f"sound_effect: sw_rail_sound_{r['kind']}; additional_text: string(STR_EXTRA_{rid.upper()}_HEAD); {head_ref}; }}",
            f"    livery_override({rid}_car) {{ {car_ref}; }}", "}"]
    return switches, out


# ---------------------------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------------------------
def assemble(src: Path, badges: bool, version: int) -> str:
    out = []
    skipping = False
    for line in src.read_text(encoding="utf-8").splitlines():
        s = line.strip()
        if s.startswith("#if "):
            cond = s.split(None, 1)[1]
            if cond != "BADGES":
                die(f"{src}: unknown condition {cond!r}")
            skipping = not badges
            continue
        if s == "#endif":
            skipping = False
            continue
        if skipping:
            continue
        m = re.fullmatch(r'#include\s+"([^"]+)"', s)
        if m:
            rel = m.group(1)
            path = (BUILD / rel) if rel.startswith("generated/") else (SRC / rel)
            out.append(f"// >>> {rel}")
            out.append(path.read_text(encoding="utf-8").rstrip("\n"))
            out.append(f"// <<< {rel}")
            continue
        out.append(line.replace("@VERSION@", str(version)))
    return "\n".join(out) + "\n"


def write_langs(aircraft: list[dict], trains: list[dict]) -> None:
    (BUILD / "lang").mkdir(parents=True, exist_ok=True)
    for lang, col in LANGS.items():
        static = (LANG / f"{lang}.lng").read_text(encoding="utf-8").rstrip("\n")
        lines = [static, "", "# ---- vehicle names (generated from data/*.csv) ----"]
        for r in aircraft + trains:
            name = r.get(col) or r["name_en"]
            lines.append(f"STR_NAME_{r['id'].upper():<28}:{name}")
        lines += ["", "# ---- purchase-window text (generated) ----"]
        for category, rows in (("aircraft", aircraft), ("trains", trains)):
            for r in rows:
                lines.append(f"STR_EXTRA_{r['id'].upper():<27}:{extra_text(lang, r, category)}")
        lines += ["", "# ---- free formations (generated) ----"]
        for r in series(trains):
            rid = r["id"].upper()
            lines += [f"STR_NAME_{rid + '_HEAD':<28}:{free_text(lang, r, 'head')}",
                      f"STR_NAME_{rid + '_CAR':<28}:{free_text(lang, r, 'car')}",
                      f"STR_EXTRA_{rid + '_HEAD':<27}:{free_text(lang, r, 'head_extra')}",
                      f"STR_EXTRA_{rid + '_CAR':<27}:{free_text(lang, r, 'car_extra')}",
                      f"STR_ATTACH_{rid:<26}:{free_text(lang, r, 'attach')}"]
        (BUILD / "lang" / f"{lang}.lng").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-badges", action="store_true", help="omit badges (OpenTTD < 15)")
    ap.add_argument("--strict", action="store_true", help="fail when a vehicle's artwork is missing")
    ap.add_argument("--version", type=int, default=int((ROOT / "VERSION").read_text().strip()))
    args = ap.parse_args()
    badges = not args.no_badges

    aircraft = read_csv("aircraft.csv")
    trains = read_csv("trains.csv")
    missing: list[str] = []
    (BUILD / "generated").mkdir(parents=True, exist_ok=True)
    (BUILD / "generated" / "air_items.pnml").write_text(gen_aircraft(aircraft, badges, args.strict, missing), encoding="utf-8")
    (BUILD / "generated" / "rail_items.pnml").write_text(gen_trains(trains, badges, args.strict, missing), encoding="utf-8")
    (BUILD / "max-air.nml").write_text(assemble(SRC / "air.pnml", badges, args.version), encoding="utf-8")
    (BUILD / "max-rail.nml").write_text(assemble(SRC / "rail.pnml", badges, args.version), encoding="utf-8")
    write_langs(aircraft, trains)
    placeholders = sum(1 for r in aircraft + trains if not r.get("art") or r["art"] in missing)
    print(f"gen_nml: {len(aircraft)} aircraft, {len(trains)} trains, badges={'on' if badges else 'off'}, "
          f"placeholder art for {placeholders} vehicles", file=sys.stderr)
    if missing:
        print("gen_nml: artwork not found for: " + ", ".join(sorted(set(missing))), file=sys.stderr)


if __name__ == "__main__":
    main()
