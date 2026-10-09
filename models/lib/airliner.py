"""Parametric airliner generator.

A model file calls build_airliner(spec) with a dict of real-world dimensions (metres, degrees).
Positions along the fuselage are given as `s`, the distance aft of the nose tip; the generator
converts them to x = length / 2 - s so the aircraft is centred on the origin and faces +X.
Ground is z = 0 (gear down).

Livery convention (company colours are recoloured by OpenTTD):
    fin                CC1
    cheat line         CC1 (band just below the windows)
    engine nacelles    CC2
    everything else    white / grey
"""
from __future__ import annotations

import math
from copy import deepcopy

from geom import (box, cylinder_y, cylinder_z, lifting_surface, loft, pchip, revolve_x, se_ring, smoothstep)

DEFAULTS = {
    "length": 39.5,
    "fus_w": 3.76,
    "fus_h": 4.01,
    "belly_clearance": 1.5,      # ground to fuselage bottom
    "nose_len": None,            # default 1.7 x fus_h
    "nose_pow": 2.1,
    "nose_droop": 0.10,          # nose tip centre below the centreline, fraction of fus_h
    "tail_len": None,            # default 2.9 x fus_h
    "tail_tip": 0.14,            # tail cone end half-size, fraction of fus_w / 2
    "tail_up": 0.42,             # rise of the tail cone underside at the end, fraction of fus_h
    "hump": None,                # {"start": s, "end": s, "height": m, "front": m, "back": m}
    "upper_windows": None,       # (s0, s1) window band on the upper deck (hump / A380)
    "upper_window_z": 0.78,      # fraction of fus_h / 2 above the centre for the upper band
    "windows": True,
    "window_z": (0.10, 0.34),    # main-deck band, fraction of fus_h / 2 above the centre
    "cheatline_z": (-0.14, 0.05),
    "cockpit": (0.60, 0.84),     # cockpit glazing, fraction of nose_len
    "cockpit_z": 0.16,
    "belly_grey": True,
    "segments": 56,
    "wing": None,                # {"stations": [{"y", "s_le", "chord", "t"}], "dihedral", "z_root", "tip": {...}}
    "htail": None,               # {"stations": [...], "dihedral", "z"}
    "vtail": None,               # {"stations": [{"h", "s_le", "chord", "t"}], "z_base"}
    "engines": [],               # [{"s", "y", "z", "length", "d", "mirror": True, "pylon": True}]
    "gear": None,                # {"nose_s", "main_s", "main_y": [..], "wheel_r", "nose_wheels"}
    "extra": None,               # callable(spec) -> list of objects for one-off details
}


def wing_stations(span, root_y, root_s_le, root_chord, tip_chord, sweep_le, kink=None, t_root=0.15, t_tip=0.10,
                  rake=None):
    """Stations for a conventional swept wing, optionally with a trailing-edge kink (yehudi)
    and a raked tip. kink = {"y": m, "chord": m}; rake = {"y": m, "sweep_le": deg, "chord": m}."""
    semi = span / 2
    tan = math.tan(math.radians(sweep_le))
    end_y = rake["y"] if rake else semi
    st = [{"y": root_y, "s_le": root_s_le, "chord": root_chord, "t": t_root}]
    if kink:
        ky = kink["y"]
        st.append({"y": ky, "s_le": root_s_le + (ky - root_y) * tan, "chord": kink["chord"],
                   "t": t_root + (t_tip - t_root) * (ky - root_y) / (end_y - root_y)})
    st.append({"y": end_y, "s_le": root_s_le + (end_y - root_y) * tan, "chord": tip_chord if not rake else rake["chord"],
               "t": t_tip})
    if rake:
        rt = math.tan(math.radians(rake["sweep_le"]))
        st.append({"y": semi, "s_le": st[-1]["s_le"] + (semi - end_y) * rt, "chord": tip_chord, "t": t_tip * 0.9})
    return st


