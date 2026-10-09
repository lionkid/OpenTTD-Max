"""Airbus BelugaXL. A330-200 lower fuselage, wing and engines with an 8.8 m wide cargo lobe on top
(length 63.1 m, height 18.9 m). Extra fins on the tailplane tips."""
import math

import _a330
from airliner import build_airliner
from geom import lifting_surface, loft, pchip, se_ring

CATEGORY = "aircraft"
VEHICLE = "beluga_xl"

# Cargo lobe: (s, half width, centre height above the A330 centreline, half height)
_LOBE = pchip([(1.2, 0.3), (2.5, 2.6), (5.0, 3.9), (9.0, 4.4), (38.0, 4.4), (46.0, 3.6), (53.0, 1.9), (57.0, 0.6)])
_LOBE_Z = pchip([(1.2, 2.4), (5.0, 3.0), (38.0, 3.0), (50.0, 2.6), (57.0, 2.1)])


def _extra(a):
    objs = []
    rings = []
    for k in range(70):
        sp = 1.2 + (57.0 - 1.2) * (1 - math.cos(math.pi * k / 69)) / 2
        r = _LOBE(sp)
        rings.append(se_ring(a.x(sp), 0.0, a.cz + _LOBE_Z(sp), r, r * 0.98, r * 0.8, 48))
    objs.append(loft("cargo_lobe", rings, ["white", "cc1"],
                     mat_fn=lambda i, j, c: 1 if (c[2] < a.cz + 1.2 and abs(c[1]) > 2.6) else 0))
    # Vertical finlets on the tailplane tips.
    h = a.s["htail"]
    tip = h["stations"][-1]
    z = h["z"] + (tip["y"] - h["stations"][0]["y"]) * math.tan(math.radians(h.get("dihedral", 6.0)))
    for side in (1, -1):
        sts = [{"span": z - 1.2, "x_le": a.x(tip["s_le"] - 0.6), "chord": tip["chord"] + 1.4, "t": 0.08, "off": side * tip["y"]},
               {"span": z + 2.6, "x_le": a.x(tip["s_le"] + 1.0), "chord": tip["chord"] * 0.8, "t": 0.08, "off": side * tip["y"]}]
        objs += lifting_surface(f"finlet_{side}", sts, "cc1", axis="z")
    return objs


SPEC = _a330.spec(63.1, tall_fin=2.0, freighter=True, engine_d=3.1)
SPEC.update({"extra": _extra, "windows": False, "nose_droop": 0.18})
SPEC["vtail"]["z_base"] += 4.2          # the fin sits on top of the cargo lobe
PARTS = {"body": lambda: build_airliner(SPEC)}
