"""E5 Series Shinkansen (2011). End car 26.5 m with a 15 m long nose, intermediate car 25 m, width 3.35 m.
Livery: company colour 1 above the stripe (Tokiwa green), company colour 2 stripe (Tsutsuji pink), white below."""
from railcar import build_car

CATEGORY = "trains"
VEHICLE = "e5"

SPEC = {
    "head_length": 26.5, "mid_length": 25.0, "width": 3.35, "roof": 3.65, "skirt": 0.38,
    "nose": {
        "length": 15.0,
        "top": [(0.0, 0.95), (0.25, 1.15), (0.45, 1.6), (0.6, 2.45), (0.72, 3.05), (0.84, 3.15), (0.92, 3.4), (1.0, 3.65)],
        "bottom": [(0.0, 0.6), (0.25, 0.42), (1.0, 0.38)],
        "width": [(0.0, 0.38), (0.15, 0.62), (0.4, 0.88), (0.7, 0.99), (1.0, 1.0)],
    },
    "cab": {"t0": 0.6, "t1": 0.78, "depth": 0.5},
    "bands": [{"z": (2.17, 9.0), "mat": "cc1"}, {"z": (2.02, 2.16), "mat": "cc2"}],
    "windows": [{"z": (2.2, 2.65), "pitch": 1.5, "duty": 0.72}],
}

PARTS = {
    "head": {"build": lambda: build_car(SPEC, "head"), "length_m": 26.5},
    "mid": {"build": lambda: build_car(SPEC, "mid"), "length_m": 25.0},
}