class Airliner:
    def __init__(self, spec: dict):
        s = deepcopy(DEFAULTS)
        s.update(spec)
        self.s = s
        self.L = s["length"]
        self.Rw = s["fus_w"] / 2
        self.Rh = s["fus_h"] / 2
        self.cz = s["belly_clearance"] + self.Rh
        self.nose_len = s["nose_len"] or 1.7 * s["fus_h"]
        self.tail_len = s["tail_len"] or 2.9 * s["fus_h"]

    # -- coordinates ---------------------------------------------------------------------------
    def x(self, s_pos: float) -> float:
        return self.L / 2 - s_pos

    def hump_extra(self, s_pos: float) -> float:
        h = self.s["hump"]
        if not h:
            return 0.0
        up = smoothstep(h["start"], h["start"] + h["front"], s_pos)
        down = 1.0 - smoothstep(h["end"] - h["back"], h["end"], s_pos)
        return h["height"] * up * down

    def section(self, s_pos: float):
        """(centre z, half width, height above centre, height below centre) at s."""
        L, Rw, Rh, cz = self.L, self.Rw, self.Rh, self.cz
        half, top, bot, c = Rw, Rh, Rh, cz
        nl, tl = self.nose_len, self.tail_len
        if s_pos < nl:
            t = max(s_pos / nl, 0.0)
            p = self.s["nose_pow"]
            f = (1 - (1 - t) ** p) ** (1 / p)
            f = max(f, 0.05)
            c = cz - self.s["nose_droop"] * self.s["fus_h"] * (1 - t) ** 1.5
            half, top, bot = Rw * f, Rh * f, Rh * f
        if s_pos > L - tl:
            t = (s_pos - (L - tl)) / tl
            tip = self.s["tail_tip"]
            half = Rw * (1 - (1 - tip) * t ** 1.25)
            top_z = cz + Rh - 0.18 * self.s["fus_h"] * t ** 1.6
            end_bot = top_z - 2 * tip * Rh
            bot_z = (cz - Rh) + (end_bot - (cz - Rh)) * smoothstep(0.0, 1.0, t) ** 0.85
            bot_z = min(bot_z, top_z - 2 * tip * Rh)
            c = (top_z + bot_z) / 2
            top = bot = (top_z - bot_z) / 2
        top_total = top + self.hump_extra(s_pos) * (1.0 if s_pos >= nl * 0.15 else 0.0)
        return c, half, top_total, bot

    def fus_bottom(self, s_pos: float) -> float:
        c, _, _, bot = self.section(s_pos)
        return c - bot

    def fus_top(self, s_pos: float) -> float:
        c, _, top, _ = self.section(s_pos)
        return c + top

    # -- fuselage --------------------------------------------------------------------------------
    def fuselage(self):
        s = self.s
        n = s["segments"]
        stations = []
        # Dense at the nose and tail, coarser along the cabin.
        nl, tl, L = self.nose_len, self.tail_len, self.L
        k = 26
        stations += [nl * (1 - math.cos(math.pi / 2 * i / k)) for i in range(k)]
        body = max(int((L - nl - tl) / 0.5), 4)
        stations += [nl + (L - nl - tl) * i / body for i in range(body)]
        stations += [L - tl + tl * i / 24 for i in range(25)]
        stations[0] = 0.02
        rings, secs = [], []
        for sp in stations:
            c, half, top, bot = self.section(sp)
            rings.append(se_ring(self.x(sp), 0.0, c, half, top, bot, n, e_top=2.0, e_bot=2.0))
            secs.append((sp, c, half, top, bot))

        materials = ["white", "glass", "cc1", "lightgrey"]
        WHITE, GLASS, CC1, GREY = range(4)
        w0, w1 = s["window_z"]
        c0, c1 = s["cheatline_z"]
        ck0, ck1 = s["cockpit"]
        uw = s["upper_windows"]

        def mat_fn(i, j, centre):
            x, y, z = centre
            sp = self.L / 2 - x
            _, c, half, top, bot = secs[min(i, len(secs) - 1)]
            zr = (z - c) / self.Rh
            side = abs(y) / max(half, 1e-3)
            if nl * ck0 < sp < nl * ck1 and z > c + s["cockpit_z"] * self.Rh * (sp / nl) and side < 0.93:
                return GLASS
            in_cabin = nl * 0.92 < sp < L - tl * 0.82
            if s["windows"] and in_cabin and w0 < zr < w1 and side > 0.55:
                return GLASS
            if uw and uw[0] < sp < uw[1] and side > 0.35:
                ztop = c + top
                if ztop - 0.55 * self.Rh * (1 - s["upper_window_z"] + 0.35) < z < ztop - 0.25 * self.Rh and \
                        z > c + s["upper_window_z"] * self.Rh * 0.85:
                    return GLASS
            if nl * 0.55 < sp < L - tl * 0.55 and c0 < zr < c1 and side > 0.45:
                return CC1
            if s["belly_grey"] and zr < -0.62 and nl * 0.4 < sp < L - tl * 0.3:
                return GREY
            return WHITE

        return [loft("fuselage", rings, materials, mat_fn=mat_fn)]

    # -- wings and tails -------------------------------------------------------------------------
    def wing_z(self, y: float) -> float:
        w = self.s["wing"]
        root_y = w["stations"][0]["y"]
        return w["z_root"] + (abs(y) - root_y) * math.tan(math.radians(w.get("dihedral", 5.0)))

    def wing_at(self, y: float):
        """Interpolated (s_le, chord, t) of the main wing at span position y."""
        st = self.s["wing"]["stations"]
        y = abs(y)
        for a, b in zip(st, st[1:]):
            if a["y"] <= y <= b["y"]:
                u = (y - a["y"]) / (b["y"] - a["y"])
                return (a["s_le"] + u * (b["s_le"] - a["s_le"]), a["chord"] + u * (b["chord"] - a["chord"]),
                        a["t"] + u * (b["t"] - a["t"]))
        last = st[-1]
        return last["s_le"], last["chord"], last["t"]

    def wing(self):
        w = self.s["wing"]
        if not w:
            return []
        stations = [{"span": st["y"], "x_le": self.x(st["s_le"]), "chord": st["chord"], "t": st["t"],
                     "off": self.wing_z(st["y"])} for st in w["stations"]]
        objs = lifting_surface("wing", stations, w.get("material", "lightgrey"), axis="y", mirror=True)
        tip = w.get("tip")
        if tip:
            objs += self.wingtip(tip)
        return objs

    def wingtip(self, tip: dict):
        """Winglet (blended / scimitar / sharklet) or wingtip fence at the last wing station, both sides."""
        last = self.s["wing"]["stations"][-1]
        y, s_le, chord = last["y"], last["s_le"], last["chord"]
        z = self.wing_z(y)
        kind = tip["kind"]
        mat = tip.get("material", "cc1" if tip.get("cc", True) else "lightgrey")
        objs = []

        def fin(side, h, cant_deg, sweep_deg, root_c, tip_c, down=False, name="winglet"):
            sgn = -1.0 if down else 1.0
            cant = math.radians(cant_deg)
            sts = []
            for u in (0.0, 1.0):
                hh = h * u
                sts.append({"x_le": self.x(s_le + hh * math.tan(math.radians(sweep_deg))),
                            "chord": root_c + (tip_c - root_c) * u, "t": 0.08,
                            "span": z + sgn * hh * math.cos(cant), "off": side * (y + hh * math.sin(cant))})
            return lifting_surface(f"{name}_{side}", sts, mat, axis="z", mirror=False)

        for side in (1, -1):
            if kind in ("winglet", "sharklet"):
                objs += fin(side, tip.get("height", 2.4), tip.get("cant", 15), tip.get("sweep", 45), chord * 0.95, chord * 0.35)
            elif kind == "scimitar":
                objs += fin(side, tip.get("height", 2.9), 12, 50, chord * 0.95, chord * 0.25)
                objs += fin(side, tip.get("lower", 1.0), 25, 40, chord * 0.7, chord * 0.3, down=True, name="winglet_low")
            elif kind == "fence":
                objs += fin(side, tip.get("height", 0.9), 0, 55, chord * 0.9, chord * 0.2)
                objs += fin(side, tip.get("lower", 0.5), 0, 55, chord * 0.8, chord * 0.2, down=True, name="fence_low")
        return objs

    def htail(self):
        h = self.s["htail"]
        if not h:
            return []
        stations = []
        root_y = h["stations"][0]["y"]
        for st in h["stations"]:
            z = h["z"] + (st["y"] - root_y) * math.tan(math.radians(h.get("dihedral", 6.0)))
            stations.append({"span": st["y"], "x_le": self.x(st["s_le"]), "chord": st["chord"], "t": st.get("t", 0.10),
                             "off": z})
        return lifting_surface("htail", stations, h.get("material", "lightgrey"), axis="y", mirror=True)

    def vtail(self):
        v = self.s["vtail"]
        if not v:
            return []
        stations = [{"span": v["z_base"] + st["h"], "x_le": self.x(st["s_le"]), "chord": st["chord"],
                     "t": st.get("t", 0.10), "off": 0.0} for st in v["stations"]]
        return lifting_surface("fin", stations, v.get("material", "cc1"), axis="z")

    # -- engines ---------------------------------------------------------------------------------
    def nacelle(self, name, s_front, y, zc, length, d, material="cc2", pylon=True, kind="turbofan"):
        r = d / 2
        x0 = self.x(s_front)
        if kind == "box":       # Concorde-style paired nacelle
            rings = []
            for u, hw, hh in ((0.0, 0.92, 0.70), (0.06, 1.0, 0.92), (0.8, 1.0, 1.0), (1.0, 0.95, 0.9)):
                rings.append(se_ring(x0 - u * length, y, zc, r * 1.5 * hw, r * hh, r * hh, 24, 4.0, 4.0))
            objs = [loft(name, rings, [material, "black"], cap_mats=(1, 1))]
        else:
            prof = [(0.0, 0.86), (0.04, 0.97), (0.22, 1.0), (0.62, 0.93), (0.9, 0.74), (1.0, 0.64)]
            profile = [(x0 - u * length, r * f) for u, f in prof]
            objs = [revolve_x(name, profile, y, zc, [material, "black", "darkgrey"], cap_mats=(1, 2))]
            plug = [(x0 - length, r * 0.42), (x0 - length * 1.16, r * 0.08)]
            objs.append(revolve_x(name + "_plug", plug, y, zc, ["darkgrey"], n=16))
        if pylon and self.s["wing"]:
            wz = self.wing_z(y) - 0.25
            top = zc + r * 0.85
            if wz > top:
                s_le, chord, _ = self.wing_at(y)
                p_front = max(s_front + length * 0.2, s_le - 1.0)
                p_back = min(s_le + chord * 0.6, s_front + length * 1.05)
                sts = [{"span": top, "x_le": self.x(p_front), "chord": p_back - p_front, "t": 0.12, "off": y},
                       {"span": wz + 0.3, "x_le": self.x(p_front + 0.4), "chord": max(p_back - p_front - 0.4, 0.5),
                        "t": 0.12, "off": y}]
                objs += lifting_surface(name + "_pylon", sts, "lightgrey", axis="z")
        return objs

    def engines(self):
        objs = []
        for k, e in enumerate(self.s["engines"]):
            sides = [1, -1] if e.get("mirror", True) and e["y"] != 0 else [1]
            for sg in sides:
                objs += self.nacelle(f"eng{k}_{'l' if sg > 0 else 'r'}", e["s"], sg * e["y"], e["z"], e["length"], e["d"],
                                     material=e.get("material", "cc2"), pylon=e.get("pylon", True),
                                     kind=e.get("kind", "turbofan"))
        return objs

    # -- landing gear ----------------------------------------------------------------------------
    def gear(self):
        g = self.s["gear"]
        if not g:
            return []
        objs = []
        r = g.get("wheel_r", 0.56)
        w = r * 0.62
        # Nose gear.
        xn = self.x(g["nose_s"])
        objs.append(cylinder_z("nose_strut", xn, 0.0, r, self.fus_bottom(g["nose_s"]) + 0.2, 0.12, "metal"))
        for sy in (-1, 1):
            objs.append(cylinder_y("nose_wheel", xn, sy * (w * 0.6), r * 0.9, r * 0.9, w, "tyre"))
        # Main gear legs: each entry is a lateral position; mirrored.
        for k, my in enumerate(g["main_y"]):
            ms = g["main_s"] if not isinstance(g["main_s"], (list, tuple)) else g["main_s"][k]
            xm = self.x(ms)
            top = self.wing_z(my) if (self.s["wing"] and abs(my) > self.Rw) else self.fus_bottom(ms) + 0.3
            bogie = g.get("bogie", 2)          # wheel rows per leg
            for sy in (-1, 1):
                y = sy * my
                objs.append(cylinder_z(f"main_strut{k}", xm, y, r, top, 0.16, "metal"))
                for row in range(bogie):
                    dx = (row - (bogie - 1) / 2) * r * 2.3
                    for side in (-1, 1):
                        objs.append(cylinder_y(f"main_wheel{k}", xm + dx, y + side * w * 0.65, r, r, w, "tyre"))
        return objs

    def build(self):
        objs = self.fuselage() + self.wing() + self.htail() + self.vtail() + self.engines() + self.gear()
        if self.s["extra"]:
            objs += self.s["extra"](self)
        return objs


def build_airliner(spec: dict):
    return Airliner(spec).build()
