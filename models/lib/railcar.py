"""Parametric high-speed train / maglev car generator.

build_car(spec, kind) returns the objects of one car; kind is "head" (nose towards +X) or "mid".
Positions along the car are given as `s`, the distance from the front end (nose tip for a head car);
the car is centred on the origin, rail top / guideway top is z = 0.

Nose shape is defined by control points over t = s / nose_length (0 at the tip, 1 where the
constant body section starts), interpolated with monotone cubics:
    "top":    [(t, z of the upper surface)]
    "bottom": [(t, z of the lower surface)]
    "width":  [(t, half width as a fraction of the body half width)]

Livery is a list of horizontal bands (absolute z, metres) applied in order, then windows and cab
glazing. Use "cc1" / "cc2" for company colours.
"""
from __future__ import annotations

import math
from copy import deepcopy

from geom import box, loft, pchip, se_ring

DEFAULTS = {
    "length": 25.0,
    "width": 3.38,
    "roof": 3.6,
    "skirt": 0.35,          # lowest point of the body
    "e_top": 3.2,
    "e_bot": 7.0,
    "nose": None,
    "rear_nose": False,      # True for head cars that are pointed at both ends (single-car units)
    "body": "white",
    "roof_mat": None,        # e.g. "lightgrey" for the roof above roof_z
    "roof_z": 3.35,
    "skirt_mat": "grey",
    "skirt_z": 0.7,
    "bands": [],             # [{"z": (z0, z1), "mat": "cc1", "where": "all" | "body" | "nose", "s": (s0, s1)}]
    "windows": [{"z": (2.05, 2.6), "pitch": 1.6, "duty": 0.74}],
    "window_margin": 1.8,    # no windows this close to the car ends (doors / vestibules)
    "cab": {"t0": 0.55, "t1": 0.80, "depth": 0.45},
    "lights": True,
    "bogies": True,
    "bogie_offset": 3.6,
    "maglev": False,
    "pantograph": None,      # s position of a pantograph on mid cars
    "segments": 72,
    "station_step": 0.2,
}


class Car:
    def __init__(self, spec: dict, kind: str):
        s = deepcopy(DEFAULTS)
        s.update(spec)
        self.s = s
        self.kind = kind
        self.L = s["length"] if kind == "head" or "mid_length" not in s else s["mid_length"]
        if kind == "head" and "head_length" in s:
            self.L = s["head_length"]
        self.hw = s["width"] / 2
        nose = s["nose"] if kind == "head" else None
        self.nose = nose
        self.nl = nose["length"] if nose else 0.0
        if nose:
            self.f_top = pchip(nose["top"])
            self.f_bot = pchip(nose["bottom"])
            self.f_w = pchip(nose["width"])

    def x(self, sp: float) -> float:
        return self.L / 2 - sp

    def section(self, sp: float):
        """(half width, top z, bottom z, e_top, e_bot) at s."""
        s = self.s
        half, top, bot = self.hw, s["roof"], s["skirt"]
        if self.nose:
            t = None
            if sp < self.nl:
                t = sp / self.nl
            elif s["rear_nose"] and sp > self.L - self.nl:
                t = (self.L - sp) / self.nl
            if t is not None:
                half = self.hw * self.f_w(t)
                top = self.f_top(t)
                bot = self.f_bot(t)
        # Slight rounding at flat car ends (gangways).
        end = min(sp, self.L - sp)
        if end < 0.3 and not (self.nose and sp < self.nl):
            k = 1.0 - 0.04 * (1 - end / 0.3)
            half *= k
            top = bot + (top - bot) * (1 - 0.03 * (1 - end / 0.3))
        return half, top, bot

    def stations(self):
        step = self.s["station_step"]
        sts = []
        if self.nose:
            k = 32
            sts += [self.nl * (1 - math.cos(math.pi / 2 * i / k)) for i in range(k)]
            sts[0] = 0.03
            start = self.nl
        else:
            sts += [0.0, 0.1, 0.2]
            start = 0.3
        end = self.L - (self.nl if (self.nose and self.s["rear_nose"]) else 0.3)
        n = max(int((end - start) / step), 2)
        sts += [start + (end - start) * i / n for i in range(n + 1)]
        if self.nose and self.s["rear_nose"]:
            k = 32
            sts += [self.L - self.nl * (1 - math.cos(math.pi / 2 * i / k)) for i in reversed(range(k))][1:]
            sts[-1] = self.L - 0.03
        else:
            sts += [self.L - 0.2, self.L - 0.1, self.L]
        return sts

    def body(self):
        s = self.s
        rings, secs = [], []
        for sp in self.stations():
            half, top, bot = self.section(sp)
            cz = (top + bot) / 2
            h = (top - bot) / 2
            rings.append(se_ring(self.x(sp), 0.0, cz, half, h, h, s["segments"], s["e_top"], s["e_bot"]))
            secs.append((sp, half, top, bot))

        materials = [s["body"], "glass", "cc1", "cc2", s["skirt_mat"], "light", "darkgrey"]
        if s["roof_mat"]:
            materials.append(s["roof_mat"])
        idx = {name: i for i, name in enumerate(materials)}
        idx["glass"], idx["cc1"], idx["cc2"], idx["light"] = 1, 2, 3, 5
        cab = s["cab"]
        nl, L = self.nl, self.L
        body_s0 = nl if self.nose else 0.0
        body_s1 = L - (nl if (self.nose and s["rear_nose"]) else 0.0)

        def in_nose(sp):
            return self.nose is not None and (sp < nl or (s["rear_nose"] and sp > L - nl))

        def mat_fn(i, j, centre):
            x, y, z = centre
            sp = L / 2 - x
            k = min(i, len(secs) - 1)
            _, half, top, bot = secs[k]
            side = abs(y) / max(half, 1e-3)
            m = idx[s["body"]]
            if z < s["skirt_z"]:
                m = idx[s["skirt_mat"]]
            if s["roof_mat"] and z > s["roof_z"]:
                m = idx[s["roof_mat"]]
            for b in s["bands"]:
                where = b.get("where", "all")
                if where == "body" and in_nose(sp):
                    continue
                if where == "nose" and not in_nose(sp):
                    continue
                if "s" in b and not (b["s"][0] <= sp <= b["s"][1]):
                    continue
                if b["z"][0] <= z <= b["z"][1] and side > b.get("min_side", 0.0):
                    m = idx[b["mat"]] if b["mat"] in idx else materials.index(b["mat"])
            if self.nose:
                tt = sp / nl if sp < nl else ((L - sp) / nl if (s["rear_nose"] and sp > L - nl) else None)
                if tt is not None:
                    if cab["t0"] <= tt <= cab["t1"] and z > top - cab["depth"] and side < 0.97:
                        return idx["glass"]
                    if s["lights"] and tt < 0.16 and bot + 0.25 * (top - bot) < z < bot + 0.6 * (top - bot) \
                            and 0.35 < side < 0.95:
                        return idx["light"]
            m0 = s["window_margin"]
            if body_s0 + m0 < sp < body_s1 - m0 and side > 0.82:
                for w in s["windows"]:
                    if w["z"][0] <= z <= w["z"][1]:
                        u = ((sp - body_s0 - m0) / w["pitch"]) % 1.0
                        if u < w["duty"]:
                            return idx["glass"]
            return m

        return [loft(f"car_{self.kind}", rings, materials, mat_fn=mat_fn, cap_mats=(0, 0))]

    def underframe(self):
        s = self.s
        objs = []
        if s["maglev"]:
            # Levitation / guidance chassis: a dark strip under the body along the whole car.
            s0 = self.nl * 0.6 if self.nose else 0.4
            s1 = self.L - (self.nl * 0.6 if (self.nose and s["rear_nose"]) else 0.4)
            objs.append(box("chassis", self.x(s1), self.x(s0), -self.hw * 0.86, self.hw * 0.86, 0.0, s["skirt"] + 0.25,
                            "darkgrey"))
            return objs
        if s["bogies"]:
            off = s["bogie_offset"]
            for sp in (max(off, self.nl * 0.75) if self.nose else off, self.L - off):
                objs.append(box("bogie", self.x(sp) - 1.5, self.x(sp) + 1.5, -1.2, 1.2, 0.05, 0.75, "darkgrey"))
        return objs

    def gangways(self):
        """Dark rubber gangway bellows on flat car ends."""
        objs = []
        ends = []
        if not self.nose:
            ends.append(0.0)
        if not (self.nose and self.s["rear_nose"]):
            ends.append(self.L)
        for sp in ends:
            x = self.x(sp)
            d = 0.12 if sp == 0.0 else -0.12
            objs.append(box("gangway", min(x, x + d), max(x, x + d), -0.55, 0.55, 0.95, 2.9, "darkgrey"))
        return objs

    def roof_gear(self):
        s = self.s
        if self.kind != "mid" or s["pantograph"] is None:
            return []
        sp = s["pantograph"]
        x = self.x(sp)
        r = s["roof"]
        return [box("panto_base", x - 0.8, x + 0.8, -0.6, 0.6, r - 0.05, r + 0.18, "darkgrey"),
                box("panto_arm", x - 1.3, x + 0.2, -0.08, 0.08, r + 0.18, r + 0.42, "metal"),
                box("panto_head", x - 1.4, x - 1.1, -0.8, 0.8, r + 0.42, r + 0.5, "metal")]

    def build(self):
        return self.body() + self.underframe() + self.gangways() + self.roof_gear()


def build_car(spec: dict, kind: str):
    return Car(spec, kind).build()
